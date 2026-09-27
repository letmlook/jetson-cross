#!/usr/bin/env bash
set -euo pipefail

# Regression contract: the macOS wrapper must keep the mutable SDK in a
# versioned volume, and must be able to copy that volume into an immutable
# image without granting privileges to normal build containers.
repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/setup-jetson-cross-sdk-macos-arm64.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fakebin="$tmp/bin"
mkdir -p "$fakebin"

cat > "$fakebin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -s) printf '%s\n' Darwin ;;
  -m) printf '%s\n' arm64 ;;
  *) exit 2 ;;
esac
EOF

cat > "$fakebin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_LOG"
if test "${1:-}" = info; then
  case "$*" in
    *'.HTTPProxy'*) printf '%s\n' "${FAKE_DOCKER_HTTP_PROXY:-}" ;;
    *'.HTTPSProxy'*) printf '%s\n' "${FAKE_DOCKER_HTTPS_PROXY:-}" ;;
    *'.NoProxy'*) printf '%s\n' "${FAKE_DOCKER_NO_PROXY:-}" ;;
  esac
fi
if test "${1:-} ${2:-}" = 'create --platform'; then
  printf '%s\n' jetson-snapshot-test
fi
EOF
chmod +x "$fakebin/uname" "$fakebin/docker"

export DOCKER_LOG="$tmp/docker.log"
export FAKE_DOCKER_HTTP_PROXY=http.docker.internal:3128
export FAKE_DOCKER_HTTPS_PROXY=http://localhost:7892
export PATH="$fakebin:$PATH"
volume=jetson-cross-sdk-jp6.2.1-l4t36.4.4-arm64
base=jetson-cross-sdk-base:macos-arm64-ubuntu22.04
snapshot=jetson-cross-sdk:jp6.2.1-l4t36.4.4-arm64

# Omitting a version selects JetPack 6.1.
: > "$DOCKER_LOG"
bash "$script" init
grep -Fq -- 'volume inspect jetson-cross-sdk-jp6.1-l4t36.4.0-arm64' "$DOCKER_LOG"
grep -Fq -- 'setup-jetson-cross-sdk-offline.sh 6.1 /opt/jetson-sdk' "$DOCKER_LOG"
grep -Fq -- 'HTTP_PROXY=http://http.docker.internal:3128' "$DOCKER_LOG"
grep -Fq -- 'HTTPS_PROXY=http://host.docker.internal:7892' "$DOCKER_LOG"

: > "$DOCKER_LOG"
bash "$script" init 6.2.1
grep -Fq -- "volume inspect $volume" "$DOCKER_LOG"
grep -Fq -- "--platform linux/arm64 --privileged" "$DOCKER_LOG"
grep -Fq -- "-v $volume:/opt/jetson-sdk" "$DOCKER_LOG"
grep -Fq -- "$base /opt/jetson-cross/setup-jetson-cross-sdk-offline.sh 6.2.1 /opt/jetson-sdk" "$DOCKER_LOG"

# JetPack 5/L4T 35 uses the matching Ubuntu 20.04 host image.
: > "$DOCKER_LOG"
bash "$script" init 5.1.7
grep -Fq -- 'jetson-cross-sdk-base:macos-arm64-ubuntu20.04' "$DOCKER_LOG"
grep -Fq -- '-v jetson-cross-sdk-jp5.1.7-l4t35.6.5-arm64:/opt/jetson-sdk' "$DOCKER_LOG"

# The equivalent L4T input must resolve to the same mutable environment.
: > "$DOCKER_LOG"
bash "$script" init 36.4.4
grep -Fq -- "volume inspect $volume" "$DOCKER_LOG"
grep -Fq -- "-v $volume:/opt/jetson-sdk" "$DOCKER_LOG"

: > "$DOCKER_LOG"
bash "$script" image 6.2.1
grep -Fq -- "-v $volume:/source-sdk:ro" "$DOCKER_LOG"
grep -Fq -- "test -f /source-sdk/.setup-complete" "$DOCKER_LOG"
grep -Fq -- "exec jetson-snapshot-test" "$DOCKER_LOG"
grep -Fq -- "commit" "$DOCKER_LOG"
grep -Fq -- "$snapshot" "$DOCKER_LOG"

: > "$DOCKER_LOG"
bash "$script" run 6.2.1 true
grep -Fq -- "-v $volume:/opt/jetson-sdk" "$DOCKER_LOG"
! grep -Fq -- '--privileged' "$DOCKER_LOG"

: > "$DOCKER_LOG"
bash "$script" run --image 36.4.4 true
grep -Fq -- "$snapshot true" "$DOCKER_LOG"
! grep -Fq -- "$volume:/opt/jetson-sdk" "$DOCKER_LOG"
! grep -Fq -- '--privileged' "$DOCKER_LOG"
