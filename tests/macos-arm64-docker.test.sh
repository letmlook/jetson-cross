#!/usr/bin/env bash
set -euo pipefail

# Regression contract: the macOS wrapper must keep the mutable SDK in a
# versioned volume, and must package that volume as a zstd-compressed tar without
# granting privileges to normal build or archive containers.
repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/setup-jetson-cross-sdk-macos-arm64.sh"
tmp=$(mktemp -d)
# The fake bin directory shadows `uname`, which cleanup tooling also uses to
# detect the platform. Restore the real PATH before removing the temp tree.
real_path=$PATH
trap 'PATH=$real_path; export PATH; rm -rf "$tmp"' EXIT
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
# When the wrapper asks to create an archive, write it to the host directory
# that was bind-mounted at /out so the follow-up assertions run on a real file.
case "$*" in
  *'zstd -T0'*) name=''; dest=''
    for arg in "$@"; do
      case "$arg" in
        ARCHIVE_NAME=*) name=${arg#ARCHIVE_NAME=} ;;
        *:/out) dest=${arg%:/out} ;;
      esac
    done
    if test -n "$name" && test -n "$dest"; then
      mkdir -p "$dest"
      : > "$dest/$name"
    fi ;;
esac
EOF
chmod +x "$fakebin/uname" "$fakebin/docker"

export DOCKER_LOG="$tmp/docker.log"
export FAKE_ARCHIVE_DIR="$tmp"
export FAKE_DOCKER_HTTP_PROXY=http.docker.internal:3128
export FAKE_DOCKER_HTTPS_PROXY=http://localhost:7892
export PATH="$fakebin:$PATH"
volume=jetson-cross-sdk-jp6.2.1-l4t36.4.4-arm64
base=jetson-cross-sdk-base:macos-arm64-ubuntu22.04

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

# Archiving writes a zstd-compressed tar of the volume and must not build a
# Docker image. An explicit output path keeps the archive in the temp dir.
: > "$DOCKER_LOG"
bash "$script" archive 6.2.1 "$tmp/jp6.2.1.tar.zst"
grep -Fq -- "-v $volume:/source-sdk:ro" "$DOCKER_LOG"
grep -Fq -- "test -f /source-sdk/.setup-complete" "$DOCKER_LOG"
grep -Fq -- "ARCHIVE_NAME=jp6.2.1.tar.zst" "$DOCKER_LOG"
grep -Fq -- 'zstd -T0 -q -o "/out/$ARCHIVE_NAME"' "$DOCKER_LOG"
[[ -f $tmp/jp6.2.1.tar.zst ]] || { echo 'FAIL: archive not written' >&2; exit 1; }
! grep -Fq -- 'commit' "$DOCKER_LOG"
! grep -Fq -- 'docker create' "$DOCKER_LOG"
! grep -Fq -- '--privileged' "$DOCKER_LOG"

# A relative output path is resolved against the current directory.
mkdir -p "$tmp/backup"
: > "$DOCKER_LOG"
(cd "$tmp" && bash "$script" archive 6.2.1 backup/custom.tar.zst)
grep -Fq -- "ARCHIVE_NAME=custom.tar.zst" "$DOCKER_LOG"
grep -Fq -- "$tmp/backup:/out" "$DOCKER_LOG"
[[ -f $tmp/backup/custom.tar.zst ]] || { echo 'FAIL: relative archive not written' >&2; exit 1; }

# The default output name carries the resolved version slug.
: > "$DOCKER_LOG"
(cd "$tmp" && bash "$script" archive 6.2.1)
grep -Fq -- "ARCHIVE_NAME=jetson-cross-sdk-jp6.2.1-l4t36.4.4-arm64.tar.zst" "$DOCKER_LOG"
[[ -f $tmp/jetson-cross-sdk-jp6.2.1-l4t36.4.4-arm64.tar.zst ]] \
  || { echo 'FAIL: default archive name not written' >&2; exit 1; }

# Restoring reads the archive back into the volume, again without privileges.
: > "$DOCKER_LOG"
printf 'payload' > "$tmp/restore-me.tar.zst"
bash "$script" restore 6.2.1 "$tmp/restore-me.tar.zst"
grep -Fq -- "-v $volume:/target" "$DOCKER_LOG"
grep -Fq -- 'tar --zstd -xf "/archive/$ARCHIVE_NAME" -C /target' "$DOCKER_LOG"
grep -Fq -- "$tmp:/archive:ro" "$DOCKER_LOG"
! grep -Fq -- '--privileged' "$DOCKER_LOG"

# A missing archive must fail loudly instead of silently doing nothing.
! bash "$script" restore 6.2.1 "$tmp/absent.tar.zst" 2>/dev/null

# The Docker image workflow is gone: no --image flag, no image subcommand.
! bash "$script" image 6.2.1 2>/dev/null
! bash "$script" run --image 6.2.1 true 2>/dev/null

: > "$DOCKER_LOG"
bash "$script" run 6.2.1 true
grep -Fq -- "-v $volume:/opt/jetson-sdk" "$DOCKER_LOG"
! grep -Fq -- '--privileged' "$DOCKER_LOG"

echo "macos-arm64 archive tests passed"
