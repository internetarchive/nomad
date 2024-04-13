#!/bin/zsh -euax

# Runs various tests.

# Run like this to avoid any env vars "leaking" in to this script:
#   env -i zsh -euax ./test/test.sh


function expects() {
  set +x
  NOMAD_VAR_VERBOSE=1
  NOMAD_TOKEN=test
  LOG=/tmp/nomad-test.log
  PATH=$PATH:/opt/homebrew/bin

  set -x
  bash -eu ./deploy.sh 2>&1 | tee $LOG
  set -e
  while [ $# -gt 0 ]; do
    EXPECT=$1
    shift
    grep "$EXPECT" $LOG
  done
  set +x
  echo "\n----------------------------------------------------------------------\n"
  set -x
}

# test various deploy scenarios (verify expected hostname and cluster get used)
(
  echo GL to dev
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://www-av.dev.archive.org'
)
(
  echo GL to dev, custom hostname
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["av"]'
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://av.dev.archive.org'
)
(
  echo GL to dev, branch, so custom hostname ignored
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=av
  CI_COMMIT_REF_SLUG=tofu
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_VAR_HOSTNAMES='["av"]'
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://www-av-tofu.dev.archive.org'
)
(
  echo GL to prod
  BASE_DOMAIN=dev.archive.org
  CI_PROJECT_NAME=plausible
  CI_COMMIT_REF_SLUG=production
  CI_PROJECT_PATH_SLUG=services-$CI_PROJECT_NAME
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://prod.archive.org' \
          'deploying to https://plausible.prod.archive.org' \
          'using nomad production token'
)
(
  echo GL to prod, custom hostname
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
  echo GH to dev
  GITHUB_ACTIONS=1
  GITHUB_REPOSITORY=internetarchive/emularity-engine
  GITHUB_REF_NAME=tofu
  BASE_DOMAIN=dev.archive.org
  expects 'nomad cluster https://dev.archive.org' \
          'deploying to https://internetarchive-emularity-engine-tofu.dev.archive.org'
)
(
  echo GH to staging
  GITHUB_ACTIONS=1
  GITHUB_REPOSITORY=internetarchive/emularity-engine
  GITHUB_REF_NAME=staging
  BASE_DOMAIN=dev.archive.org
  NOMAD_TOKEN_PROD=test
  expects 'nomad cluster https://staging.archive.org' \
          'deploying to https://emularity-engine.staging.archive.org'
)
(
  echo GH to production
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
  echo GL repo using 'main' branch to be like 'production'
  BASE_DOMAIN=prod.archive.org
  CI_PROJECT_NAME=offshoot
  CI_COMMIT_REF_SLUG=main
  CI_PROJECT_PATH_SLUG=www-$CI_PROJECT_NAME
  NOMAD_TOKEN_PROD=test
  NOMAD_VAR_HOSTNAMES='["offshoot"]'
  expects 'nomad cluster https://prod.archive.org' \
          'deploying to https://offshoot.prod.archive.org'
)

set +x
echo; echo; echo SUCCESS
