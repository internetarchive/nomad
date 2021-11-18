#!/bin/bash -ex

# Installs latest stable docker-ce version for current ubuntu OS.
# Should be andy/tracey compatible -- ie: should be same version.
VER=
VER="=5:19.03.13~3-0~ubuntu-focal"

[ "$( docker -v 2> /dev/null )" = "" ]  ||  echo 'docker already installed - exiting'
[ "$( docker -v 2> /dev/null )" = "" ]  ||  exit 0

sudo apt-get -yqq update
sudo apt-get -yqq install \
  apt-transport-https \
  ca-certificates \
  curl \
  software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo apt-key fingerprint 0EBFCD88

echo \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable" | sudo tee /etc/apt/sources.list.d/download_docker_com_linux_ubuntu.list

sudo apt-get -yqq update

sudo apt-get -yqq install docker-ce$VER
