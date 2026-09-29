# shellcheck shell=bash
# Online sysroot acquisition: rsync /lib, /usr, /opt off a live Jetson
# device. Used by the Jetson->host build path where the host is x86_64 and
# the target device is the same Jetson. The host never modifies the
# target.

# probe_target <user@host> <expected_l4t> <expected_cuda>
#
# SSHes into the device, reads nvidia-l4t-core, /usr/local/cuda/version.json
# (for CUDA), /usr/local/cuda symlink, and a handful of dev package
# versions. Compares to the requested L4T / CUDA, dies if they mismatch.
# Prints the resolved versions on stdout for the caller to log.
probe_target() {
  local target=$1 expected_l4t=$2 expected_cuda=$3
  command -v ssh >/dev/null || die 'Install openssh-client first'
  local remote
  remote=$(ssh -o BatchMode=yes "$target" 'set -e
    test "$(uname -m)" = aarch64
    dpkg-query -W -f="${Version}" nvidia-l4t-core
    echo
    if test -f /usr/local/cuda/version.json; then
      sed -n "s/.*\"version\"[[:space:]]*:[[:space:]]*\"\([0-9]*\.[0-9]*\).*$/\1/p" /usr/local/cuda/version.json | head -1
    fi
    readlink -f /usr/local/cuda || true
    dpkg-query -W -f="${Package} ${Version}\n" libnvinfer-dev libopencv-dev libgstreamer1.0-dev libavformat-dev 2>/dev/null || true
  ')
  local l4t major minor
  l4t=$(printf '%s\n' "$remote" | sed -n '1p')
  major=${expected_l4t%%.*}; minor=$(printf '%s' "$expected_l4t" | cut -d. -f2)
  local target_l4t
  target_l4t=$(printf '%s' "$l4t" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  [[ $target_l4t = "$expected_l4t" ]] || die "Requested L4T $expected_l4t but target has $l4t"
  local cuda_path target_cuda
  cuda_path=$(printf '%s\n' "$remote" | grep -m1 '^/usr/local/cuda-' || true)
  target_cuda=$(printf '%s\n' "$cuda_path" | sed -n 's@^/usr/local/cuda-\([0-9]*\.[0-9]*\).*@\1@p')
  [[ -n $target_cuda ]] || target_cuda=$(printf '%s\n' "$remote" | sed -n '2p' | grep -E '^[0-9]+\.[0-9]+$' || true)
  [[ $target_cuda = "$expected_cuda" ]] || die "Requested CUDA $expected_cuda but target CUDA is ${target_cuda:-undetected}. Check /usr/local/cuda."
  printf '%s\n' "$remote" | tail -n +4
}

# rsync_sysroot <target> <sdk_dir>
#
# Pulls /lib, /usr, /opt off the device into <sdk_dir>/sysroot. Requires
# either an SSH user that can read every file on the device, or `sudo -n
# rsync` configured on the target. Verifies the development libraries are
# present after the sync.
rsync_sysroot() {
  local target=$1 sdk=$2
  command -v rsync >/dev/null || die 'rsync is required for the online build'
  local root="$sdk/sysroot"
  mkdir -p "$root"
  for dir in lib usr opt; do
    mkdir -p "$root/$dir"
    sudo rsync -aH --numeric-ids --no-owner --no-group --delete \
      --rsync-path='sudo -n rsync' \
      "$target:/$dir/" "$root/$dir/" \
      || die 'Target sudo -n rsync failed. Grant read-only filesystem access through target sudoers, or run SSH as root.'
  done
  # Sanity check: at least one of the well-known headers must exist; if the
  # device is missing the development package the resulting SDK will
  # silently drop it.
  [[ -f $root/usr/include/NvInfer.h ]] \
    || die 'Target libnvinfer-dev/NvInfer.h missing. Install the development package on Jetson and rerun.'
  local path
  for path in \
    usr/include/opencv4/opencv2/core.hpp \
    usr/include/gstreamer-1.0/gst/gst.h \
    usr/include/libavformat/avformat.h
  do
    [[ -f $root/$path ]] || die "Target development header missing: /$path"
  done
}