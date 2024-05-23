#!/bin/bash -e

# FROM: registry.gitlab.com/internetarchive/auto-build-image/main
# which was FROM: gitlab-org/cluster-integration/auto-build-image

# build stage script for Auto-DevOps

set -o pipefail

filter_docker_warning() {
  grep -E -v "^WARNING! Your password will be stored unencrypted in |^Configure a credential helper to remove this warning. See|^https://docs.docker.com/engine/reference/commandline/login/#credentials-store" || true
}

docker_login_filtered() {
  # $1 - username, $2 - password, $3 - registry
  # this filters the stderr of the `docker login`, without merging stdout and stderr together
  { echo "$2" | docker login -u "$1" --password-stdin "$3" 2>&1 1>&3 | filter_docker_warning 1>&2; } 3>&1
}


if ! docker info &>/dev/null; then
  if [ -z "$DOCKER_HOST" ] && [ "$KUBERNETES_PORT" ]; then
    export DOCKER_HOST='tcp://localhost:2375'
  fi
fi

if [[ -n "$CI_REGISTRY" && -n "$CI_REGISTRY_USER" ]]; then
  echo "Logging in to GitLab Container Registry with CI credentials..."
  docker_login_filtered "$CI_REGISTRY_USER" "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
fi

if [[ -n "$CI_DEPENDENCY_PROXY_SERVER" && -n "$CI_DEPENDENCY_PROXY_USER" ]]; then
  echo "Logging in to GitLab Dependency proxy with CI credentials..."
  docker_login_filtered "$CI_DEPENDENCY_PROXY_USER" "$CI_DEPENDENCY_PROXY_PASSWORD" "$CI_DEPENDENCY_PROXY_SERVER"
fi

image_previous="$CI_APPLICATION_REPOSITORY:$CI_COMMIT_BEFORE_SHA"
image_tagged="$CI_APPLICATION_REPOSITORY:$CI_APPLICATION_TAG"
image_latest="$CI_APPLICATION_REPOSITORY:latest"

function gl_write_auto_build_variables_file() {
  echo "CI_APPLICATION_TAG=$CI_APPLICATION_TAG@$(docker image inspect --format='{{ index (split (index .RepoDigests 0) "@") 1 }}' "$image_tagged")" > gl-auto-build-variables.env
}

if [[ "$AUTO_DEVOPS_BUILD_IMAGE_CNB_ENABLED" != "false" && ! -f Dockerfile && -z "${DOCKERFILE_PATH}" ]]; then
  builder=${AUTO_DEVOPS_BUILD_IMAGE_CNB_BUILDER:-"heroku/buildpacks:20"}
  default_port=${AUTO_DEVOPS_BUILD_IMAGE_CNB_PORT:-"5000"}
  echo "Building Cloud Native Buildpack-based application with builder ${builder}..."
  buildpack_args=()
  if [[ -n "$BUILDPACK_URL" ]]; then
    buildpack_args=('--buildpack' "$BUILDPACK_URL")
  fi
  volume_args=()
  if [[ -n "$BUILDPACK_VOLUMES" ]]; then
    mapfile -t vol_arg_names < <(echo "$BUILDPACK_VOLUMES" | tr '|' "\n")
    for vol_arg_name in "${vol_arg_names[@]}"; do
      volume_args+=('--volume' "$vol_arg_name")
    done
  fi
  env_args=()
  if [[ -n "$AUTO_DEVOPS_BUILD_IMAGE_FORWARDED_CI_VARIABLES" ]]; then
    mapfile -t env_arg_names < <(echo "$AUTO_DEVOPS_BUILD_IMAGE_FORWARDED_CI_VARIABLES" | tr ',' "\n")
    for env_arg_name in "${env_arg_names[@]}"; do
      env_args+=('--env' "$env_arg_name")
    done
  fi
  run_image=()
  if [[ -n "$AUTO_DEVOPS_BUILD_IMAGE_CNB_RUN_IMAGE" ]]; then
    run_image=('--run-image' "$AUTO_DEVOPS_BUILD_IMAGE_CNB_RUN_IMAGE")
  fi
  lifecycle_image=()
  if [[ -n "$AUTO_DEVOPS_BUILD_IMAGE_CNB_LIFECYCLE_IMAGE" ]]; then
    lifecycle_image=('--lifecycle-image' "$AUTO_DEVOPS_BUILD_IMAGE_CNB_LIFECYCLE_IMAGE")
  fi
  pack build tmp-cnb-image \
    --builder "$builder" \
    "${env_args[@]}" \
    "${buildpack_args[@]}" \
    "${volume_args[@]}" \
    "${run_image[@]}" \
    "${lifecycle_image[@]}" \
    --env HTTP_PROXY \
    --env http_proxy \
    --env HTTPS_PROXY \
    --env https_proxy \
    --env FTP_PROXY \
    --env ftp_proxy \
    --env NO_PROXY \
    --env no_proxy
  if [[ "$default_port" != "false" ]]; then
    cp /build/cnb.Dockerfile Dockerfile
    docker build \
      --build-arg source_image=tmp-cnb-image \
      --build-arg default_port="${default_port}" \
      --tag "$image_tagged" \
      --tag "$image_latest" \
      .
  else
    docker tag tmp-cnb-image "$image_tagged"
    docker tag tmp-cnb-image "$image_latest"
  fi
  docker push "$image_tagged"
  docker push "$image_latest"
  gl_write_auto_build_variables_file
  exit 0
