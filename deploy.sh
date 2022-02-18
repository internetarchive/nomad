#!/bin/bash -e


function main() {
  if [ "$GITHUB_ACTIONS" ]; then github-setup; fi


  ############################### NOMAD VARS SETUP ##############################

  # auto-convert from pre-2022 var name
  if [ "$BASE_DOMAIN" = "" ]; then
    export BASE_DOMAIN="$KUBE_INGRESS_BASE_DOMAIN"
  fi

  # make a nice "slug" that is like [GROUP]-[PROJECT]-[BRANCH], each component also "slugged",
  # where "-main" or "-master" are omitted.  respect DNS limit of 63 max chars.
  export BRANCH_PART=""
  if [ "$CI_COMMIT_REF_SLUG" != "main" -a "$CI_COMMIT_REF_SLUG" != "master" ]; then export BRANCH_PART="-${CI_COMMIT_REF_SLUG}"; fi
  export NOMAD_VAR_SLUG=$(echo "${CI_PROJECT_PATH_SLUG}${BRANCH_PART}" |cut -b1-63)
  # make nice (semantic) hostname, based on the slug, eg:
  #   services-timemachine.x.archive.org
  #   ia-petabox-webdev-3939-fix-things.x.archive.org
  # however, if repo has list of 1+ custom hostnames it wants to use instead for main/master branch
  # review app, then use them and log during [deploy] phase the first hostname in the list
  export HOSTNAME="${NOMAD_VAR_SLUG}.${BASE_DOMAIN}"

  # some archive.org specific production deployment detection & var updates first
  if [ "$NOMAD_ADDR" = "" ]; then
    if   [ "$BASE_DOMAIN" =      "archive.org" ]; then export NOMAD_ADDR=https://nom.us.archive.org:4646
    elif [ "$BASE_DOMAIN" =  "dev.archive.org" ]; then export NOMAD_ADDR=https://nom.us.archive.org:4646
    elif [ "$BASE_DOMAIN" = "prod.archive.org" ]; then export NOMAD_ADDR=https://nom.ux.archive.org
    elif [ "$BASE_DOMAIN" =   "ux.archive.org" ]; then export NOMAD_ADDR=https://nom.ux.archive.org
    fi
  fi

  USE_FIRST_CUSTOM_HOSTNAME=
  if [ "$NOMAD_VAR_PRODUCTION_BRANCH" = "" ]; then

    PROD_OR_MAIN=
    if [ "$CI_COMMIT_REF_SLUG" = "production" -o "$CI_COMMIT_REF_SLUG" = "main" -o "$CI_COMMIT_REF_SLUG" = "master" ]; then
      PROD_OR_MAIN=1
    fi

    # some archive.org specific production deployment detection & var updates first
    PROD_IA=
    if [ "$CI_COMMIT_REF_SLUG" = "production" ]; then
      if [[ "$NOMAD_ADDR" == *.archive.org:* ]]; then
        PROD_IA=1
      fi
    fi

    if [ $PROD_IA ]; then
      export NOMAD_ADDR=https://nomad.ux.archive.org
      if [ "$NOMAD_VAR_COUNT" = "" ]; then
        export NOMAD_VAR_COUNT=3
      fi
      if [ "$NOMAD_TOKEN_PROD" != "" ]; then
        export NOMAD_TOKEN="$NOMAD_TOKEN_PROD"
        echo using nomad production token
      fi
    fi

    if [ "$NOMAD_VAR_HOSTNAMES" != ""  -a  "$PROD_OR_MAIN" ]; then
      USE_FIRST_CUSTOM_HOSTNAME=1
    elif [ $PROD_IA ]; then
      export HOSTNAME="${CI_PROJECT_NAME}.prod.archive.org"
    fi
  else
    if [ "$NOMAD_VAR_HOSTNAMES" != ""  -a  "$CI_COMMIT_REF_SLUG" = "$NOMAD_VAR_PRODUCTION_BRANCH" ]; then
      USE_FIRST_CUSTOM_HOSTNAME=1
    fi
  fi

  if [ $USE_FIRST_CUSTOM_HOSTNAME ]; then
    export HOSTNAME=$(echo "$NOMAD_VAR_HOSTNAMES" |cut -f1 -d, |tr -d '[]" ' |tr -d "'")
  else
    NOMAD_VAR_HOSTNAMES=
  fi

  if [ "$NOMAD_VAR_HOSTNAMES" = "" ]; then
    export NOMAD_VAR_HOSTNAMES='["'$HOSTNAME'"]'
  fi


  if [[ "$NOMAD_ADDR" == *crawl*.archive.org:* ]]; then
    # this is temporary until NFS server is setup for persistent volumes
    export NOMAD_VAR_NOT_PV='[]'
    export NOMAD_VAR_CONSUL_PATH='/usr/local/bin/consul'
  fi

  ############################### NOMAD VARS SETUP ##############################



  if [ "$1" = "stop" ]; then
    nomad stop $NOMAD_VAR_SLUG
    exit 0
  fi



  echo using nomad cluster $NOMAD_ADDR
  echo deploying to https://$HOSTNAME

  # You can have your own/custom `project.nomad` in the top of your repo - or we'll just use
  # this fully parameterized nice generic 'house style' project.
  #
  # Create project.hcl - including optional insertions that a repo might elect to inject
  REPODIR="$(pwd)"
  cd /tmp
  if [ -e "$REPODIR/project.nomad" ]; then
    cp "$REPODIR/project.nomad" project.hcl
  else
    rm -f project.nomad
    wget -q https://gitlab.com/internetarchive/nomad/-/raw/groups/project.nomad
    (
      fgrep -B10000 VARS.NOMAD--INSERTS-HERE project.nomad
      # if this filename doesnt exist in repo, this line noops
      cat "$REPODIR/vars.nomad" 2>/dev/null || echo
      fgrep -A10000 VARS.NOMAD--INSERTS-HERE project.nomad
    ) >| tmp.nomad
    (
      fgrep -B10000 JOB.NOMAD--INSERTS-HERE tmp.nomad
      # if this filename doesnt exist in repo, this line noops
      cat "$REPODIR/job.nomad" 2>/dev/null || echo
      fgrep -A10000 JOB.NOMAD--INSERTS-HERE tmp.nomad
    ) >| project.hcl
  fi


  # Do the one current substitution nomad v1.0.3 can't do now (apparently a bug)
  sed -i "s/NOMAD_VAR_SLUG/$NOMAD_VAR_SLUG/" project.hcl

  if [ "$NOMAD_SECRETS" = "" ]; then
    # set NOMAD_SECRETS to JSON encoded key/val hashmap of env vars starting w/ "NOMAD_SECRET_"
    # (w/ NOMAD_SECRET_ prefix omitted), then convert to HCL style hashmap string (chars ":" => "=")
    echo NOMAD_SECRETS=$(deno eval 'console.log(JSON.stringify(Object.fromEntries(Object.entries(Deno.env.toObject()).filter(([k, v]) => k.startsWith("NOMAD_SECRET_")).map(([k ,v]) => [k.replace(/^NOMAD_SECRET_/,""), v]))))' | sed 's/":"/"="/g') >| env.env
  else
    # this alternate clause allows GitHub Actions to send in repo secrets to us, as a single secret
    # variable, as our JSON-like hashmap of keys (secret/env var names) and values
    cat >| env.env << EOF
NOMAD_SECRETS=$NOMAD_SECRETS
EOF
  fi
  # copy current env vars starting with "CI_" to "NOMAD_VAR_CI_" variants & inject them into shell
  deno eval 'Object.entries(Deno.env.toObject()).map(([k, v]) => console.log("export NOMAD_VAR_"+k+"="+JSON.stringify(v)))' |egrep '^export NOMAD_VAR_CI_' >| ci.env
  source ci.env
  rm     ci.env

  set -x
  nomad validate -var-file=env.env project.hcl
  nomad plan     -var-file=env.env project.hcl 2>&1 |sed 's/\(password[^ \t]*[ \t]*\).*/\1 ... /' |tee plan.log  ||  echo
  export INDEX=$(grep -E -o -- '-check-index [0-9]+' plan.log |tr -dc 0-9)
  nomad run      -var-file=env.env -check-index $INDEX project.hcl

  rm env.env plan.log
  set +x

  echo deployed to https://$HOSTNAME
}


