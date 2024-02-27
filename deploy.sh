#!/bin/bash -e

function verbose() {
  if [ "$NOMAD_VAR_VERBOSE" ]; then
    echo "$@";
  fi
}


function main() {
  # IF someone set this programmatically in their project yml `before_script:` tag, etc., exit
  if [ "$NOMAD_VAR_NO_DEPLOY" ]; then exit 0; fi

  if [ "$GITHUB_ACTIONS" ]; then github-setup; fi


  ############################### NOMAD VARS SETUP ##############################

  # auto-convert from pre-2022 var name
  if [ "$BASE_DOMAIN" = "" ]; then
    BASE_DOMAIN="$KUBE_INGRESS_BASE_DOMAIN"
  fi

  # some archive.org specific production/staging deployment detection & var updates first
  if [[ "$BASE_DOMAIN" == *.archive.org ]]; then
    if [ "$CI_COMMIT_REF_SLUG" = "production" ]; then
      export BASE_DOMAIN=prod.archive.org
    elif [ "$CI_COMMIT_REF_SLUG" = "staging" ]; then
      export BASE_DOMAIN=staging.archive.org
    fi

    if [ "$BASE_DOMAIN" = prod.archive.org ]; then
      if [ "$NOMAD_TOKEN_PROD" != "" ]; then
        export NOMAD_TOKEN="$NOMAD_TOKEN_PROD"
        echo using nomad production token
      fi
      if [ "$NOMAD_VAR_COUNT" = "" ]; then
        export NOMAD_VAR_COUNT=3
      fi
    elif [ "$BASE_DOMAIN" = staging.archive.org ]; then
      if [ "$NOMAD_TOKEN_STAGING" != "" ]; then
        export NOMAD_TOKEN="$NOMAD_TOKEN_STAGING"
        echo using nomad staging token
      fi
    fi
  fi

  export BASE_DOMAIN


  MAIN_OR_PROD_OR_STAGING=
  if [ "$CI_COMMIT_REF_SLUG" = "main" -o "$CI_COMMIT_REF_SLUG" = "master" -o "$CI_COMMIT_REF_SLUG" = "production" -o "$CI_COMMIT_REF_SLUG" = "staging" ]; then
    MAIN_OR_PROD_OR_STAGING=1
  fi


  # Make a nice "slug" that is like [GROUP]-[PROJECT]-[BRANCH], each component also "slugged",
  # where "-main", "-master", "-production", "-staging" are omitted. Respect DNS 63 max chars limit.
  export BRANCH_PART=""
  if [ ! $MAIN_OR_PROD_OR_STAGING ]; then
    export BRANCH_PART="-${CI_COMMIT_REF_SLUG}"
  fi
  export NOMAD_VAR_SLUG=$(echo "${CI_PROJECT_PATH_SLUG}${BRANCH_PART}" |cut -b1-63)
  # make nice (semantic) hostname, based on the slug, eg:
  #   services-timemachine.x.archive.org
  #   ia-petabox-webdev-3939-fix-things.x.archive.org
  # however, if repo has list of 1+ custom hostnames it wants to use instead for main/master branch
  # review app, then use them and log during [deploy] phase the first hostname in the list
  export HOSTNAME="${NOMAD_VAR_SLUG}.${BASE_DOMAIN}"
  # NOTE: YAML or CI/CD Variable `NOMAD_VAR_HOSTNAMES` is *IGNORED* -- and automatic $HOSTNAME above
  #       is used for branches not main/master/production/staging

  # make even nicer names for archive.org processing cluster deploys
  if [ "$BASE_DOMAIN" = "work.archive.org" ]; then
    export HOSTNAME="${CI_PROJECT_NAME}${BRANCH_PART}.${BASE_DOMAIN}"
  fi

  if [ "$NOMAD_ADDR" = "" ]; then
    export NOMAD_ADDR=https://$BASE_DOMAIN
    if [ "$BASE_DOMAIN" = archive.org ]; then
      # an archive.org specific adjustment
      export NOMAD_ADDR=https://dev.archive.org
    fi
  fi

  if [ "$NOMAD_VAR_HOSTNAMES" != ""  -a  "$BASE_DOMAIN" != "" ]; then
    # Now auto-append .$BASE_DOMAIN to any hostname that isn't a fully qualified domain name
    export NOMAD_VAR_HOSTNAMES=$(deno eval 'const fqdns = JSON.parse(Deno.env.get("NOMAD_VAR_HOSTNAMES")).map((e) => e.includes(".") ? e : e.concat(".").concat(Deno.env.get("BASE_DOMAIN"))); console.log(fqdns)')
  fi

  USE_FIRST_CUSTOM_HOSTNAME=
  if [ "$NOMAD_VAR_HOSTNAMES" != "" ]; then
    [ "$BASE_DOMAIN" = prod.archive.org ]  &&  USE_FIRST_CUSTOM_HOSTNAME=1
    [ $MAIN_OR_PROD_OR_STAGING ]           &&  USE_FIRST_CUSTOM_HOSTNAME=1
  fi


  if [ "$BASE_DOMAIN" = prod.archive.org ]; then
    if [ ! $USE_FIRST_CUSTOM_HOSTNAME ]; then
      export HOSTNAME="${CI_PROJECT_NAME}.$BASE_DOMAIN"
    fi
  fi

  if [ "$BASE_DOMAIN" = staging.archive.org ]; then
    export HOSTNAME="${CI_PROJECT_NAME}.$BASE_DOMAIN"
  fi


  if [ $USE_FIRST_CUSTOM_HOSTNAME ]; then
    export HOSTNAME=$(echo "$NOMAD_VAR_HOSTNAMES" |cut -f1 -d, |tr -d '[]" ' |tr -d "'")
  else
    NOMAD_VAR_HOSTNAMES=
  fi

  if [ "$NOMAD_VAR_HOSTNAMES" = "" ]; then
    export NOMAD_VAR_HOSTNAMES='["'$HOSTNAME'"]'
  fi


  if [[ "$NOMAD_ADDR" == *crawl*.archive.org:* ]]; then # nixxx
    export NOMAD_VAR_CONSUL_PATH='/usr/local/bin/consul'
  fi


  if [ "$CI_REGISTRY_READ_TOKEN" = "0" ]; then unset CI_REGISTRY_READ_TOKEN; fi

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
    cp "$REPODIR/project.nomad" project.nomad
  else
    rm -f project.nomad
    wget -q https://gitlab.com/internetarchive/nomad/-/raw/master/project.nomad
  fi

  verbose "Replacing variables internal to project.nomad."

  (
    fgrep -B10000 VARS.NOMAD--INSERTS-HERE project.nomad
    # if this filename doesnt exist in repo, this line noops
    cat "$REPODIR/vars.nomad" 2>/dev/null || echo
    fgrep -A10000 VARS.NOMAD--INSERTS-HERE project.nomad
  ) >| tmp.nomad
  cp tmp.nomad project.nomad
  (
    fgrep -B10000 JOB.NOMAD--INSERTS-HERE project.nomad
    # if this filename doesnt exist in repo, this line noops
    cat "$REPODIR/job.nomad" 2>/dev/null || echo
    fgrep -A10000 JOB.NOMAD--INSERTS-HERE project.nomad
  ) >| tmp.nomad
  cp tmp.nomad project.nomad
  (
    fgrep -B10000 GROUP.NOMAD--INSERTS-HERE project.nomad
    # if this filename doesnt exist in repo, this line noops
    cat "$REPODIR/group.nomad" 2>/dev/null || echo
    fgrep -A10000 GROUP.NOMAD--INSERTS-HERE project.nomad
  ) >| tmp.nomad
  cp tmp.nomad project.nomad

  verbose "project.nomad -> project.hcl"

  cp project.nomad project.hcl

  verbose "NOMAD_VAR_SLUG variable substitution"
  # Do the one current substitution nomad v1.0.3 can't do now (apparently a bug)
  sed -i "s/NOMAD_VAR_SLUG/$NOMAD_VAR_SLUG/" project.hcl


  if [ "$NOMAD_ADDR" = "https://dew.archive.org" ]; then
    # new HinD cluster(s) use `podman` driver instead of `dodker`
    sed -i 's/driver\s*=\s*"docker"/driver="podman"/'  project.hcl
  fi

  verbose "Handling NOMAD_SECRETS."
  if [ "$NOMAD_SECRETS" = "" ]; then
    # Set NOMAD_SECRETS to JSON encoded key/val hashmap of env vars starting w/ "NOMAD_SECRET_"
    # (w/ NOMAD_SECRET_ prefix omitted), then convert to HCL style hashmap string (chars ":" => "=")
    echo '{}' >| env.env
    ( env | grep -qE ^NOMAD_SECRET_ )  &&  (
      echo NOMAD_SECRETS=$(deno eval 'console.log(JSON.stringify(Object.fromEntries(Object.entries(Deno.env.toObject()).filter(([k, v]) => k.startsWith("NOMAD_SECRET_")).map(([k ,v]) => [k.replace(/^NOMAD_SECRET_/,""), v]))))' | sed 's/":"/"="/g') >| env.env
    )
  else
    # this alternate clause allows GitHub Actions to send in repo secrets to us, as a single secret
    # variable, as our JSON-like hashmap of keys (secret/env var names) and values
    cat >| env.env << EOF
NOMAD_SECRETS=$NOMAD_SECRETS
EOF
  fi

  verbose "copy current env vars starting with "CI_" to "NOMAD_VAR_CI_" variants & inject them into shell"
  deno eval 'Object.entries(Deno.env.toObject()).map(([k, v]) => console.log("export NOMAD_VAR_"+k+"="+JSON.stringify(v)))' | grep -E '^export NOMAD_VAR_CI_' >| ci.env
  source ci.env
  rm     ci.env

  set -x
  nomad validate -var-file=env.env project.hcl
  nomad plan     -var-file=env.env project.hcl 2>&1 |sed 's/\(password[^ \t]*[ \t]*\).*/\1 ... /' |tee plan.log  ||  echo
  export INDEX=$(grep -E -o -- '-check-index [0-9]+' plan.log |tr -dc 0-9)

  # IA dev & prod clusters sometimes fail to fetch deployment :( -- so let's retry 5x
  for RETRIES in $(seq 1 5); do
    set -o pipefail
    nomad run    -var-file=env.env -check-index $INDEX project.hcl 2>&1 |tee check.log
    if [ "$?" = "0" ]; then
      # This particular fail case output doesnt seem to exit non-zero -- so we have to check for it
      #   ==> 2023-03-29T17:21:15Z: Error fetching deployment
      if ! fgrep 'Error fetching deployment' check.log; then
        echo deployed to https://$HOSTNAME
        return
      fi
    fi

    echo retrying..
    sleep 10
    continue
  done
  exit 1
}


