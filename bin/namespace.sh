#!/bin/zsh -ux

# Setup limited access to the nomad cluster
# (If you get errors, you might need to run this using a nomad client that is v1.4 for now)


NAMESPACE=${1:?"Usage: [namespace name, eg: singularity]"}

nomad namespace apply -description "$NAMESPACE project" $NAMESPACE


echo 'namespace "'$NAMESPACE'" { policy = "write" }' |\
  nomad acl policy apply -description "$NAMESPACE only access" $NAMESPACE -

nomad acl token create -name="$NAMESPACE only access token" -policy=$NAMESPACE -type=client
