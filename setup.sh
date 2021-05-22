#!/bin/zsh -e

# One time setup of server(s) to make a nomad cluster.
#
# Assumes you are creating cluster with debian/ubuntu VMs/baremetals,
# that you have ssh and sudo access to.
#
# Current Overview:
#   Installs nomad server and client on all nodes, securely talking together & electing a leader
#   Installs consul server and client on all nodes
#   Installs load balancer "fabio" on all nodes
#      (in case you want to use multiple IP addresses for deployments in case one LB/node is out)
#   Optionally installs gitlab runner on 1st node
#   Sets up Persistent Volume subdirs on 1st node - deployments needing PV only schedule to this node
#
# NOTE: if setup 3 nodes (h0, h1 & h2) on day 1; and want to add 2 more (h3 & h4) later,
# you can manually run the lines from `config`, then `add-nodes`
# where you set environment variables like this:
#   NODES=(h3 h4)
#   FIRST=[fully qualified DNS name of your first node]
#   CLUSTER_SIZE=2
#   INITIAL_CLUSTER_SIZE=3

MYDIR=${0:a:h}

# where supporting scripts live and will get pulled from
RAW=https://gitlab.com/internetarchive/nomad/-/raw/master

[ $# -lt 1 ]  &&  echo "
usage: $0  [TLS_CRT file]  [TLS_KEY file]  <node 2>  <node 3>  ..

[TLS_CRT file] - file location. wildcard domain PEM format.
[TLS_KEY file] - file location. wildcard domain PEM format.  May need to prepend '[SERVER]:' for rsync..)

Run this script on FIRST node in your cluster, while ssh-ed in.

If invoking cmd-line has env var NFSHOME=1 then we'll setup /home/ r/o and r/w mounts.

To simplify, we'll reuse TLS certs, setting up ACL and TLS for nomad.
"  &&  exit 1


# avoid any environment vars from CLI poisoning..
unset   NOMAD_TOKEN
unset   NOMAD_ADDR


function main() {
  if [ "$1" != "baseline"  -a  "$1" != "baseline-nomad" ]; then
    TLS_CRT=$1  # @see create-https-certs.sh - fully qualified path to crt file it created
    TLS_KEY=$2  # @see create-https-certs.sh - fully qualified path to key file it created
    shift
    INITIAL_CLUSTER_SIZE=0
    CLUSTER_SIZE=$#
    shift

    set -x
    config

    COUNT=${INITIAL_CLUSTER_SIZE?}

    # use the TLS_CRT and TLS_KEY params
    setup-certs


    # Setup baseline & get consul up/ running *first* -- so can use consul for nomad bootstraping.
    # Run "baseline" across all VMs.
    # https://learn.hashicorp.com/tutorials/nomad/clustering#use-consul-to-automatically-cluster-nodes
    typeset -a $NODES
    NODES=( ${FIRST?} "$@" )
    for NODE in ${NODES?}; do
      # copy ourself / this script over to the node first, then run it
      cat ${MYDIR?}/setup.sh | ssh $NODE 'tee /tmp/setup.sh >/dev/null && chmod +x /tmp/setup.sh'
      ssh $NODE env NFSHOME=$NFSHOME /tmp/setup.sh baseline ${FIRST?} ${COUNT?} ${CLUSTER_SIZE?}
      let "COUNT=$COUNT+1"
    done


    # Now get nomad configured and up.
    # Run "baseline-nomad" on all VMs.
    COUNT=${INITIAL_CLUSTER_SIZE?}
    for NODE in ${NODES?}; do
      ssh $NODE env NFSHOME=$NFSHOME /tmp/setup.sh baseline-nomad ${FIRST?} ${COUNT?} ${CLUSTER_SIZE?}
      let "COUNT=$COUNT+1"
    done


    finish
  else
    set -x
    FIRST=$2
    COUNT=$3
    CLUSTER_SIZE=$4

    config

    "$1"
  fi
}


function config() {
  # Let's put LB/fabio on all servers
  export LB_COUNT=${CLUSTER_SIZE?}
  export CONSUL_COUNT=${CLUSTER_SIZE?}

  if [ "$FIRST" = "" ]; then
    export FIRST=$(hostname -f)
  fi

  export  NOMAD_ADDR="https://${FIRST?}:4646"
  export CONSUL_ADDR="http://localhost:8500"
  export  FABIO_ADDR="http://localhost:9998"
  export PV_MAX=20
  export PV_DIR=/pv

  # get IP address of FIRST
  export FIRSTIP=$(host ${FIRST?} | perl -ane 'print $F[3] if $F[2] eq "address"' |head -1)

  # find daemon config files
  NOMAD_HCL=$( dpkg -L nomad  2>/dev/null |egrep ^/etc/ |egrep -m1 '\.hcl$' || echo -n '')
  CONSUL_HCL=$(dpkg -L consul 2>/dev/null |egrep ^/etc/ |egrep -m1 '\.hcl$' || echo -n '')
}


