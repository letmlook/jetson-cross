#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/jetson-versions.sh
source "$script_dir/lib/jetson-versions.sh"

usage() {
  cat >&2 <<EOF
Usage:
  $0 init [JETPACK_OR_L4T_VERSION]
  $0 image [JETPACK_OR_L4T_VERSION]
  $0 shell [--image] [JETPACK_OR_L4T_VERSION]
  $0 run [--image] [JETPACK_OR_L4T_VERSION] COMMAND [ARG ...]

The default version is JetPack $DEFAULT_JETPACK_VERSION.
EOF
  exit 2
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

[[ $# -ge 1 ]] || usage
action=$1
shift
case "$action" in init|image|shell|run) ;; *) usage ;; esac

use_image=false
if [[ ${1:-} = --image ]]; then
  use_image=true
  shift
fi
if [[ $action = init || $action = image ]] && $use_image; then usage; fi

version_input=
if [[ $action = run ]]; then
  if [[ ${1:-} =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    version_input=$1
    shift
  fi
  [[ $# -gt 0 ]] || usage
else
  if [[ $# -gt 0 ]]; then
    version_input=$1
    shift
  fi
  [[ $# -eq 0 ]] || usage
fi

resolve_jetson_version "$version_input" \
  || die "Unsupported JetPack/L4T version: ${version_input:-$DEFAULT_JETPACK_VERSION}"

[[ $(uname -s) = Darwin && $(uname -m) = arm64 ]] \
  || die 'This wrapper requires an Apple Silicon (macOS arm64) host'
command -v docker >/dev/null || die 'Docker Desktop is required'

normalize_docker_proxy() {
  local proxy=$1
  if [[ -n $proxy && $proxy != *://* ]]; then proxy="http://$proxy"; fi
  proxy=${proxy/\/\/127.0.0.1:/\/\/host.docker.internal:}
  proxy=${proxy/\/\/localhost:/\/\/host.docker.internal:}
  proxy=${proxy/\/\/\[::1\]:/\/\/host.docker.internal:}
  printf '%s' "$proxy"
}

# Docker Desktop can publish a macOS loopback proxy into Linux containers.
# Rewrite it to Docker's host gateway so apt/curl can reach the same service.
docker_http_proxy=$(normalize_docker_proxy "$(docker info --format '{{.HTTPProxy}}' 2>/dev/null || true)")
docker_https_proxy=$(normalize_docker_proxy "$(docker info --format '{{.HTTPSProxy}}' 2>/dev/null || true)")
docker_no_proxy=$(docker info --format '{{.NoProxy}}' 2>/dev/null || true)
proxy_build_args=()
proxy_run_args=()
if [[ -n $docker_http_proxy ]]; then
  proxy_build_args+=(--build-arg "HTTP_PROXY=$docker_http_proxy" --build-arg "http_proxy=$docker_http_proxy")
  proxy_run_args+=(-e "HTTP_PROXY=$docker_http_proxy" -e "http_proxy=$docker_http_proxy")
fi
if [[ -n $docker_https_proxy ]]; then
  proxy_build_args+=(--build-arg "HTTPS_PROXY=$docker_https_proxy" --build-arg "https_proxy=$docker_https_proxy")
  proxy_run_args+=(-e "HTTPS_PROXY=$docker_https_proxy" -e "https_proxy=$docker_https_proxy")
fi
if [[ -n $docker_no_proxy ]]; then
  proxy_build_args+=(--build-arg "NO_PROXY=$docker_no_proxy" --build-arg "no_proxy=$docker_no_proxy")
  proxy_run_args+=(-e "NO_PROXY=$docker_no_proxy" -e "no_proxy=$docker_no_proxy")
fi

l4t_major=${L4T_VERSION%%.*}
if [[ $l4t_major = 35 ]]; then host_ubuntu=20.04; else host_ubuntu=22.04; fi
base_image=${JETSON_CROSS_BASE_IMAGE:-jetson-cross-sdk-base:macos-arm64-ubuntu${host_ubuntu}}
volume="jetson-cross-sdk-${JETSON_VERSION_SLUG}-arm64"
snapshot_image="jetson-cross-sdk:${JETSON_VERSION_SLUG}-arm64"
project_dir=${JETSON_PROJECT_DIR:-$PWD}

if [[ -n $JETPACK_VERSION ]]; then
  log "Resolved JetPack $JETPACK_VERSION to L4T $L4T_VERSION"
else
  log "Using L4T $L4T_VERSION (no known JetPack mapping)"
fi

ensure_base_image() {
  if ! docker image inspect "$base_image" >/dev/null 2>&1; then
    log "Building ARM64 Ubuntu base image $base_image"
    docker build --platform linux/arm64 -f "$script_dir/docker/macos-arm64/Dockerfile" \
      --build-arg "UBUNTU_VERSION=$host_ubuntu" \
      ${proxy_build_args[@]+"${proxy_build_args[@]}"} -t "$base_image" "$script_dir"
  fi
}

ensure_volume() {
  docker volume inspect "$volume" >/dev/null 2>&1 || docker volume create "$volume" >/dev/null
}

check_volume_ready() {
  docker run --rm --platform linux/arm64 \
    ${proxy_run_args[@]+"${proxy_run_args[@]}"} \
    -v "$volume:/source-sdk:ro" "$base_image" \
    test -f /source-sdk/.setup-complete \
    || die "SDK volume $volume is incomplete; run '$0 init ${version_input:-$DEFAULT_JETPACK_VERSION}' first"
}

case "$action" in
  init)
    ensure_base_image
    ensure_volume
    log "Initializing $volume"
    docker run --rm --platform linux/arm64 --privileged \
      ${proxy_run_args[@]+"${proxy_run_args[@]}"} \
      -v "$volume:/opt/jetson-sdk" \
      -v "$script_dir:/opt/jetson-cross:ro" \
      "$base_image" \
      /opt/jetson-cross/setup-jetson-cross-sdk-offline.sh \
      "${version_input:-$DEFAULT_JETPACK_VERSION}" /opt/jetson-sdk
    ;;
  image)
    ensure_base_image
    ensure_volume
    check_volume_ready
    snapshot_container="jetson-cross-snapshot-${JETSON_VERSION_SLUG//./-}-$$"
    cleanup_snapshot() { docker rm -f "$snapshot_container" >/dev/null 2>&1 || true; }
    trap cleanup_snapshot EXIT
    log "Copying $volume into $snapshot_image"
    snapshot_id=$(docker create --platform linux/arm64 --name "$snapshot_container" \
      -v "$volume:/source-sdk:ro" "$base_image" sleep infinity)
    docker start "$snapshot_id" >/dev/null
    docker exec "$snapshot_id" sh -c \
      'mkdir -p /opt/jetson-sdk && cp -a /source-sdk/. /opt/jetson-sdk/'
    docker commit \
      --change "LABEL org.opencontainers.image.version=$JETSON_VERSION_SLUG" \
      --change "LABEL com.nvidia.jetson.l4t=$L4T_VERSION" \
      "$snapshot_id" "$snapshot_image" >/dev/null
    cleanup_snapshot
    trap - EXIT
    log "Image ready: $snapshot_image"
    ;;
  shell|run)
    mounts=(-v "$project_dir:/workspace" -w /workspace)
    if $use_image; then
      docker image inspect "$snapshot_image" >/dev/null 2>&1 \
        || die "Image $snapshot_image does not exist; run '$0 image ${version_input:-$DEFAULT_JETPACK_VERSION}' first"
      runtime_image=$snapshot_image
    else
      ensure_base_image
      ensure_volume
      check_volume_ready
      mounts=(-v "$volume:/opt/jetson-sdk" "${mounts[@]}")
      runtime_image=$base_image
    fi
    if [[ $action = shell ]]; then
      exec docker run --rm -it --platform linux/arm64 \
        ${proxy_run_args[@]+"${proxy_run_args[@]}"} "${mounts[@]}" "$runtime_image" bash
    else
      exec docker run --rm --platform linux/arm64 \
        ${proxy_run_args[@]+"${proxy_run_args[@]}"} "${mounts[@]}" "$runtime_image" "$@"
    fi
    ;;
esac
