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

# S1 + S8: the -dev packages for the ONNX parser and the FFmpeg
# filter/device components must be present. Without
# libnvonnxparsers-dev, find_library(nvonnxparser) misses the unversioned
# .so symlink and NvOnnxParser.h is absent, so any ONNX->engine converter
# target silently gets skipped. Without libavfilter-dev/libavdevice-dev,
# any project that puts them in pkg_check_modules(... REQUIRED) fails at
# configure time.
grep -F 'libnvonnxparsers-dev' "$repo/lib/rootfs-apt.sh" >/dev/null
grep -F 'libavfilter-dev'      "$repo/lib/rootfs-apt.sh" >/dev/null
grep -F 'libavdevice-dev'      "$repo/lib/rootfs-apt.sh" >/dev/null

# S7: libnvdla-compiler is attempted (warn-only) so libnvinfer.so's
# NEEDED libnvdla_compiler.so resolves; when the repo lacks it the
# workaround is documented rather than silently failing at link time.
grep -F 'libnvdla-compiler' "$repo/lib/rootfs-apt.sh" >/dev/null
grep -F -- '--allow-shlib-undefined' "$repo/lib/rootfs-apt.sh" >/dev/null

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

# --- S2: fix_cuda_alternatives -----------------------------------------
# NVIDIA's CUDA packages register /usr/local/cuda through Debian
# alternatives, leaving absolute links into /etc/alternatives. Those
# resolve against the HOST root, so a host with its own CUDA toolkit hands
# find_library(cudart) x86_64 libs and the link dies with `file in wrong
# format`. The rewrite must point both names at the versioned directory.
croot=$tmp/cuda-rootfs
mkdir -p "$croot/usr/local/cuda-12.6/targets/aarch64-linux"
mkdir -p "$croot/etc/alternatives"
ln -s /etc/alternatives/cuda    "$croot/usr/local/cuda"
ln -s /etc/alternatives/cuda-12 "$croot/usr/local/cuda-12"
fix_cuda_alternatives "$croot" "12.6"
[[ $(readlink "$croot/usr/local/cuda")    = cuda-12.6 ]]
[[ $(readlink "$croot/usr/local/cuda-12") = cuda-12.6 ]]
# The rewritten links are relative, so normalize_sysroot_symlinks must
# leave them alone (it only touches absolute links).
! grep -Fq '/etc/alternatives' <(readlink "$croot/usr/local/cuda")

# A rootfs without the versioned toolkit must warn but not create links.
croot2=$tmp/cuda-rootfs2
mkdir -p "$croot2/usr/local"
warn_out=$( ( fix_cuda_alternatives "$croot2" "12.6" ) 2>&1 )
grep -Fq 'missing' <<<"$warn_out" \
  || { echo "FAIL: fix_cuda_alternatives should warn without a toolkit" >&2; exit 1; }
[[ ! -e $croot2/usr/local/cuda ]] \
  || { echo "FAIL: fix_cuda_alternatives created a link without a toolkit" >&2; exit 1; }

echo "rootfs-apt.test.sh passed"