# shellcheck shell=bash
# Build the SDK on the Jetson device itself. The device already has a
# working aarch64 g++, a /usr/local/cuda tree, and all the system
# libraries we would otherwise download. The "rootfs" the build runs
# against is the device's own rootfs, with the BSP apply_binaries.sh step
# skipped and the chroot apparatus unused.

# assert_jetson_toolchain
#
# Verifies that the device's native toolchain and CUDA install are usable
# for cross-compiling to itself.
assert_jetson_toolchain() {
  command -v g++ >/dev/null       || die 'Jetson device is missing g++'
  command -v readelf >/dev/null   || die 'Jetson device is missing readelf'
  [[ -x /usr/local/cuda/bin/nvcc || -d /usr/local/cuda-12.6 ]] \
    || warn 'No CUDA installation detected at /usr/local/cuda; CUDA toolchain may not work'
}

# build_on_target <sdk_dir>
#
# Sets up an SDK directory whose sysroot is the live Jetson rootfs. We
# bind-mount the device's filesystem tree into <sdk>/sysroot using
# hardlink-preserving rsync so the SDK stays self-contained for offline
# use later, while reusing the device's installed packages.
build_on_target() {
  local sdk=$1
  mkdir -p "$sdk/sysroot"
  local dir
  for dir in lib usr opt; do
    mkdir -p "$sdk/sysroot/$dir"
    # rsync from the local filesystem (the Jetson) into the SDK. --numeric-ids
    # keeps uid/gid stable so files moved off-device keep their ownership.
    rsync -aH --numeric-ids --no-owner --no-group --delete \
      "/$dir/" "$sdk/sysroot/$dir/"
  done
  # Sanity check that the device really has the development packages
  # the SDK will need.
  local path
  for path in \
    usr/include/NvInfer.h \
    usr/include/opencv4/opencv2/core.hpp \
    usr/include/gstreamer-1.0/gst/gst.h \
    usr/include/libavformat/avformat.h
  do
    [[ -f $sdk/sysroot/$path ]] || warn "Jetson is missing /$path; some example builds will fail"
  done
}

# teardown_on_target
#
# Empty for now; the on-target build does not bind-mount, so there is
# nothing to undo. Defined so the entry script can call a uniform
# teardown at the end of every build.
teardown_on_target() { :; }