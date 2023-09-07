#!/bin/zsh -eu

# Looks for review apps for branches for active projects that are "old",
# and removes them from the nomad cluster.

# Tailor these next two variables to what makes sense for you.

JOB_STARTS="ia-petabox-  www-offshoot-"
JOB_STARTS_NOT="www-offshoot-ssr"
MAX_DAYS_OLD=28 # 4 weeks


NOW=$(date +%s)

for JOB_START in $(echo $JOB_STARTS); do
  for ID in $(nomad status |egrep "^$JOB_START" |egrep -v "^$JOB_STARTS_NOT" |cut -f1 -d' ' |sort); do
    echo
    YMD=$(nomad status $ID |egrep '^Submit Date' |cut -f2 -d= |tr -d ' ' |cut -f1 -dT)
    # convert submit date to unix timestamp (linux style; else assume macosx)
    TS=$(date --date="$YMD" +"%s" 2>/dev/null ||  date -jf "%Y-%m-%d" "$YMD" +%s)
    let "SECONDS=$NOW-$TS"
    [ $SECONDS -lt 0 ] && continue
    set +e
    let "DAYS=$SECONDS/86400"
    set -e
    # dont trust any age more than a year -- in case something strange went wrong in computing age
    [ $DAYS -gt 365 ] && continue

    echo "$ID\t$YMD => $DAYS"
    [ $DAYS -lt $MAX_DAYS_OLD ] && continue

    echo
    echo "KILL $ID\t$YMD\t$DAYS DAYS OLD"
    echo
    nomad stop -purge $ID
  done
done