function github-setup() {
  # Converts from GitHub env vars to GitLab-like env vars

  # You must add these as Secrets to your repository:
  #   NOMAD_TOKEN
  #   NOMAD_TOKEN_PROD (optional)

  # You may override the defaults via passed-in args from your repository:
  #   BASE_DOMAIN
  #   NOMAD_ADDR
  # https://github.com/internetarchive/cicd


  # Example of the (limited) GitHub ENV vars that are avail to us:
  #  GITHUB_REPOSITORY=internetarchive/dyno

  # (registry host)
  export CI_REGISTRY=ghcr.io

  # eg: ghcr.io/internetarchive/dyno:main  (registry image)
  export CI_GITHUB_IMAGE="${CI_REGISTRY?}/${GITHUB_REPOSITORY?}:${GITHUB_REF_NAME?}"

  # eg: dyno  (project name)
  export CI_PROJECT_NAME=$(basename "${GITHUB_REPOSITORY?}")

  # eg: main  (branchname)  xxxd slugme
  export CI_COMMIT_REF_SLUG="${GITHUB_REF_NAME?}"

  # eg: internetarchive-dyno  xxxd better slugification
  export CI_PROJECT_PATH_SLUG=$(echo "${GITHUB_REPOSITORY?}" |tr / -)

  export CI_R2_PASS=${REGISTRY_TOKEN?}
  export CI_R2_USER=USERNAME
  if [ "$PRIVATE_REPO" = "false" ]; then
    # turn off `docker login`` before pulling registry image, since it seems like the TOKEN expires
    # and makes re-deployment due to containers changing hosts not work.. sometimes? always?
    unset CI_R2_PASS
  fi


  # unset any blank vars that come in from GH actions
  for i in $(env |egrep '^NOMAD_VAR_[A-Z0-9_]+=$' |cut -f1 -d=); do
    unset $i
  done

  # see if we should do nothing
  if [ "$NOMAD_VAR_NO_DEPLOY" ]; then exit 0; fi
}


main "$1"