function baseline() {
  cd /tmp

  sudo apt-get -yqq install  wget

  # install docker if not already present
  getr install-docker-ce.sh
  /tmp/install-docker-ce.sh


  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
  sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
  sudo apt-get -yqq update

  # install binaries and service files
  #   eg: /usr/bin/consul  /etc/consul.d/consul.hcl  /usr/lib/systemd/system/consul.service
  sudo apt-get -yqq install  consul

  config

  # restore original config (if reran)
  [ -e $CONSUL_HCL.orig ]  &&  sudo cp -p $CONSUL_HCL.orig $CONSUL_HCL

  # stash copies of original config
  sudo cp -p $CONSUL_HCL $CONSUL_HCL.orig


  # start up uncustomized version of consul
  setup-certs
  setup-misc
  sudo systemctl daemon-reload
  sudo systemctl enable  consul

  setup-consul

  # avoid a decrypt bug (consul servers speak encrypted to each other over https)
  sudo rm /opt/consul/serf/local.keyring
  sudo systemctl restart  consul
  sleep 10

  set +x

  echo "================================================================================"
  ( set -x; consul members )
  echo "================================================================================"
}


function baseline-nomad {
  sudo apt-get -yqq install  nomad

  config

  [ -e  $NOMAD_HCL.orig ]  &&  sudo cp -p  $NOMAD_HCL.orig  $NOMAD_HCL
  sudo cp -p  $NOMAD_HCL  $NOMAD_HCL.orig

  sudo systemctl daemon-reload
  sudo systemctl enable  nomad

  setup-certs

  setup-nomad
  # NOTE: if you see failures join-ing and messages like:
  #   "No installed keys could decrypt the message"
  # try either (depending on nomad or consul) inspecting all nodes' contents of file) and:
  # sudo rm /opt/nomad/data/server/serf.keyring
  # sudo systemctl restart  nomad
  set +x

  nomad-addr-and-token
  echo "================================================================================"
  ( set -x; nomad server members )
  echo "================================================================================"
  ( set -x; nomad node status )
  echo "================================================================================"
}


function setup-consul() {
  ## Consul - setup the fields 'encrypt' etc. as per your cluster.

  if [ ${COUNT?} -eq 0 ]; then
    # starting cluster - how exciting!  mint some tokens
    TOK_C=$(consul keygen |tr -d ^)
  else
    TOK_C=$(ssh ${FIRST?} "egrep '^encrypt\s*=' ${CONSUL_HCL?}" |cut -f2- -d= |tr -d '\t "')
  fi

  echo '
server = true
advertise_addr = "{{ GetInterfaceIP \"eth0\" }}"
node_name = "'$(hostname -s)'"
bootstrap_expect = '${CONSUL_COUNT?}'
encrypt = "'${TOK_C?}'"
retry_join = ["'${FIRSTIP?}'"]
' | sudo tee -a  $CONSUL_HCL

  sudo systemctl restart consul  &&  sleep 10
}


function setup-nomad() {
  # setup only 1st server to go into bootstrap mode (with itself)
  [ $COUNT -ge 1 ] && sudo sed -i -e 's^bootstrap_expect =.*$^^' $NOMAD_HCL

  # setup the fields 'encrypt' etc. as per your cluster.
  [ $COUNT -eq 0 ]  &&  export TOK_N=$(nomad operator keygen |tr -d ^ |cat)
  [ $COUNT -ge 1 ]  &&  export TOK_N=$(ssh ${FIRST?} "egrep  'encrypt\s*=' ${NOMAD_HCL?}"  |cut -f2- -d= |tr -d '\t "' |cat)

  # All jobs requiring a PV get put on first cluster node
  # We'll put a loadbalancer on all cluster nodes (unless installer wants otherwise)
  export KIND=worker
  [ ${COUNT?} -eq 0 ]             &&  export KIND="$KIND,pv"
  [ ${COUNT?} -lt ${LB_COUNT?} ]  &&  export KIND="$KIND,lb"


  export HOME_NFS=/tmp/home
  [ $NFSHOME ]  &&  export HOME_NFS=/home


  getr etc/nomad.hcl
  # interpolate  /tmp/nomad.hcl  to  $NOMAD_HCL
  ( echo "cat <<EOF"; cat /tmp/nomad.hcl; echo EOF ) | sh | sudo tee $NOMAD_HCL
  rm /tmp/nomad.hcl


  # First server in cluster gets marked for hosting repos with Persistent Volume requirements.
  # Keeping things simple, and to avoid complex multi-host solutions like rook/ceph, we'll
  # pass through these `/pv/` dirs from the VM/host to containers.  Each container using it
  # needs to use a unique subdir...
  # So we'll peg all deployed project(s) with PV requirements to first host.
  (
    echo 'client {'
    for N in $(seq 1 ${PV_MAX?}); do
      sudo mkdir -m777 -p ${PV_DIR?}/$N
      echo 'host_volume "pv'$N'" { path = "'${PV_DIR?}'/'$N'" read_only = false }'
    done
    echo '}'
  ) |sudo tee -a $NOMAD_HCL


  sudo systemctl restart nomad  &&  sleep 10  ||  echo 'moving on ...'
}


