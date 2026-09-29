# shellcheck shell=bash
# Docker base-image management: building the linux/arm64 Ubuntu image that
# runs the offline flow inside Docker on macOS arm64 (and is also reusable
# for Linux hosts that want the same isolation).

# default_base_image_tag <platform> <ubuntu_version>
#
# Returns the local Docker image tag used for this platform + Ubuntu
# version combination.
default_base_image_tag() {
  local platform=$1 ubuntu_version=$2
  printf '%s' "jetson-cross-sdk-base:${platform}-ubuntu${ubuntu_version}"
}

# ensure_base_image <platform> <ubuntu_version> [<dockerfile> [<context>]]
#
# Builds the base image if it does not already exist. <dockerfile>
# defaults to docker/<platform>/Dockerfile and <context> defaults to the
# repo root.
ensure_base_image() {
  local platform=$1 ubuntu_version=$2
  local dockerfile=${3:-$(repo_root)/docker/${platform}/Dockerfile}
  local context=${4:-$(repo_root)}
  local tag
  tag=$(default_base_image_tag "$platform" "$ubuntu_version")
  if docker image inspect "$tag" >/dev/null 2>&1; then return 0; fi
  log "Building base image $tag from $dockerfile"
  local -a build_args=(--platform "linux/arm64" -f "$dockerfile"
    --build-arg "UBUNTU_VERSION=$ubuntu_version" -t "$tag" "$context")
  if [[ -n ${JETSON_DOCKER_BUILD_PROXY:-} ]]; then
    build_args+=(--build-arg "HTTP_PROXY=$JETSON_DOCKER_BUILD_PROXY"
                 --build-arg "HTTPS_PROXY=$JETSON_DOCKER_BUILD_PROXY")
  fi
  docker build "${build_args[@]}"
}

# resolve_docker_proxy
#
# Docker Desktop publishes a macOS loopback proxy into Linux containers.
# Rewrite 127.0.0.1/localhost/[::1] hosts to host.docker.internal so
# apt/curl can reach the same service.
normalize_docker_proxy() {
  local proxy=$1
  if [[ -n $proxy && $proxy != *://* ]]; then proxy="http://$proxy"; fi
  proxy=${proxy/\/\/127.0.0.1:/\/\/host.docker.internal:}
  proxy=${proxy/\/\/localhost:/\/\/host.docker.internal:}
  proxy=${proxy/\/\/\[::1\]:/\/\/host.docker.internal:}
  printf '%s' "$proxy"
}

# Returns the resolved HTTP/HTTPS/NoProxy values from `docker info`,
# normalized for use inside containers.
docker_proxy_settings() {
  DOCKER_HTTP_PROXY=$(normalize_docker_proxy "$(docker info --format '{{.HTTPProxy}}' 2>/dev/null || true)")
  DOCKER_HTTPS_PROXY=$(normalize_docker_proxy "$(docker info --format '{{.HTTPSProxy}}' 2>/dev/null || true)")
  DOCKER_NO_PROXY=$(docker info --format '{{.NoProxy}}' 2>/dev/null || true)
  export DOCKER_HTTP_PROXY DOCKER_HTTPS_PROXY DOCKER_NO_PROXY
}