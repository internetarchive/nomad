#!/bin/bash -e

function verbose() {
  if [ "$NOMAD_VAR_VERBOSE" ]; then
    echo "$@";
  fi
}


function main() {
  if [ "$NOMAD_TOKEN" = test ]; then
    # during testing, set any var that isn't set, to an empty string, when the var gets used later
    NOMAD_VAR_NO_DEPLOY=${NOMAD_VAR_NO_DEPLOY:-""}
    GITHUB_ACTIONS=${GITHUB_ACTIONS:-""}
    NOMAD_VAR_HOSTNAMES=${NOMAD_VAR_HOSTNAMES:-""}
    CI_REGISTRY_READ_TOKEN=${CI_REGISTRY_READ_TOKEN:-""}
    NOMAD_VAR_COUNT=${NOMAD_VAR_COUNT:-""}
    NOMAD_SECRETS=${NOMAD_SECRETS:-""}
    NOMAD_ADDR=${NOMAD_ADDR:-""}
    NOMAD_TOKEN_PROD=${NOMAD_TOKEN_PROD:-""}
    NOMAD_TOKEN_STAGING=${NOMAD_TOKEN_STAGING:-""}
    NOMAD_TOKEN_EXT=${NOMAD_TOKEN_EXT:-""}
    PRIVATE_REPO=${PRIVATE_REPO:-""}
  fi


  # IF someone set this programmatically in their project yml `before_script:` tag, etc., exit
  if [ "$NOMAD_VAR_NO_DEPLOY" ]; then exit 0; fi

  if [ "$GITHUB_ACTIONS" ]; then github-setup; fi

  ############################### NOMAD VARS SETUP ##############################

  # auto-convert from pre-2022 var name
  if [ "$BASE_DOMAIN" = "" ]; then
    BASE_DOMAIN="$KUBE_INGRESS_BASE_DOMAIN"
  fi

  MAIN_OR_PROD_OR_STAGING_OR_EXT=
  MAIN_OR_PROD_OR_STAGING_OR_EXT_SLUG=
  PRODUCTION=
  STAGING=
  EXT=
  if [ "$CI_COMMIT_REF_SLUG" = "main" -o "$CI_COMMIT_REF_SLUG" = "master" ]; then
    MAIN_OR_PROD_OR_STAGING_OR_EXT=1
    MAIN_OR_PROD_OR_STAGING_OR_EXT_SLUG=1
  elif [ "$CI_COMMIT_REF_SLUG" = "production" ]; then
    PRODUCTION=1
    MAIN_OR_PROD_OR_STAGING_OR_EXT=1
    MAIN_OR_PROD_OR_STAGING_OR_EXT_SLUG=1
  elif [ "$BASE_DOMAIN" = "prod.archive.org" ]; then
    # NOTE: this is _very_ unusual -- but it's where a repo can elect to have
    # another branch name (not `production`) deploy to production cluster via (typically) various
    # gitlab CI/CD variables pegged to that branch name.
    PRODUCTION=1
    MAIN_OR_PROD_OR_STAGING_OR_EXT=1
  elif [ "$CI_COMMIT_REF_SLUG" = "staging" ]; then
    STAGING=1
    MAIN_OR_PROD_OR_STAGING_OR_EXT=1
    MAIN_OR_PROD_OR_STAGING_OR_EXT_SLUG=1
  elif [ "$CI_COMMIT_REF_SLUG" = "ext" ]; then
    EXT=1
    MAIN_OR_PROD_OR_STAGING_OR_EXT=1
    MAIN_OR_PROD_OR_STAGING_OR_EXT_SLUG=1
  fi


  # some archive.org specific production/staging/ext deployment detection & var updates first
  if [[ "$BASE_DOMAIN" == *.archive.org ]]; then
    if [ $PRODUCTION ]; then
      export BASE_DOMAIN=prod.archive.org
      if [[ "$CI_PROJECT_PATH_SLUG" == internetarchive-emularity-* ]]; then
        export BASE_DOMAIN=ux-b.archive.org
      fi
    elif [ $STAGING ]; then
      export BASE_DOMAIN=staging.archive.org
    elif [ $EXT ]; then
      export BASE_DOMAIN=ext.archive.org
    fi

    if [ $PRODUCTION ]; then
      if [ "$NOMAD_TOKEN_PROD" != "" ]; then
        export NOMAD_TOKEN="$NOMAD_TOKEN_PROD"
        echo using nomad production token
      fi
      if [ "$NOMAD_VAR_COUNT" = "" ]; then
        export NOMAD_VAR_COUNT=3
      fi
    elif [ $STAGING ]; then
      if [ "$NOMAD_TOKEN_STAGING" != "" ]; then
        export NOMAD_TOKEN="$NOMAD_TOKEN_STAGING"
        echo using nomad staging token
      fi
    elif [ $EXT ]; then
      if [ "$NOMAD_TOKEN_EXT" != "" ]; then
        export NOMAD_TOKEN="$NOMAD_TOKEN_EXT"
        echo using nomad ext token
      fi
    fi
  fi

  export BASE_DOMAIN


  # Make a nice "slug" that is like [GROUP]-[PROJECT]-[BRANCH], each component also "slugged",
  # where "-main", "-master", "-production", "-staging", "-ext" are omitted.
  # Respect DNS 63 max chars limit.
  export BRANCH_PART=""
  if [ ! $MAIN_OR_PROD_OR_STAGING_OR_EXT_SLUG ]; then
    export BRANCH_PART="-${CI_COMMIT_REF_SLUG}"
  fi
  export NOMAD_VAR_SLUG=$(echo "${CI_PROJECT_PATH_SLUG}${BRANCH_PART}" |cut -b1-63 | sed 's/-$//')
  # make nice (semantic) hostname, based on the slug, eg:
  #   services-timemachine.x.archive.org
  #   ia-petabox-webdev-3939-fix-things.x.archive.org
  # however, if repo has list of 1+ custom hostnames it wants to use instead for main/master branch
  # review app, then use them and log during [deploy] phase the first hostname in the list
  export HOSTNAME="${NOMAD_VAR_SLUG}.${BASE_DOMAIN}"
  # NOTE: YAML or CI/CD Variable `NOMAD_VAR_HOSTNAMES` is *IGNORED* -- and automatic $HOSTNAME above
  #       is used for branches not main/master/production/staging/ext

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

  if [ "$MAIN_OR_PROD_OR_STAGING_OR_EXT"  -a  "$NOMAD_VAR_HOSTNAMES" != "" ]; then
    export HOSTNAME=$(echo "$NOMAD_VAR_HOSTNAMES" |cut -f1 -d, |tr -d '[]" ' |tr -d "'")
  else
    NOMAD_VAR_HOSTNAMES=

    if [ "$PRODUCTION"  -o  "$STAGING"  -o  "$EXT" ]; then
      export HOSTNAME="${CI_PROJECT_NAME}.$BASE_DOMAIN"
    fi
  fi


  if [ "$NOMAD_VAR_HOSTNAMES" = "" ]; then
    export NOMAD_VAR_HOSTNAMES='["'$HOSTNAME'"]'
  fi


  if [[ "$NOMAD_ADDR" == *crawl*.archive.org:* ]]; then # nixxx
    export NOMAD_VAR_CONSUL_PATH='/usr/local/bin/consul'
  fi


  if [ "$CI_REGISTRY_READ_TOKEN" = "0" ]; then unset CI_REGISTRY_READ_TOKEN; fi

  ############################### NOMAD VARS SETUP ##############################



  if [ "$ARG1" = "stop" ]; then
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
    wget -q https://raw.githubusercontent.com/internetarchive/nomad/refs/heads/main/project.nomad
  fi

  verbose "Replacing variables internal to project.nomad."

  (
    grep -F -B10000 VARS.NOMAD--INSERTS-HERE project.nomad
    # if this filename doesnt exist in repo, this line noops
    cat "$REPODIR/vars.nomad" 2>/dev/null || echo
    grep -F -A10000 VARS.NOMAD--INSERTS-HERE project.nomad
  ) >| tmp.nomad
  cp tmp.nomad project.nomad
  (
    grep -F -B10000 JOB.NOMAD--INSERTS-HERE project.nomad
    # if this filename doesnt exist in repo, this line noops
    cat "$REPODIR/job.nomad" 2>/dev/null || echo
    grep -F -A10000 JOB.NOMAD--INSERTS-HERE project.nomad
  ) >| tmp.nomad
  cp tmp.nomad project.nomad
  (
    grep -F -B10000 GROUP.NOMAD--INSERTS-HERE project.nomad
    # if this filename doesnt exist in repo, this line noops
    cat "$REPODIR/group.nomad" 2>/dev/null || echo
    grep -F -A10000 GROUP.NOMAD--INSERTS-HERE project.nomad
  ) >| tmp.nomad
  cp tmp.nomad project.nomad

  verbose "project.nomad -> project.hcl"

  cp project.nomad project.hcl

  verbose "NOMAD_VAR_SLUG variable substitution"
  # Do the one current substitution nomad v1.0.3 can't do now (apparently a bug)
  sed -ix "s/NOMAD_VAR_SLUG/$NOMAD_VAR_SLUG/" project.hcl

  if [[ "$NOMAD_ADDR" == *.archive.org ]]; then
    local NA=$(echo "$NOMAD_ADDR" |cut -f1 -d. |sed 's=^https://==')
    case "$NA" in
      work|hind|dev|ext|books-loki|ux-b)
        # HinD cluster(s) use `podman` driver instead of `docker`
        sed -ix 's/driver\s*=\s*"docker"/driver="podman"/'  project.hcl # xxx
        sed -ix 's/memory_hard_limit/# memory_hard_limit/'  project.hcl # xxx
        ;;
    esac
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
  # Avoid env vars like commit messages (or possibly commit author) with quotes or weirness
  # or malicious values by only passing through env vars, set by gitlab automation,
  # with known sanitized values.
  # More can be added if/as needed.  list is sorted.
  export NOMAD_VAR_CI_APPLICATION_REPOSITORY="$CI_APPLICATION_REPOSITORY"
  export NOMAD_VAR_CI_APPLICATION_TAG="$CI_APPLICATION_TAG"
  export NOMAD_VAR_CI_BUILDS_DIR="$CI_BUILDS_DIR"
  export NOMAD_VAR_CI_COMMIT_BRANCH="$CI_COMMIT_BRANCH"
  export NOMAD_VAR_CI_COMMIT_REF_NAME="$CI_COMMIT_REF_NAME"
  export NOMAD_VAR_CI_COMMIT_REF_SLUG="$CI_COMMIT_REF_SLUG"
  export NOMAD_VAR_CI_COMMIT_SHA="$CI_COMMIT_SHA"
  export NOMAD_VAR_CI_COMMIT_SHORT_SHA="$CI_COMMIT_SHORT_SHA"
  export NOMAD_VAR_CI_COMMIT_TAG="$CI_COMMIT_TAG"
  export NOMAD_VAR_CI_CONCURRENT_ID="$CI_CONCURRENT_ID"
  export NOMAD_VAR_CI_DEFAULT_BRANCH="$CI_DEFAULT_BRANCH"
  export NOMAD_VAR_CI_GITHUB_IMAGE="$CI_GITHUB_IMAGE"
  export NOMAD_VAR_CI_HOSTNAME="$CI_HOSTNAME"
  export NOMAD_VAR_CI_PIPELINE_SOURCE="$CI_PIPELINE_SOURCE"
  export NOMAD_VAR_CI_PROJECT_DIR="$CI_PROJECT_DIR"
  export NOMAD_VAR_CI_PROJECT_NAME="$CI_PROJECT_NAME"
  export NOMAD_VAR_CI_PROJECT_PATH_SLUG="$CI_PROJECT_PATH_SLUG"
  export NOMAD_VAR_CI_REGISTRY="$CI_REGISTRY"
  export NOMAD_VAR_CI_REGISTRY_IMAGE="$CI_REGISTRY_IMAGE"
  export NOMAD_VAR_CI_REGISTRY_PASSWORD="$CI_REGISTRY_PASSWORD"
  export NOMAD_VAR_CI_REGISTRY_READ_TOKEN="$CI_REGISTRY_READ_TOKEN"
  export NOMAD_VAR_CI_REGISTRY_USER="$CI_REGISTRY_USER"


  if [ "$NOMAD_TOKEN" = test ]; then
    nomad run -output -var-file=env.env project.hcl >| project.json
    exit 0
  fi

  set -x
  nomad validate -var-file=env.env project.hcl
  nomad plan     -var-file=env.env project.hcl 2>&1 |sed 's/\(password[^ \t]*[ \t]*\).*/\1 ... /' |tee plan.log  ||  echo
  export INDEX=$(grep -E -o -- '-check-index [0-9]+' plan.log |tr -dc 0-9)

  # some clusters sometimes fail to fetch deployment :( -- so let's retry 5x
  for RETRIES in $(seq 1 5); do
    set -o pipefail
    nomad run    -var-file=env.env -check-index $INDEX project.hcl 2>&1 |tee check.log
    if [ "$?" = "0" ]; then
      if grep -E 'Status[ ]*=[ ]*failed' check.log; then
        # for example, unhealthy 5x, unable to roll back, ends up failing
        exit 1
      fi

      # This particular fail case output doesnt seem to exit non-zero -- so we have to check for it
      #   ==> 2023-03-29T17:21:15Z: Error fetching deployment
      if ! grep -F 'Error fetching deployment' check.log; then
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
  #   NOMAD_TOKEN_EXT (optional)

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
  if [ "${NOMAD_TOKEN}${NOMAD_TOKEN_PROD}${NOMAD_TOKEN_STAGING}${NOMAD_TOKEN_EXT}" = "" ]; then exit 0; fi
}


ARG1=
if [ $# -gt 0 ]; then ARG1=$1; fi

main
