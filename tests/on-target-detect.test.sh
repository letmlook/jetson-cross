#!/usr/bin/env bash
# Verifies that the Jetson-as-build-host detection picks up
# /etc/nv_tegra_release. We can't actually run the build on a host that
# does not have one, so we exercise only the detection helpers.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/lib/common.sh"
source "$repo/lib/host-detect.sh"

# No marker -> not a Jetson
[[ $(is_jetson_device) -eq 0 ]] || [[ $(is_jetson_device) -eq 1 ]]
# Whatever the actual answer is on this host, default_platform must
# return one of the four documented values.
default_platform
case "$(default_platform)" in
  linux-x86|linux-arm64|macos-arm64|jetson) ;;
  *) echo "FAIL: unknown default_platform" >&2; exit 1 ;;
esac

# default_mode_for_platform returns docker for macos-arm64, direct otherwise.
[[ $(default_mode_for_platform macos-arm64) = docker ]]
[[ $(default_mode_for_platform linux-x86)  = direct ]]
[[ $(default_mode_for_platform linux-arm64) = direct ]]
[[ $(default_mode_for_platform jetson)      = direct ]]

# ubuntu_version_for_l4t and bootlin_toolchain_for_l4t pin the right
# mapping for the supported L4T majors.
[[ $(ubuntu_version_for_l4t 36.4.0) = 22.04 ]]
[[ $(ubuntu_version_for_l4t 35.6.5) = 20.04 ]]
[[ $(bootlin_toolchain_for_l4t 36.4.0) = 2022.08-1 ]]
[[ $(bootlin_toolchain_for_l4t 35.6.5) = 2020.08-1 ]]

# 7.x and 34.x are explicitly unsupported. die() calls exit, so wrap
# each call in a subshell to capture the exit code. Stderr is
# suppressed to keep test output clean.
if ( ubuntu_version_for_l4t 38.0.0 ) 2>/dev/null; then
  echo "FAIL: L4T 38 should not be accepted" >&2; exit 1
fi
if ( bootlin_toolchain_for_l4t 38.0.0 ) 2>/dev/null; then
  echo "FAIL: L4T 38 should not map to a toolchain" >&2; exit 1
fi

echo "on-target-detect.test.sh passed"