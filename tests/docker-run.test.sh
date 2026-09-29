#!/usr/bin/env bash
# Verifies lib/docker-run.sh and lib/docker-base.sh assemble docker
# invocations correctly when proxy settings are present or absent.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

source "$repo/lib/common.sh"
source "$repo/lib/docker-base.sh"
source "$repo/lib/docker-volumes.sh"
source "$repo/lib/docker-run.sh"

# Volume name format
[[ $(default_volume_name jp6.1-l4t36.4.0) = jetson-cross-sdk-jp6.1-l4t36.4.0-arm64 ]]
[[ $(default_volume_name jp6.2.1-l4t36.4.4) = jetson-cross-sdk-jp6.2.1-l4t36.4.4-arm64 ]]

# Image tag format
[[ $(default_base_image_tag linux 22.04) = jetson-cross-sdk-base:linux-ubuntu22.04 ]]
[[ $(default_base_image_tag linux 20.04) = jetson-cross-sdk-base:linux-ubuntu20.04 ]]

# proxy_run_args: empty when no proxy
DOCKER_HTTP_PROXY=
DOCKER_HTTPS_PROXY=
DOCKER_NO_PROXY=
empty_args=$(proxy_run_args)
[[ -z $empty_args ]]

# proxy_run_args: emits -e KEY=VALUE pairs when proxy is set. Each
# element is on its own line, so we grep for the value alone.
DOCKER_HTTP_PROXY=http://host.docker.internal:3128
DOCKER_HTTPS_PROXY=http://host.docker.internal:3129
DOCKER_NO_PROXY=localhost,127.0.0.1
args=$(proxy_run_args)
grep -Fxq -- '-e' <<<"$args"
grep -Fxq -- 'HTTP_PROXY=http://host.docker.internal:3128' <<<"$args"
grep -Fxq -- 'http_proxy=http://host.docker.internal:3128' <<<"$args"
grep -Fxq -- 'HTTPS_PROXY=http://host.docker.internal:3129' <<<"$args"
grep -Fxq -- 'NO_PROXY=localhost,127.0.0.1' <<<"$args"

# normalize_docker_proxy rewrites loopback addresses to host.docker.internal
[[ $(normalize_docker_proxy http://127.0.0.1:8080) = http://host.docker.internal:8080 ]]
[[ $(normalize_docker_proxy http://localhost:8080) = http://host.docker.internal:8080 ]]
[[ $(normalize_docker_proxy http://[::1]:8080) = http://host.docker.internal:8080 ]]
[[ $(normalize_docker_proxy http://example.com:8080) = http://example.com:8080 ]]
# Bare hostnames get the http:// scheme prepended
[[ $(normalize_docker_proxy example.com:8080) = http://example.com:8080 ]]

echo "docker-run.test.sh passed"