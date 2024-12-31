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
# podman run --rm --privileged --net=host --cgroupns=host -v $SOCK:$SOCK ghcr.io/internetarchive/nomad:main zsh -c 'podman --remote ps -a'

set -o pipefail

filter_docker_warning() {
  grep -E -v "^WARNING! Your password will be stored unencrypted in |^Configure a credential helper to remove this warning. See|^https://docs.docker.com/engine/reference/commandline/login/#credentials-store" || true
}

docker_login_filtered() {
  # $1 - username, $2 - password, $3 - registry
  # this filters the stderr of the `podman --remote login`, without merging stdout and stderr together
  { echo "$2" | podman --remote login -u "$1" --password-stdin "$3" 2>&1 1>&3 | filter_docker_warning 1>&2; } 3>&1
}

gl_write_auto_build_variables_file() {
  echo "CI_APPLICATION_TAG=$CI_APPLICATION_TAG@$(podman --remote image inspect --format='{{ index (split (index .RepoDigests 0) "@") 1 }}' "$image_tagged")" > gl-auto-build-variables.env
}


if [[ -z "$CI_COMMIT_TAG" ]]; then
  export CI_APPLICATION_REPOSITORY=${CI_APPLICATION_REPOSITORY:-$CI_REGISTRY_IMAGE/$CI_COMMIT_REF_SLUG}
  export CI_APPLICATION_TAG=${CI_APPLICATION_TAG:-$CI_COMMIT_SHA}
else
  export CI_APPLICATION_REPOSITORY=${CI_APPLICATION_REPOSITORY:-$CI_REGISTRY_IMAGE}
  export CI_APPLICATION_TAG=${CI_APPLICATION_TAG:-$CI_COMMIT_TAG}
fi

DOCKER_BUILDKIT=1
image_tagged="$CI_APPLICATION_REPOSITORY:$CI_APPLICATION_TAG"
image_latest="$CI_APPLICATION_REPOSITORY:latest"

if [[ -n "$CI_REGISTRY" && -n "$CI_REGISTRY_USER" ]]; then
  echo "Logging in to GitLab Container Registry with CI credentials..."
  docker_login_filtered "$CI_REGISTRY_USER" "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
fi


# xxx seccomp for IA git repos
# o/w opening seccomp profile failed: open /etc/containers/seccomp.json: no such file or directory
build_args=(
  --cache-from "$CI_APPLICATION_REPOSITORY"
  $AUTO_DEVOPS_BUILD_IMAGE_EXTRA_ARGS
  --security-opt seccomp=unconfined
  --tag "$image_tagged"
)

if [ "$NOMAD_VAR_SERVERLESS" = "" ]; then
  build_args+=(--tag "$image_latest")
fi

if [[ -n "${DOCKERFILE_PATH}" ]]; then
  build_args+=(-f "$DOCKERFILE_PATH")
fi

if [[ -n "$AUTO_DEVOPS_BUILD_IMAGE_FORWARDED_CI_VARIABLES" ]]; then
  build_secret_file_path=/tmp/auto-devops-build-secrets
  "$(dirname "$0")"/export-build-secrets > "$build_secret_file_path" # xxx /build/export-build-secrets
  build_args+=(
    --secret "id=auto-devops-build-secrets,src=$build_secret_file_path"
  )
fi


(
  set -x
  podman --remote buildx build "${build_args[@]}" --progress=plain . 2>&1
)

(
  set -x
  podman --remote push "$image_tagged"
)
if [ "$NOMAD_VAR_SERVERLESS" = "" ]; then
  (
    set -x
    podman --remote push "$image_latest"
  )
fi


gl_write_auto_build_variables_file
