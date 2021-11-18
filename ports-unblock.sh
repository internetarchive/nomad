#!/bin/zsh -e

# If you use ferm for firewalls, here's how we do at archive.org
# DO NOT expose 4646 to the world without additional extra work securing it - this is the
# port to your `nomad` server
# (and w/o access control, any user could queue or remove jobs in your cluster, etc.)
# The lines with `$CLUSTER` here only allows access from other servers inside Internet Archive.
set -x
sudo mkdir -p /etc/ferm/input
sudo mkdir -p /etc/ferm/output
sudo mkdir -p /etc/ferm/forward
FI=/etc/ferm/input/nomad.conf
set +x
echo '
# @see https://gitlab.com/internetarchive/nomad/-/blob/master/ports-unblock.sh


# ===== WORLD OPEN =======================================================================
# nomad main port
proto tcp dport 4646 ACCEPT;

# vault main port
proto tcp dport 8200 ACCEPT;


# loadbalancer main ports - open to world for http/s std. ports
proto tcp dport 443 ACCEPT;
proto tcp dport  80 ACCEPT;

# webapps that want extra https ports for 2nd/alt daemons in their containers
#   timemachine:
proto tcp dport 8012 ACCEPT;

#   dweb ipfs:
proto tcp dport 4245 ACCEPT;

#   dweb webtorrent-seeder:
proto tcp dport 6881 ACCEPT;

#   dweb webtorrent-tracker:
proto tcp dport 6969 ACCEPT;

#   dweb wolk:
proto tcp dport 99 ACCEPT;

#   services/lcp:
proto tcp dport 8989 ACCEPT;
proto tcp dport 8990 ACCEPT;

#   services/scribe-c2:  7777 = "irc", 8889 = "reg"
proto tcp dport 7777 ACCEPT;
proto tcp dport 8889 ACCEPT;

# ===== CLUSTER OPEN ======================================================================
# for nomad join
saddr $CLUSTER proto tcp dport 4647 ACCEPT;
saddr $CLUSTER proto tcp dport 4648 ACCEPT;

# for consul service discovery, DNS, join & more - https://www.consul.io/docs/install/ports
saddr $CLUSTER proto tcp dport 8600 ACCEPT;
saddr $CLUSTER proto udp dport 8600 ACCEPT;
saddr $CLUSTER proto tcp dport 8300 ACCEPT;
saddr $CLUSTER proto tcp dport 8301 ACCEPT;
saddr $CLUSTER proto udp dport 8301 ACCEPT;
saddr $CLUSTER proto tcp dport 8302 ACCEPT;
saddr $CLUSTER proto udp dport 8302 ACCEPT;

# try to avoid "ACL Token not found" - https://github.com/hashicorp/consul/issues/5421
saddr $CLUSTER proto tcp dport 8201 ACCEPT;
saddr $CLUSTER proto udp dport 8400 ACCEPT;
saddr $CLUSTER proto tcp dport 8500 ACCEPT;

# for consul join
saddr $CLUSTER proto tcp dport 8301 ACCEPT;

# for fabio service discovery
saddr $CLUSTER proto tcp dport 9998 ACCEPT;

# locator UDP port for archive website
saddr $CLUSTER proto udp sport 8010 ACCEPT;

# for webapps and such on higher ports
saddr $CLUSTER proto tcp dport 20000:45000 ACCEPT;
' |sudo tee $FI

set -x
sudo cp -p $FI /etc/ferm/output/nomad.conf
sudo cp -p $FI /etc/ferm/forward/nomad.conf

sudo service ferm reload