function github-setup() {
  # Converts from GitHub env vars to GitLab-like env vars

  # You must add these as Secrets to your repository:
  #   NOMAD_TOKEN
  #   NOMAD_TOKEN_PROD (optional)
  #   NOMAD_TOKEN_STAGING (optional)

  # You may override the defaults via passed-in args from your repository:
  #   BASE_DOMAIN
  #   NOMAD_ADDR
  # https://github.com/internetarchive/cicd


  # Example of the (limited) GitHub ENV vars that are avail to us:
  #  GITHUB_REPOSITORY=internetarchive/dyno

  # (registry host)
  export CI_REGISTRY=ghcr.io

  local GITHUB_REPOSITORY_LC=$(echo "${GITHUB_REPOSITORY?}" |tr A-Z a-z)

  # eg: ghcr.io/internetarchive/dyno:main  (registry image)
  export CI_GITHUB_IMAGE="${CI_REGISTRY?}/${GITHUB_REPOSITORY_LC?}:${GITHUB_REF_NAME?}"
  # since the registry image :part uses a _branch name_ and not a commit id (like gitlab),
  # we can end up with a stale deploy if we happen to redeploy to the same VM.  so force a pull.
  export NOMAD_VAR_FORCE_PULL=true

  # eg: dyno  (project name)
  export CI_PROJECT_NAME=$(basename "${GITHUB_REPOSITORY_LC?}")

  # eg: main  (branchname)  xxxd slugme
  export CI_COMMIT_REF_SLUG="${GITHUB_REF_NAME?}"

  # eg: internetarchive-dyno  xxxd better slugification
  export CI_PROJECT_PATH_SLUG=$(echo "${GITHUB_REPOSITORY_LC?}" |tr '/.' - |cut -b1-63 | sed 's/[^a-z0-9\-]//g')

  if [ "$PRIVATE_REPO" = "false" ]; then
    # turn off `docker login`` before pulling registry image, since it seems like the TOKEN expires
    # and makes re-deployment due to containers changing hosts not work.. sometimes? always?
    unset CI_REGISTRY_READ_TOKEN
  fi


  # unset any blank vars that come in from GH actions
  for i in $(env | grep -E '^NOMAD_VAR_[A-Z0-9_]+=$' |cut -f1 -d=); do
    unset $i
  done

  # see if we should do nothing
  if [ "$NOMAD_VAR_NO_DEPLOY" ]; then exit 0; fi
  if [ "$NOMAD_TOKEN" = "" -a "$NOMAD_TOKEN_PROD" = "" -a "$NOMAD_TOKEN_STAGING" = "" ]; then exit 0; fi
}

main "$1"
