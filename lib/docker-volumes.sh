# shellcheck shell=bash
# Docker volume lifecycle: ensure a per-JetPack-version volume exists and
# is in the right state (initialized with a finished SDK).

# default_volume_name <version_slug>
#
# Returns the volume name used to persist the SDK directory between
# invocations. <version_slug> is the resolved JetPack/L4T pair, e.g.
# jp6.1-l4t36.4.0.
default_volume_name() {
  printf '%s' "jetson-cross-sdk-${1}-arm64"
}

# ensure_volume <name>
#
# Creates the volume if it does not already exist. Idempotent.
ensure_volume() {
  local name=$1
  docker volume inspect "$name" >/dev/null 2>&1 || docker volume create "$name" >/dev/null
}

# check_volume_ready <volume> <base_image> [<sdk_subpath>]
#
# Returns 0 if the volume contains a finished SDK (sentinel file
# present), otherwise dies.
check_volume_ready() {
  local volume=$1 base_image=$2 subpath=${3:-/opt/jetson-sdk}
  local marker="$subpath/.setup-complete"
  docker run --rm --platform linux/arm64 \
    -v "$volume:$subpath:ro" "$base_image" \
    test -f "$marker" \
    || die "SDK volume $volume is incomplete; initialize it first"
}