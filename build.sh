#!/bin/bash -e

# Build stage script for Auto-DevOps

# FROM: registry.gitlab.com/internetarchive/auto-build-image/main
# which was
# FROM registry.gitlab.com/gitlab-org/cluster-integration/auto-build-image:v1.14.0
#
# then pulled the unused heroku/buildpack stuff/clutter

# Wondering how to do podman-in-podman?  Of course we are.  Here's a minimal example:
#
# SOCK=$(sudo podman info |grep -F podman.sock |rev |cut -f1 -d ' ' |rev)
# podman run --rm --privileged --net=host --cgroupns=host -v $SOCK:$SOCK registry.gitlab.com/internetarchive/nomad/master zsh -c 'podman --remote ps -a'

set -o pipefail

filter_docker_warning() {
  grep -E -v "^WARNING! Your password will be stored unencrypted in |^Configure a credential helper to remove this warning. See|^https://docs.docker.com/engine/reference/commandline/login/#credentials-store" || true
}

docker_login_filtered() {
  # $1 - username, $2 - password, $3 - registry
  # this filters the stderr of the `podman --remote login`, without merging stdout and stderr together
  { echo "$2" | podman --remote login -u "$1" --password-stdin "$3" 2>&1 1>&3 | filter_docker_warning 1>&2; } 3>&1
}


if [[ -z "$CI_COMMIT_TAG" ]]; then
  export CI_APPLICATION_REPOSITORY=${CI_APPLICATION_REPOSITORY:-$CI_REGISTRY_IMAGE/$CI_COMMIT_REF_SLUG}
  export CI_APPLICATION_TAG=${CI_APPLICATION_TAG:-$CI_COMMIT_SHA}
else
  export CI_APPLICATION_REPOSITORY=${CI_APPLICATION_REPOSITORY:-$CI_REGISTRY_IMAGE}
  export CI_APPLICATION_TAG=${CI_APPLICATION_TAG:-$CI_COMMIT_TAG}
fi

DOCKER_BUILDKIT=1

if ! podman --remote info &>/dev/null; then
  if [ -z "$DOCKER_HOST" ] && [ "$KUBERNETES_PORT" ]; then
    # export DOCKER_HOST='tcp://localhost:2375'
    export DOCKER_HOST='unix:///run/podman/podman.sock'
  fi
fi

if [[ -n "$CI_REGISTRY" && -n "$CI_REGISTRY_USER" ]]; then
  echo "Logging in to GitLab Container Registry with CI credentials..."
  docker_login_filtered "$CI_REGISTRY_USER" "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
fi

image_tagged="$CI_APPLICATION_REPOSITORY:$CI_APPLICATION_TAG"
image_latest="$CI_APPLICATION_REPOSITORY:latest"

function gl_write_auto_build_variables_file() {
  echo "CI_APPLICATION_TAG=$CI_APPLICATION_TAG@$(podman --remote image inspect --format='{{ index (split (index .RepoDigests 0) "@") 1 }}' "$image_tagged")" > gl-auto-build-variables.env
}


if [[ -n "${DOCKERFILE_PATH}" ]]; then
  echo "Building Dockerfile-based application using '${DOCKERFILE_PATH}'..."
else
  export DOCKERFILE_PATH="Dockerfile"
  echo "Building Dockerfile-based application..."
fi

if [[ ! -f "${DOCKERFILE_PATH}" ]]; then
  echo "Unable to find '${DOCKERFILE_PATH}'. Exiting..." >&2
  exit 1
fi


# shellcheck disable=SC2206
build_args=(
  --cache-from "$CI_APPLICATION_REPOSITORY"
  -f "$DOCKERFILE_PATH"
  --build-arg HTTP_PROXY="$HTTP_PROXY"
  --build-arg http_proxy="$http_proxy"
  --build-arg HTTPS_PROXY="$HTTPS_PROXY"
  --build-arg https_proxy="$https_proxy"
  --build-arg FTP_PROXY="$FTP_PROXY"
  --build-arg ftp_proxy="$ftp_proxy"
  --build-arg NO_PROXY="$NO_PROXY"
  --build-arg no_proxy="$no_proxy"
  $AUTO_DEVOPS_BUILD_IMAGE_EXTRA_ARGS
  --tag "$image_tagged"
)

if [ "$NOMAD_VAR_SERVERLESS" != "" ]; then
  build_args+=(--tag "$image_latest")
fi


if [[ -n "$AUTO_DEVOPS_BUILD_IMAGE_FORWARDED_CI_VARIABLES" ]]; then
  build_secret_file_path=/tmp/auto-devops-build-secrets
  "$(dirname "$0")"/export-build-secrets > "$build_secret_file_path"
  build_args+=(
    --secret "id=auto-devops-build-secrets,src=$build_secret_file_path"
  )
fi

cache_mode=${AUTO_DEVOPS_BUILD_CACHE_MODE:-max}
registry_ref=${AUTO_DEVOPS_BUILD_CACHE_REF:-"${CI_APPLICATION_REPOSITORY}:cache"}


echo xxx "${build_args[@]}"

podman --remote buildx build "${build_args[@]}"  --progress=plain . 2>&1

podman --remote push "$image_tagged"
if [ "$NOMAD_VAR_SERVERLESS" != "" ]; then
  podman --remote push "$image_latest"
fi


gl_write_auto_build_variables_file
