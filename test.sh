#!/bin/zsh -eu

# Runs various tests.

# Avoid any env vars "leaking" in to this script
unset $(printenv |cut -f1 -d= |grep -Ev '^PATH|HOME$')
set -ax


function banner() {
  set +x
  echo "\n\n----------------------------------------------------------------------"
  echo "$@"
  echo "----------------------------------------------------------------------"
  set -x
}
function expects() {
  set +x
  NOMAD_VAR_VERBOSE=1
  NOMAD_TOKEN=test
  LOG=/tmp/nomad-test.log
  # for testing, find `deno` and `nomad` binary executables:
  PATH=$PATH:/usr/local/sbin:/opt/homebrew/bin:$HOME/.deno/bin
  # `deno` needs this -- and is set in the `denoland/deno:alpine`.  however, due to avoiding
  # env var "leaking" into tests, we removed it (which will cause `deno` to fail to run).
  # so add it back in
  LD_LIBRARY_PATH=/usr/local/lib

  set -x
  bash -eu ./deploy.sh 2>&1 | tee $LOG
  set -e
  while [ $# -gt 0 ]; do
    EXPECT=$1
    shift
    grep "$EXPECT" $LOG
  done
}

function tags() {
  STR=$(jq -cr '[..|objects|.Tags//empty]'  /tmp/project.json)
  if [ "$STR" != "$1" ]; then
    set +x
    echo "services tags: $STR not expected: $1"
    exit 1
  fi
}

function ctags() {
  STR=$(jq -cr '[..|objects|.CanaryTags//empty]'  /tmp/project.json)
  if [ "$STR" != "$1" ]; then
    set +x
    echo "services canary tags: $STR not expected: $1"
    exit 1
  fi
}

function slug() {
  STR=$(jq -cr '.Job.ID'  /tmp/project.json)
  if [ "$STR" != "$1" ]; then
    set +x
    echo "slug/job name: $STR not expected: $1"
    exit 1
  fi
}

function prodtest() {
  CI_PROJECT_NAME=$(echo "$CI_PROJECT_PATH_SLUG" |cut -f2- -d-)
  BASE_DOMAIN=${BASE_DOMAIN:-"prod.example.com"} # default to prod.example.com unless caller set it
  NOMAD_TOKEN_PROD=test
  expects "deploying to https://$CI_HOSTNAME"
}

# test various deploy scenarios (verify expected hostname and cluster get used)
# NOTE: the CI_    * vars are normally auto-poplated by CI/CD GL (gitlab) yaml setup
# NOTE: the GITHUB_* vars are normally auto-poplated in CI/CD GH Actions by GH (github)
(
  banner GL to dev
  BASE_DOMAIN=dev.example.com
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  expects 'nomad cluster https://dev.example.com' \
          'deploying to https://www-av.dev.example.com'
  tags '[["https://www-av.dev.example.com"]]'
  ctags '[["https://canary-www-av.dev.example.com"]]'
  slug www-av
)
(
  banner GL to dev, custom hostname
  BASE_DOMAIN=dev.example.com
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["av"]'
  expects 'nomad cluster https://dev.example.com' \
          'deploying to https://av.dev.example.com'
  tags '[["https://av.dev.example.com"]]'
  ctags '[["https://canary-av.dev.example.com"]]'
  slug www-av
)
(
  echo GL to prod, via alt/unusual branch name, custom hostname
  BASE_DOMAIN=prod.example.com
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=avinfo
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["avinfo"]'
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://prod.example.com' \
          'deploying to https://avinfo.prod.example.com' \
          'using nomad production token'
  tags '[["https://avinfo.prod.example.com"]]'
  ctags '[["https://canary-avinfo.prod.example.com"]]'
  slug www-av-avinfo
)
(
  echo GL to prod, via alt/unusual branch name, custom hostname
  BASE_DOMAIN=prod.example.com
  CI_PROJECT_NAME=plausible
  CI_COMMIT_REF_SLUG=plausible-ait
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["plausible-ait"]'
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://prod.example.com' \
          'deploying to https://plausible-ait.prod.example.com' \
          'using nomad production token'
)
(
  echo GL to dev, branch, so custom hostname ignored
  banner GL to dev, w/ 2+ custom hostnames
  BASE_DOMAIN=dev.example.com
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["av1", "av2.dweb.me", "traceypooh.com"]'
  expects 'nomad cluster https://dev.example.com' \
          'deploying to https://av1.dev.example.com'
  # NOTE: subtle -- with multiple names to single port deploy, we expect a list of 3 hostnames
  #       applying to *one* service
  tags '[["https://av1.dev.example.com","https://av2.dweb.me","https://traceypooh.com"]]'
  ctags '[["https://canary-av1.dev.example.com","https://canary-av2.dweb.me","https://canary-traceypooh.com"]]'
)
(
  banner GL to dev, branch, so custom hostname ignored
  BASE_DOMAIN=dev.example.com
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=tofu
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["av"]'
  expects 'nomad cluster https://dev.example.com' \
          'deploying to https://www-av-tofu.dev.example.com'
  slug www-av-tofu
)
(
  banner GL to prod
  BASE_DOMAIN=dev.example.com
  CI_PROJECT_NAME=plausible
  CI_COMMIT_REF_SLUG=production
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://prod.example.com' \
          'deploying to https://plausible.prod.example.com' \
          'using nomad production token'
  tags '[["https://plausible.prod.example.com"]]'
  ctags '[["https://canary-plausible.prod.example.com"]]'
)
(
  banner GL to prod, custom hostname
  BASE_DOMAIN=dev.example.com
  CI_PROJECT_NAME=plausible
  CI_COMMIT_REF_SLUG=production
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["plausible-ait.prod.example.com"]'
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://prod.example.com' \
          'deploying to https://plausible-ait.prod.example.com' \
          'using nomad production token'
)
(
  banner GH to main
  GITHUB_ACTIONS=1
  GITHUB_REPOSITORY=internetarchive/emularity-engine
  GITHUB_REF_NAME=main
  BASE_DOMAIN=ux-b.example.com
  NOMAD_VAR_HOSTNAMES='["emularity-engine"]'
  expects 'nomad cluster https://ux-b.example.com' \
          'deploying to https://emularity-engine.ux-b.example.com'
)
(
  banner "GL repo using 'main' branch to be like 'production'"
  BASE_DOMAIN=prod.example.com
  CI_PROJECT_NAME=offshoot
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_TOKEN_PROD=test
  NOMAD_VAR_HOSTNAMES='["offshoot"]'
  expects 'nomad cluster https://prod.example.com' \
          'deploying to https://offshoot.prod.example.com'
  slug www-offshoot
)
(
  banner GL repo using one TCP-only port and 2+ ports/names, to dev
  BASE_DOMAIN=dev.example.com
  CI_PROJECT_NAME=lcp
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_VAR_PORTS='{ 9999 = "http" , -8989 = "lcp", 8990 = "lsd" }'
  expects 'nomad cluster https://dev.example.com' \
          'deploying to https://services-lcp.dev.example.com'
  # NOTE: subtle -- with multiple ports (one thus one service per port), we expect 3 services
  #       eacho with its own hostname
  tags '[["https://services-lcp.dev.example.com"],[],["https://services-lcp-lsd.dev.example.com"]]'
  ctags '[["https://canary-services-lcp.dev.example.com"]]'
)
(
  banner GL repo using one TCP-only port and 2+ ports/names, to prod
  BASE_DOMAIN=dev.example.com
  CI_PROJECT_NAME=lcp
  CI_COMMIT_REF_SLUG=production
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_VAR_PORTS='{ 9999 = "http" , -8989 = "lcp", 8990 = "lsd" }'
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://prod.example.com' \
          'deploying to https://lcp.prod.example.com' \
          'using nomad production token'
  # NOTE: subtle -- with multiple ports (thus one service per port), we expect 2 services
  #       each with its own hostname (the 3rd service is TCP only so gets ignored)
  tags '[["https://lcp.prod.example.com"],[],["https://lcp-lsd.prod.example.com"]]'
  ctags '[["https://canary-lcp.prod.example.com"]]'
)
(
  banner GL repo using one TCP-only port and 2+ ports/names
  BASE_DOMAIN=dev.example.com
  CI_PROJECT_NAME=scribe-c2
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_VAR_PORTS='{ 9999 = "http" , -7777 = "tcp", 8889 = "reg" }'
  expects 'nomad cluster https://dev.example.com' \
          'deploying to https://services-scribe-c2.dev.example.com'
  # NOTE: subtle -- with multiple ports (one thus one service per port), we'd normally expect 3 services
  #       eacho with its own hostname -- but one is TCP so the middle Service gets an *empty* list of tags.
  tags '[["https://services-scribe-c2.dev.example.com"],[],["https://services-scribe-c2-reg.dev.example.com"]]'
  ctags '[["https://canary-services-scribe-c2.dev.example.com"]]'
)
(
  banner repo use CI_MAIN_STYLE
  BASE_DOMAIN=ext.example.com
  NOMAD_ADDR=https://ux-b.example.com
  NOMAD_VAR_HOSTNAMES='["esm"]'
  CI_MAIN_STYLE=1
  CI_PROJECT_PATH_SLUG=www-esm
  CI_COMMIT_REF_SLUG=ext
  expects 'nomad cluster https://ux-b.example.com' \
          'deploying to https://esm.ext.example.com'
  tags '[["https://esm.ext.example.com"]]'
  ctags '[["https://canary-esm.ext.example.com"]]'
  slug www-esm
)


# a bunch of quick, simple production deploy tests validating hostnames
(
  CI_PROJECT_PATH_SLUG=services-article-exchange
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=article-exchange.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-atlas
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=atlas.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-bwhogs
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=bwhogs.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-ids-logic
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=ids-logic.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-lcp
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=lcp.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-microfilmmonitor
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=microfilmmonitor.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-oclc-ill
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=oclc-ill.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-odyssey
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=odyssey.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-opds
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=opds.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-plausible
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=plausible.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-rapid-slackbot
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=rapid-slackbot.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=services-scribe-serial-helper
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=scribe-serial-helper.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=www-av
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=av.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=www-bookserver
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=bookserver.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=www-iiif
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=iiif.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=www-nginx
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=nginx.prod.example.com
  prodtest
)
(
  CI_PROJECT_PATH_SLUG=www-rendertron
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=rendertron.prod.example.com
  prodtest
)


# a bunch of quick, _custom HOSTNAMES_, production deploy tests validating hostnames
(
  NOMAD_VAR_HOSTNAMES='["popcorn.example.com"]'
  CI_PROJECT_PATH_SLUG=www-popcorn
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=popcorn.example.com
  prodtest
)
(
  NOMAD_VAR_HOSTNAMES='["polyfill.example.com"]'
  CI_PROJECT_PATH_SLUG=www-polyfill-io-production
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=polyfill.example.com
  prodtest
)
(
  NOMAD_VAR_HOSTNAMES='["purl.example.com"]'
  CI_PROJECT_PATH_SLUG=www-purl
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=purl.example.com
  prodtest
)
(
  NOMAD_VAR_HOSTNAMES='["esm.example.com"]'
  CI_PROJECT_PATH_SLUG=www-esm
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=esm.example.com
  prodtest
)
(
  NOMAD_VAR_HOSTNAMES='["cantaloupe.prod.example.com"]'
  CI_PROJECT_PATH_SLUG=services-ia-iiif-cantaloupe-experiment
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=cantaloupe.prod.example.com
  prodtest
)
(
  NOMAD_VAR_HOSTNAMES='["plausible-ait.prod.example.com"]'
  CI_PROJECT_PATH_SLUG=services-plausible
  CI_COMMIT_REF_SLUG=production-ait
  CI_HOSTNAME=plausible-ait.prod.example.com
  prodtest
)
(
  NOMAD_VAR_HOSTNAMES='["parse_dates"]'
  CI_PROJECT_PATH_SLUG=services-parse-dates
  CI_COMMIT_REF_SLUG=production
  CI_HOSTNAME=parse_dates.prod.example.com
  prodtest
)

banner SUCCESS
