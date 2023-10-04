#!/bin/zsh -eu

# One time setup of server(s) to make a nomad cluster.

# xxx 2+ ip addresses for hostname to caddy LB https://caddy.community/t/caddy-as-clustered-load-balancer-hows-that-gonna-work/12510
#    could share certs dir over NFS or use Caddy API


# Our git repo
REPO=https://gitlab.com/internetarchive/nomad.git


function usage() {
  echo "
----------------------------------------------------------------------------------------------------
Usage: setup.sh   <node 1>  <node 2>  ..

----------------------------------------------------------------------------------------------------
Creates a nomad cluster on debian/ubuntu VMs/baremetals.

- Installs 'nomad'  server and client on all nodes, securely talking together & electing a leader
- Installs 'consul' server and client on all nodes
- Installs 'caddy' load balancer on all nodes
    (in case you want to use multiple IP addresses for deployments in case one LB/node is out)

Requires that you have ssh and sudo access to each of the node names you pass in.

----------------------------------------------------------------------------------------------------
Make all your nodes be FULLY-QUALIFIED DOMAIN NAMES
  (and the desired addressable url hostname if your machine has multiple names).

Run this script on a mac/linux laptop or VM where you can ssh in to all of your nodes.

Internally, the cluster will setup & use lets encrypt generated certs (created via \`caddy\`).
xxx: after 90 days you may need restart/reload nomad.

If invoking cmd-line has env var:
  NFSHOME=1                     -- then we'll setup /home/ r/o and r/w mounts
  NFS_PV=[IP ADDRESS:MOUNT_DIR] -- then we'll setup each VM with /pv mounting your NFS server for
                                   Persistent Volumes.
  TRUSTED_PROXIES=[CIDR IP RANGE] -- to optionally allow certain 'X-Forwarded-*' headers,
                                     otherwise defaults to 'private_ranges'.  See:
                    https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#trusted_proxies
  UNKNOWN_SERVICE_404=[URL]     -- url to auto-redirect to for unknown service hostnames,
                                   defaults to: https://archive.org/about/404.html
  NOMAD_ADDR_EXTRA=[HOSTNAME]   -- For 1+ extra, nicer https:// hostname(s) you'd like to use to talk
                                   to nomad, pass in hostname(s) in CSV format for us to setup.
  ON_DEMAND_TLS_ASK=[URL]       -- If you want to use caddy 'on_demand_tls', URL to use to 200/400
                                   @see https://caddy.community/t/11179

  Example:
    NFS_PV=1.1.1.1:/mnt/exports  ./setup.sh  vm1.example.com  vm2.example.com


----------------------------------------------------------------------------------------------------
NOTE: if you setup a 2 node (vm1, vm2) cluster on day 1; and want to add 2 more (vm3 & vm4) later,
you should rerun this script with just the new node names
*AND* use any of the same optional NFS* env vars used initially
*AND* set env var \`FIRST=\` to the fully-qualified first hostname used orginally.
Example:
  FIRST=vm1.example.com  NFSHOME=1  ./setup.sh  vm3.example.com  vm4.example.com
"
  exit 1
}


function main() {
  # avoids any potentially previously set external environment vars from CLI poisoning..
  unset   NOMAD_TOKEN

  typeset -a NODES # array type env variable

  if [ "$1" = "setup-consul-caddy-misc" ]; then
    setup-consul-caddy-misc

  elif [ "$1" = "setup-certs" ]; then
    setup-certs

  elif [ "$1" = "setup-nomad" ]; then
    setup-nomad

  elif [ "$#" -gt 0 ]; then
    # This is where the script starts
    set -x

    # number of args from the command line are all the hostnames to setup
    NODES=( "$@" )
    COUNT=$#
    # If script invoker is adding additional nodes to previously existing cluster, they need
    # to have set FIRST environment variable in the invoking CLI shell.  In that case, use it.
    # Otherwise, we are setting up a new cluster and we'll use the first node in the passed in list.
    set +u
    [ -z $FIRST ]  &&  FIRST=$NODES[1]
    set -u

    for NODE in $NODES; do
      ssh $NODE "sudo apt-get -yqq install git  &&  sudo git clone $REPO /nomad;  cd /nomad  &&  sudo git pull"
    done


    # Setup environment vars -- write needed environment variables to a file on each node.
    NFSHOME=${NFSHOME:-""}
    NFS_PV="${NFS_PV:-""}"
    TRUSTED_PROXIES=${TRUSTED_PROXIES:="private_ranges"}
    UNKNOWN_SERVICE_404="${UNKNOWN_SERVICE_404:-"https://archive.org/about/404.html"}"
    NOMAD_ADDR_EXTRA="${NOMAD_ADDR_EXTRA:-""}"
    ON_DEMAND_TLS_ASK="${ON_DEMAND_TLS_ASK:-""}"

    LETSENCRYPT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory"
    for NODE in $NODES; do
      ssh $NODE "sudo mkdir -m755 -p /etc/caddy  &&  echo '
FIRST=$FIRST
FQDN=$NODE
COUNT=$COUNT
NFSHOME=$NFSHOME
NFS_PV=$NFS_PV
LETSENCRYPT_DIR=$LETSENCRYPT_DIR
TRUSTED_PROXIES=$TRUSTED_PROXIES
UNKNOWN_SERVICE_404=$UNKNOWN_SERVICE_404
NOMAD_ADDR_EXTRA=$NOMAD_ADDR_EXTRA
ON_DEMAND_TLS_ASK=$ON_DEMAND_TLS_ASK
      ' | sudo tee /etc/caddy/env"
    done

    # Setup certs & get consul up & running *first* -- so can use consul for nomad bootstraping.
    # Run setups across all VMs.
    # https://learn.hashicorp.com/tutorials/nomad/clustering#use-consul-to-automatically-cluster-nodes
    for NODE in $NODES; do
      ssh $NODE  /nomad/setup.sh  setup-consul-caddy-misc
    done

    for NODE in $NODES; do
      ssh $NODE  /nomad/setup.sh  setup-certs
    done

    # Now get nomad configured and up - run "setup-nomad" on all VMs.
    for NODE in $NODES; do
      ssh $NODE  /nomad/setup.sh  setup-nomad
    done

    finish

  else
    usage "$@"
  fi
}


function load-env-vars() {
  # avoid any potentially previously set external environment vars from CLI poisoning..
  unset   NOMAD_TOKEN
  unset   NOMAD_ADDR

  # loads environment variables that were previously setup
  set -o allexport
  source /etc/caddy/env
  set +o allexport

  export  NOMAD_ADDR="https://$FIRST"

  set -x
}


function setup-consul-and-misc() {
  set -x
  load-env-vars

  cd /tmp

  setup-misc
  setup-PV
  setup-consul
}


function setup-hashicorp() {
  KEY_HASHI=/usr/share/keyrings/hashicorp-archive-keyring.gpg

  wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o $KEY_HASHI
  echo "deb [signed-by=$KEY_HASHI] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list

  sudo apt-get -yqq update
}

function setup-consul() {
  # sets up consul

  # install binaries and service files
  #   eg: /usr/bin/consul  /etc/consul.d/consul.hcl  /usr/lib/systemd/system/consul.service
  sudo apt-get -yqq install  consul

  # start up uncustomized version of consul
  sudo systemctl daemon-reload
  sudo systemctl enable  consul

  # find daemon config files from listing apt pkg contents ( eg: /etc/nomad.d/nomad.hcl )
  CONSUL_HCL=$(dpkg -L consul 2>/dev/null |egrep ^/etc/ |egrep -m1 '\.hcl$' || echo -n '')

  # restore original config (if reran)
  [ -e $CONSUL_HCL.orig ]  &&  sudo cp -p $CONSUL_HCL.orig $CONSUL_HCL

  # stash copies of original config
  sudo cp -p $CONSUL_HCL $CONSUL_HCL.orig


  # setup the fields 'encrypt' etc. as per your cluster.
  if [ $FIRST = $FQDN ]; then
    # starting cluster - how exciting!  mint some tokens
    TOK_C=$(consul keygen |tr -d ^)
  else
    # get the encrypt value from the first node's configured consul /etc/ file
    TOK_C=$(ssh $FIRST "egrep '^encrypt\s*=' $CONSUL_HCL" |cut -f2- -d= |tr -d '\t "')
  fi

  # get IP address of FIRST
  local FIRSTIP=$(host $FIRST | perl -ane 'print $F[3] if $F[2] eq "address"' |head -1)

  echo '
server = true
advertise_addr = "{{ GetInterfaceIP \"eth0\" }}"
node_name = "'$(hostname -s)'"
bootstrap_expect = '$COUNT'
encrypt = "'$TOK_C'"
retry_join = ["'$FIRSTIP'"]
ui_config { enabled = true }
limits {
  # default of 200 is too low for clusters with 200+ deploys
  http_max_conns_per_client = 32767
}
' | sudo tee -a  $CONSUL_HCL

  # restart and give a few seconds to ensure server responds
  sudo systemctl restart consul  &&  sleep 10


  # avoid a decrypt bug (consul servers speak encrypted to each other over https)
  sudo rm -fv /opt/consul/serf/local.keyring
  # restart and give a few seconds to ensure server responds
  sudo systemctl restart  consul  &&  sleep 10


  set +x
  echo "================================================================================"
  ( set -x; consul members )
  echo "================================================================================"
  set -x
}


function setup-nomad {
  # sets up nomad
  set -x

  load-env-vars

  sudo apt-get -yqq install  nomad

  # find daemon config files from listing apt pkg contents ( eg: /etc/nomad.d/nomad.hcl )
  NOMAD_HCL=$( dpkg -L nomad  2>/dev/null |egrep ^/etc/ |egrep -m1 '\.hcl$' || echo -n '')


  [ -e  $NOMAD_HCL.orig ]  &&  sudo cp -p  $NOMAD_HCL.orig  $NOMAD_HCL
  sudo cp -p  $NOMAD_HCL  $NOMAD_HCL.orig

  sudo systemctl daemon-reload
  sudo systemctl enable  nomad


  # now that this user and group exist, lock certs dir down
  sudo chown -R nomad.nomad /opt/nomad/tls


  # setup the fields 'encrypt' etc. as per your cluster.
  if [ $FIRST = $FQDN ]; then
    export TOK_N=$(nomad operator keygen |tr -d ^ |cat)
  else
    # get the encrypt value from the first node's configured nomad /etc/ file
    export TOK_N=$(ssh $FIRST "egrep  'encrypt\s*=' $NOMAD_HCL"  |cut -f2- -d= |tr -d '\t "' |cat)
  fi

  export HOME_NFS=/tmp/home
  mkdir -p $HOME_NFS
  [ $NFSHOME ]  &&  export HOME_NFS=/home


  # interpolate  nomad.hcl  to  $NOMAD_HCL
  ( echo "cat <<EOF"; cat /nomad/etc/nomad.hcl; echo EOF ) | sh | sudo tee $NOMAD_HCL


  # setup only 1st server to go into bootstrap mode (with itself)
  [ $FIRST != $FQDN ] && sudo sed -i -e 's^bootstrap_expect =.*$^^' $NOMAD_HCL


  # restart and give a few seconds to ensure server responds
  sudo systemctl restart nomad  ||  echo 'look into start -v- restart?'  &&  sleep 10

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

  set -x
}


function nomad-addr-and-token() {
  # sets NOMAD_ADDR and NOMAD_TOKEN
  CONF=$HOME/.config/nomad
  if [ $FIRST = $FQDN ]; then
    # First VM -- bootstrap the entire nomad cluster
    # If you already have a .config/nomad file -- copy it to a `.prev` file.
    [ -e $CONF ]  &&  mv $CONF $CONF.prev
    # we only get one shot at bootstrapping the ACL info access to nomad -- so save entire response
    # to a separate file (that we can extract needed TOKEN from)
    local NOMACL=$HOME/.config/nomad.$FIRST
    mkdir -p $(dirname $NOMACL)
    chmod 600 $NOMACL $CONF 2>/dev/null |cat
    nomad acl bootstrap |tee $NOMACL
    # NOTE: can run `nomad acl token self` post-facto if needed...

    # extract TOKEN from $NOMACL; set it to NOMAD_TOKEN; place the 2 nomad access env vars into $CONF
    echo "
export NOMAD_ADDR=$NOMAD_ADDR
export NOMAD_TOKEN="$(fgrep 'Secret ID' $NOMACL |cut -f2- -d= |tr -d ' ') |tee $CONF
    chmod 400 $NOMACL $CONF
  fi
  source $CONF
}


function setup-consul-caddy-misc() {
  load-env-vars

  setup-hashicorp

  setup-consul-and-misc

  sudo apt-get -yqq install  consul-template  jq  cron

  # https://caddyserver.com/docs/install#debian-ubuntu-raspbian
  sudo apt install -yqq debian-keyring debian-archive-keyring apt-transport-https
  [ -e /usr/share/keyrings/caddy-stable-archive-keyring.gpg ] ||
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      |sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    |sudo tee /etc/apt/sources.list.d/caddy-stable.list
  sudo apt-get -yqq update
  sudo apt-get -yqq install caddy
  sudo mkdir -p    /var/lib/caddy
  sudo chown caddy /var/lib/caddy

  sudo ln -sf /nomad/etc/caddy/Caddyfile.ctmpl /etc/caddy/Caddyfile.ctmpl
}

function setup-certs() {
  # setup nomad w/ https certs so they can talk to each other, and we can talk to them securely.
  set -x

  load-env-vars

  # now that consul is clustered and happy, we can customize `consul-template` and `caddy`
  sudo cp /nomad/etc/systemd/system/consul-template.service  /etc/systemd/system/


  fgrep Restart=always /lib/systemd/system/caddy.service ||
    sudo perl -i -pe 's/\[Service\]/[Service]\nRestart=always/' /lib/systemd/system/caddy.service


  sudo systemctl daemon-reload
  sudo systemctl enable consul-template
  sudo systemctl start  consul-template
  sudo systemctl status consul-template | cat
  sudo systemctl restart caddy || echo hmm


  # wait for lets encrypt certs
  TLS_CRT=$LETSENCRYPT_DIR/$FQDN/$FQDN.crt
  TLS_KEY=$LETSENCRYPT_DIR/$FQDN/$FQDN.key


  while true; do
    wget -q --server-response https://$FQDN || echo wget fail

    ( sudo cat $TLS_KEY |egrep . ) && break
    echo "waiting for $FQDN certs"
    sleep 1
  done
  sleep 2


  sudo mkdir -m 500 -p        /opt/nomad/tls
  sudo chmod -R go-rwx        /opt/nomad/tls
  /nomad/bin/nomad-tls.sh

  echo "SHELL=/bin/bash\n@daily root /nomad/bin/nomad-tls.sh" | sudo tee /etc/cron.d/nomad
}

function setup-misc() {
  # sets up docker (if needed) and a few other misc. things
  sudo apt-get -yqq install  wget

  # install docker if not already present
  /nomad/bin/install-docker-ce.sh

  setup-ctop

  # avoid death by `odcker pull` timeout nomad kills relooping and destroying i/o throughput
  echo '{ "max-download-attempts": 1 }' >| sudo tee /etc/docker/daemon.json

  if [ -e /etc/ferm ]; then
    # archive.org uses `ferm` for port firewalling.
    # Open the minimum number of HTTP/TCP/UDP ports we need to run.
    /nomad/bin/ports-unblock.sh
    sudo service docker restart  ||  echo 'no docker yet'
  fi


  # This gets us DNS resolving on archive.org VMs, at the VM level (not inside containers)-8
  # for hostnames like:
  #   services-clusters.service.consul
  if [ -e /etc/dnsmasq.d/ ]; then
    echo "server=/consul/127.0.0.1#8600" |sudo tee /etc/dnsmasq.d/nomad
    # restart and give a few seconds to ensure server responds
    sudo systemctl restart dnsmasq
    sleep 2
  fi

  FI=/lib/systemd/system/systemd-networkd.socket
  if [ -e $FI ]; then
    # workaround focal-era bug after ~70 deploys (and thus 70 "veth" interfaces)
    # https://www.mail-archive.com/ubuntu-bugs@lists.ubuntu.com/msg5888501.html
    sudo sed -i -e 's^ReceiveBuffer=.*$^ReceiveBuffer=256M^' $FI
  fi
}


function setup-PV() {
  sudo mkdir -m777 -p /pv

  if [ "$NFS_PV" ]; then
    sudo apt-get install -yqq nfs-common
    echo "$NFS_PV /pv nfs proto=tcp,nosuid,hard,intr,actimeo=1,nofail,noatime,nolock,tcp 0 0" |sudo tee -a /etc/fstab
    sudo mount /pv
  fi
}


function setup-ctop() {
  # really nice `ctop` - a container monitoring more specialized version of `top`
  # https://github.com/bcicen/ctop

  curl -fsSL https://azlux.fr/repo.gpg.key \
    | sudo gpg --dearmor -o /usr/share/keyrings/azlux-archive-keyring.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian \
    stable main" | sudo tee /etc/apt/sources.list.d/azlux.list >/dev/null

  sudo apt-get -yqq update
  sudo apt-get install -yqq docker-ctop
}


function finish() {
  set +x

  echo "

💥 CONGRATULATIONS!  Your cluster is setup. 💥

You can get started with the UI for: nomad & consul here:

Nomad  (deployment: managements & scheduling):
( https://www.nomadproject.io )
$NOMAD_ADDR
( login with NOMAD_TOKEN from $HOME/.config/nomad - keep this safe!)

Consul (networking: service discovery & health checks, service mesh, envoy, secrets storage):
( https://www.consul.io )
http://localhost:8500  (use nom-tunnel or similar to get to consul this way)

Caddy  (routing: load balancing, ingress router, https and http2 termination (to http))
( https://caddyserver.com/ )



For localhost urls above - see 'nom-tunnel' alias here:
  https://gitlab.com/internetarchive/nomad/-/blob/master/aliases

To uninstall:
  https://gitlab.com/internetarchive/nomad/-/blob/master/bin/wipe-node.sh


"
}


main "$@"
