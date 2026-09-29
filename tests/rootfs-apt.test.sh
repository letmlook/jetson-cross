#!/usr/bin/env bash
# Verifies the rootfs-apt module installs packages by name only (no
# version pinning) and rejects missing-header errors with a clear
# message. We can't run a real chroot in CI, so we exercise the package
# name derivation and the probe helpers.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

source "$repo/lib/common.sh"
source "$repo/lib/host-detect.sh"
source "$repo/lib/rootfs-apt.sh"

# Build a fake rootfs that mimics what nvidia-jetpack-dev / cuDNN install
# in the system include and lib directories.
root=$tmp/rootfs
mkdir -p "$root/usr/include" "$root/usr/include/aarch64-linux-gnu" \
         "$root/usr/lib/aarch64-linux-gnu"
: > "$root/usr/include/NvInfer.h"
: > "$root/usr/include/aarch64-linux-gnu/NvInfer.h"
: > "$root/usr/include/cudnn.h"
: > "$root/usr/lib/aarch64-linux-gnu/libcudnn.so"

# probe_nvinfer: must accept either /usr/include or the multiarch path
[[ $(probe_nvinfer "$root") = usr/include/aarch64-linux-gnu ]]
rm -f "$root/usr/include/aarch64-linux-gnu/NvInfer.h"
[[ $(probe_nvinfer "$root") = usr/include ]]

# probe_cudnn: sets CUDNN_INCLUDE_DIR + CUDNN_LIB_DIR globals
probe_cudnn "$root"
[[ $CUDNN_INCLUDE_DIR = usr/include ]]
[[ $CUDNN_LIB_DIR = usr/lib/aarch64-linux-gnu ]]

# A rootfs without cudnn.h must fail with a clear message.
rm -f "$root/usr/include/cudnn.h"
if ( probe_cudnn "$root" ) 2>/dev/null; then
  echo "FAIL: probe_cudnn should die without cudnn.h" >&2; exit 1
fi

# A rootfs without libcudnn.so must also fail.
: > "$root/usr/include/cudnn.h"
rm -f "$root/usr/lib/aarch64-linux-gnu/libcudnn.so"
if ( probe_cudnn "$root" ) 2>/dev/null; then
  echo "FAIL: probe_cudnn should die without libcudnn.so" >&2; exit 1
fi

# Install list sanity: install_rootfs_dev_stack is the only place we hand
# package names to apt. Verify the names we use do not contain "=..."
# style exact pins (the user asked to drop version pinning).
grep -F 'nvidia-jetpack-dev'    "$repo/lib/rootfs-apt.sh" >/dev/null
grep -F 'libgstreamer1.0-dev'  "$repo/lib/rootfs-apt.sh" >/dev/null
grep -F 'libavformat-dev'      "$repo/lib/rootfs-apt.sh" >/dev/null
grep -F 'cuda-crt-'            "$repo/lib/rootfs-apt.sh" >/dev/null
grep -F 'libopencv-dev'        "$repo/lib/rootfs-apt.sh" >/dev/null
# Negative: no "=version" pins inside the install invocation.
if grep -E '\-[0-9]+-[0-9]+=[0-9]' "$repo/lib/rootfs-apt.sh" >/dev/null; then
  echo "FAIL: install_rootfs_dev_stack pins a specific version" >&2
  exit 1
fi
# Negative: no --allow-downgrades.
if grep -F -- '--allow-downgrades' "$repo/lib/rootfs-apt.sh" >/dev/null; then
  echo "FAIL: install_rootfs_dev_stack should not use --allow-downgrades" >&2
  exit 1
fi

echo "rootfs-apt.test.sh passed"