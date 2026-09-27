#!/usr/bin/env bash
set -euo pipefail

# Regression contract: public scripts accept either version family, and
# equivalent JetPack/L4T inputs normalize to the same canonical identity.
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/lib/jetson-versions.sh"

[[ $DEFAULT_JETPACK_VERSION = 6.1 ]]
resolve_jetson_version ''
[[ $JETPACK_VERSION = 6.1 ]]
[[ $L4T_VERSION = 36.4.0 ]]
[[ $JETSON_VERSION_SLUG = jp6.1-l4t36.4.0 ]]

resolve_jetson_version 6.2.1
[[ $JETPACK_VERSION = 6.2.1 ]]
[[ $L4T_VERSION = 36.4.4 ]]
[[ $JETSON_VERSION_SLUG = jp6.2.1-l4t36.4.4 ]]

resolve_jetson_version 36.4.4
[[ $JETPACK_VERSION = 6.2.1 ]]
[[ $L4T_VERSION = 36.4.4 ]]
[[ $JETSON_VERSION_SLUG = jp6.2.1-l4t36.4.4 ]]

# NVIDIA published JetPack 5.1.5 with two BSP revisions. The shorthand uses
# the newer one; callers can still request 35.6.1 explicitly.
resolve_jetson_version 5.1.5
[[ $JETPACK_VERSION = 5.1.5 ]]
[[ $L4T_VERSION = 35.6.2 ]]
resolve_jetson_version 35.6.1
[[ $JETPACK_VERSION = 5.1.5 ]]
[[ $L4T_VERSION = 35.6.1 ]]

# A syntactically valid L4T 35/36 release remains usable with local archives
# even when NVIDIA did not assign it a JetPack marketing version.
resolve_jetson_version 36.4.2
[[ -z $JETPACK_VERSION ]]
[[ $L4T_VERSION = 36.4.2 ]]
[[ $JETSON_VERSION_SLUG = l4t36.4.2 ]]

if resolve_jetson_version 7.0; then
  echo 'JetPack 7 unexpectedly accepted' >&2
  exit 1
fi
if resolve_jetson_version 34.1.1; then
  echo 'unsupported L4T major unexpectedly accepted' >&2
  exit 1
fi
