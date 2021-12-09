#!/bin/zsh -e

# Sets up a https cert for an entire domain w/ let's encrypt
# https://medium.com/@saurabh6790/generate-wildcard-ssl-certificate-using-lets-encrypt-certbot-273e432794d7

# https://github.com/kubernetes/ingress-nginx/issues/2045

# https://community.letsencrypt.org/t/confusing-on-root-domain-with-wildcard-cert/56113


[ $# -lt 1 ]  &&  echo "usage: $0 [TLS_DOMAIN eg: x.archive.org]\nusage: $0 -1 [single hostname cert"
[ $# -lt 1 ]  &&  exit 1
set -x

TLS_DOMAIN=
SINGLETON=
[ $# -eq 1 ]  &&  TLS_DOMAIN=$1
[ $# -eq 3 ]  &&  SINGLETON=$3

[ $TLS_DOMAIN ] && ARGS="--preferred-challenges dns-01  -d '*.${TLS_DOMAIN?}'"
[ $SINGLETON  ] && ARGS="--preferred-challenges http-01 -d '*.${TLS_DOMAIN?}'"

BASENAME="$TLS_DOMAIN$SINGLETON"

# This part is pretty slow, so let's do all the slow setup and save it for reuse.
# You can `sudo docker rmi certomatic` later as desired
sudo docker run -it --rm certomatic echo  || (
  sudo docker run -it --name certomatic --net=host ubuntu:focal bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get -yqq update
    apt-get -yqq install  certbot
  '
  sudo docker commit certomatic certomatic
  sudo docker rm -v  certomatic
)


sudo touch     ${BASENAME?}-{cert,key}.pem || echo 'nice.  moving on..'
sudo chmod 666 ${BASENAME?}-{cert,key}.pem || echo 'nice.  moving on..'

sudo docker run -it --rm --net=host -v $(pwd):/x  certomatic  bash -c "
  certbot certonly --manual --agree-tos --manual-public-ip-logging-ok  \
    --server https://acme-v02.api.letsencrypt.org/directory $ARGS
  set -x
  cd /etc/letsencrypt/live/*/
  cp -p fullchain.pem /x/${BASENAME?}-cert.pem
  cp -p privkey.pem   /x/${BASENAME?}-key.pem
  echo 'type exit to finish'
  bash
"
sudo chmod 444 ${BASENAME?}-cert.pem
sudo chmod 400 ${BASENAME?}-key.pem