fi

if [[ -n "${DOCKERFILE_PATH}" ]]; then
  echo "Building Dockerfile-based application using '${DOCKERFILE_PATH}'..."
else
  export DOCKERFILE_PATH="Dockerfile"

  if [[ -f "${DOCKERFILE_PATH}" ]]; then
    echo "Building Dockerfile-based application..."
  else
    echo "Building Heroku-based application using gliderlabs/herokuish docker image..."
    erb -T - /build/Dockerfile.erb > "${DOCKERFILE_PATH}"
  fi
fi

if [[ ! -f "${DOCKERFILE_PATH}" ]]; then
  echo "Unable to find '${DOCKERFILE_PATH}'. Exiting..." >&2
  exit 1
fi

# By default we support DOCKER_BUILDKIT, however it can be turned off
# by explicitly setting this to an empty string
DOCKER_BUILDKIT=${DOCKER_BUILDKIT:-1}

# shellcheck disable=SC2206
build_args=(
  --cache-from "$image_previous"
  --cache-from "$image_latest"
  -f "$DOCKERFILE_PATH"
  --build-arg BUILDPACK_URL="$BUILDPACK_URL"
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
  --tag "$image_latest"
)

if [[ -n "$AUTO_DEVOPS_BUILD_IMAGE_FORWARDED_CI_VARIABLES" ]]; then
  build_secret_file_path=/tmp/auto-devops-build-secrets
  "$(dirname "$0")"/export-build-secrets > "$build_secret_file_path"
  build_args+=(
    --secret "id=auto-devops-build-secrets,src=$build_secret_file_path"
  )

  # Setting build time secrets always requires buildkit
  DOCKER_BUILDKIT=1
fi

cache_type=$AUTO_DEVOPS_BUILD_CACHE
cache_mode=${AUTO_DEVOPS_BUILD_CACHE_MODE:-max}
registry_ref=${AUTO_DEVOPS_BUILD_CACHE_REF:-"${CI_APPLICATION_REPOSITORY}:cache"}

if [[ -n "$DOCKER_BUILDKIT" && "$DOCKER_BUILDKIT" != "0" ]]; then
  case "$cache_type" in
    inline)
      build_args+=(--cache-to type=inline) ;;
    registry)
      build_args+=(
        --cache-from "$registry_ref"
        --cache-to "type=registry,ref=$registry_ref,mode=$cache_mode"
      )
      # the docker-container driver is required for this cache type
      docker buildx create --use
      ;;
  esac

  docker buildx build \
    "${build_args[@]}" \
    --progress=plain \
    --push \
    . 2>&1
else
  echo "Attempting to pull a previously built image for use with --cache-from..."
  docker image pull --quiet "$image_previous" || \
    docker image pull --quiet "$image_latest" || \
    echo "No previously cached image found. The docker build will proceed without using a cached image"

  docker build "${build_args[@]}" .

  docker push "$image_tagged"
  docker push "$image_latest"
fi

gl_write_auto_build_variables_file