function nomad-addr-and-token() {
  # set NOMAD_ADDR and NOMAD_TOKEN
  CONF=$HOME/.config/nomad
  if [ ${COUNT?} -eq 0 ]; then
    # NOTE: if you can't listen on :443 and :80 (the ideal defaults), you'll need to change
    # the two fabio.* files in this dir, re-copy the fabio.properties file in place and manually
    # restart fabio..
    [ -e $CONF ]  &&  mv $CONF $CONF.prev
    local NOMACL=$HOME/.config/nomad.$(echo ${FIRST?} |cut -f1 -d.)
    mkdir -p $(dirname $NOMACL)
    chmod 600 $NOMACL $CONF 2>/dev/null |cat
    nomad acl bootstrap |tee $NOMACL
    # NOTE: can run `nomad acl token self` post-facto if needed...
    echo "
export NOMAD_ADDR=$NOMAD_ADDR
export NOMAD_TOKEN="$(fgrep 'Secret ID' $NOMACL |cut -f2- -d= |tr -d ' ') |tee $CONF
    chmod 400 $NOMACL $CONF
  fi
  source $CONF
}



function setup-misc() {
  if [ -e /etc/ferm ]; then
    # archive.org uses `ferm` for port firewalling.
    # Open the minimum number of HTTP/TCP/UDP ports we need to run.
    getr ports-unblock.sh
    /tmp/ports-unblock.sh
    sudo service docker restart  ||  echo 'no docker yet'
  fi


  # This gets us DNS resolving on archive.org VMs, at the VM level (not inside containers)-8
  # for hostnames like:
  #   services-clusters.service.consul
  if [ -e /etc/dnsmasq.d/ ]; then
    echo "server=/consul/127.0.0.1#8600" |sudo tee /etc/dnsmasq.d/nomad
    sudo systemctl restart dnsmasq
    sleep 2
  fi
}


function setup-certs() {
  # sets up https / TLS  and fabio for routing, loadbalancing, and https traffic
  local DOMAIN=$(echo ${FIRST?} |cut -f2- -d.)
  local CRT=/etc/fabio/ssl/${DOMAIN?}-cert.pem
  local KEY=/etc/fabio/ssl/${DOMAIN?}-key.pem

  sudo mkdir -p         /etc/fabio/ssl/
  sudo chown root:root  /etc/fabio/ssl/
  wget -qO- ${RAW?}/etc/fabio.properties |sudo tee /etc/fabio/fabio.properties

  [ $TLS_CRT ]  &&  sudo bash -c "(
    rsync -Pav ${TLS_CRT?} ${CRT?}
    rsync -Pav ${TLS_KEY?} ${KEY?}
  )"

  [ ${COUNT?} -gt 0 ]  &&  bash -c "(
    ssh ${FIRST?} sudo cat ${CRT?} |sudo tee ${CRT} >/dev/null
    ssh ${FIRST?} sudo cat ${KEY?} |sudo tee ${KEY} >/dev/null
  )"

  sudo chown root:root ${CRT} ${KEY}
  sudo chmod 444 ${CRT}
  sudo chmod 400 ${KEY}


  sudo mkdir -m 500 -p      /opt/nomad/tls
  sudo cp $CRT              /opt/nomad/tls/tls.crt
  sudo cp $KEY              /opt/nomad/tls/tls.key
  sudo chown -R nomad.nomad /opt/nomad/tls  ||  echo 'future pass will work'
  sudo chmod -R go-rwx      /opt/nomad/tls
}


function getr() {
  # gets a supporting file from main repo into /tmp/
  wget --backups=1 -qP /tmp/ ${RAW}/"$1"
  chmod +x /tmp/$(basename "$1")
}


function finish() {
  sleep 30
  nomad-addr-and-token

  nomad run ${RAW?}/etc/fabio.hcl
  set +x

  echo "Setup GitLab runner in your cluster?\n"
  echo "Enter 'yes' now to set up a GitLab runner in your cluster"
  read cont

  if [ "$cont" = "yes" ]; then
    getr setup-runner.sh
    /tmp/setup-runner.sh
  fi


  echo "

💥 CONGRATULATIONS!  Your cluster is setup. 💥

You can get started with the UI for: nomad consul fabio here:

Nomad  (deployment: managements & scheduling):
( https://www.nomadproject.io )
$NOMAD_ADDR
( login with NOMAD_TOKEN from $HOME/.config/nomad - keep this safe!)

Consul (networking: service discovery & health checks, service mesh, envoy, secrets storage):
( https://www.consul.io )
$CONSUL_ADDR

Fabio  (routing: load balancing, ingress/edge router, https and http2 termination (to http))
( https://fabiolb.net )
$FABIO_ADDR



For localhost urls above - see 'nom-tunnel' alias here:
  https://gitlab.com/internetarchive/nomad/-/blob/master/aliases

To uninstall:
  https://gitlab.com/internetarchive/nomad/-/blob/master/wipe-node.sh


"
}


main "$@"
