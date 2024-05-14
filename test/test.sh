#!/bin/zsh -euax

# Runs various tests.

# Run like this to avoid any env vars "leaking" in to this script:
#   env -i zsh -euax ./test/test.sh

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

# test various deploy scenarios (verify expected hostname and cluster get used)
# NOTE: the CI_    * vars are normally auto-poplated by CI/CD GL (gitlab) yaml setup
# NOTE: the GITHUB_* vars are normally auto-poplated in CI/CD GH Actions by GH (github)
(
  banner GL to dev
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://www-av.dev.archive.org'
  tags '[["https://www-av.dev.archive.org"]]'
  ctags '[["https://canary-www-av.dev.archive.org"]]'
)
(
  banner GL to dev, custom hostname
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["av"]'
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://av.dev.archive.org'
  tags '[["https://av.dev.archive.org"]]'
  ctags '[["https://canary-av.dev.archive.org"]]'
)
(
  banner GL to dev, w/ 2+ custom hostnames
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["av1", "av2.dweb.me", "poohbot.com"]'
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://av1.dev.archive.org'
  # NOTE: subtle -- with multiple names to single port deploy, we expect a list of 3 hostnames
  #       applying to *one* service
  tags '[["https://av1.dev.archive.org","https://av2.dweb.me","https://poohbot.com"]]'
  ctags '[["https://canary-av1.dev.archive.org","https://canary-av2.dweb.me","https://canary-poohbot.com"]]'
)
(
  banner GL to dev, branch, so custom hostname ignored
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=tofu
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["av"]'
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://www-av-tofu.dev.archive.org'
)
(
  banner GL to prod
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=plausible
  CI_COMMIT_REF_SLUG=production
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://prod.archive.org' \
          'deploying to https://plausible.prod.archive.org' \
          'using nomad production token'
  tags '[["urlprefix-plausible.prod.archive.org"]]'
  ctags '[["https://canary-plausible.prod.archive.org"]]'
)
(
  banner GL to prod, custom hostname
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=plausible
  CI_COMMIT_REF_SLUG=production
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["plausible-ait.prod.archive.org"]'
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://prod.archive.org' \
          'deploying to https://plausible-ait.prod.archive.org' \
          'using nomad production token'
)
(
  banner GH to dev
  GITHUB_ACTIONS=1
  GITHUB_REPOSITORY=internetarchive/emularity-engine
  GITHUB_REF_NAME=tofu
  BASE_DOMAIN=dev.archive.org
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://internetarchive-emularity-engine-tofu.dev.archive.org'
)
(
  banner GH to staging
  GITHUB_ACTIONS=1
  GITHUB_REPOSITORY=internetarchive/emularity-engine
  GITHUB_REF_NAME=staging
  BASE_DOMAIN=dev.archive.org
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://staging.archive.org' \
          'deploying to https://emularity-engine.staging.archive.org'
)
(
  banner GH to production
  GITHUB_ACTIONS=1
  GITHUB_REPOSITORY=internetarchive/emularity-engine
  GITHUB_REF_NAME=production
  BASE_DOMAIN=dev.archive.org
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://ux-b.archive.org' \
          'deploying to https://emularity-engine.ux-b.archive.org' \
          'using nomad production token'
)
(
  banner "GL repo using 'main' branch to be like 'production'"
  BASE_DOMAIN=prod.archive.org
  CI_PROJECT_NAME=offshoot
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_TOKEN_PROD=test
  NOMAD_VAR_HOSTNAMES='["offshoot"]'
  expects 'nomad cluster https://prod.archive.org' \
          'deploying to https://offshoot.prod.archive.org'
)
(
  banner GL repo using one HTTP-only port and 2+ ports/names, to dev
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=lcp
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_VAR_PORTS='{ 9999 = "http" , 18989 = "lcp", 8990 = "lsd" }'
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://services-lcp.dev.archive.org'
  # NOTE: subtle -- with multiple ports (one thus one service per port), we expect 3 services
  #       eacho with its own hostname
  tags '[["https://services-lcp.dev.archive.org"],["http://services-lcp-lcp.dev.archive.org"],["https://services-lcp-lsd.dev.archive.org"]]'
  ctags '[["https://canary-services-lcp.dev.archive.org"]]'
)
(
  banner GL repo using one HTTP-only port and 2+ ports/names, to prod
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=lcp
  CI_COMMIT_REF_SLUG=production
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_VAR_PORTS='{ 9999 = "http" , 18989 = "lcp", 8990 = "lsd" }'
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://prod.archive.org' \
          'deploying to https://lcp.prod.archive.org' \
          'using nomad production token'
  # NOTE: subtle -- with multiple ports (one thus one service per port), we expect 3 services
  #       eacho with its own hostname
  tags '[["urlprefix-lcp.prod.archive.org"],["urlprefix-lcp-lcp.prod.archive.org proto=http"],["urlprefix-lcp-lsd.prod.archive.org"]]'
  ctags '[["https://canary-lcp.prod.archive.org"]]'
)
(
  banner GL repo using one TCP-only port and 2+ ports/names
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=scribe-c2
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_VAR_PORTS='{ 9999 = "http" , -7777 = "tcp", 8889 = "reg" }'
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://services-scribe-c2.dev.archive.org'
  # NOTE: subtle -- with multiple ports (one thus one service per port), we'd normally expect 3 services
  #       eacho with its own hostname -- but one is TCP so the middle Service gets an *empty* list of tags.
  tags '[["https://services-scribe-c2.dev.archive.org"],[],["https://services-scribe-c2-reg.dev.archive.org"]]'
  ctags '[["https://canary-services-scribe-c2.dev.archive.org"]]'
)


banner SUCCESS
