# shellcheck shell=bash
# Configure the Jetson apt source inside the offline rootfs and install
# the development stack. Jetson ships one version of each nvidia-* /
# cuda-* / libcudnn9-* package per L4T release, so installing by package
# name is enough — no version pinning or closure walking required.

# install_rootfs_dev_stack <root> <cuda_suffix>
#
# Does an `apt-get update` then installs:
#   - nvidia-jetpack-dev        (the umbrella JetPack development bundle)
#   - GStreamer + FFmpeg dev    (not bundled with nvidia-jetpack-dev);
#                               includes libavfilter-dev / libavdevice-dev
#                               so pkg_check_modules(... REQUIRED) on those
#                               two does not fail at configure time
#   - cuda-crt                  (compiler-internal CUDA headers)
#   - libnvonnxparsers-dev      (ONNX parser: the -dev package is what
#                               ships the unversioned .so symlink and the
#                               NvOnnxParser.h / NvOnnxConfig.h headers;
#                               without it find_library(nvonnxparser)
#                               fails and the converter tool cannot build)
#   - OpenCV 4.5 ABI            (the NVIDIA one links to runtime libs that
#                                the Jetson repo never published, so we drop
#                                it and install the Ubuntu ABI explicitly)
#
# All installs are by package name only. Jetson repo versions each
# package by the L4T/JetPack release, so the right version is selected
# automatically.
#
# Constraint this function enforces: any library whose runtime package is
# installed must also have its -dev package installed, otherwise the SDK
# links but cannot compile against it.
install_rootfs_dev_stack() {
  local root=$1 cuda_suffix=$2
  rootfs_exec "$root" /bin/sh -c 'apt-get update'
  rootfs_exec "$root" /bin/sh -c \
    "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       nvidia-jetpack-dev \
       libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
       libavformat-dev libavcodec-dev libavutil-dev libswscale-dev \
       libavfilter-dev libavdevice-dev \
       cuda-crt-${cuda_suffix} \
       libnvonnxparsers-dev \
       libopencv-core4.5d libopencv-imgproc4.5d libopencv-dnn4.5d libopencv-dev" \
    || {
      warn 'Some packages were unavailable; the SDK may compile a subset of the development stack'
    }
  # libnvdla_compiler.so ships with the L4T DLA runtime but is not pulled
  # in by nvidia-jetpack-dev on every release. Without it, libnvinfer.so's
  # NEEDED entry cannot be resolved and linking a TensorRT program dies on
  # unresolved nvdla:: symbols. Try to install it; when the repo does not
  # offer it, callers must pass -Wl,--allow-shlib-undefined (documented in
  # the SDK usage guide).
  rootfs_exec "$root" /bin/sh -c \
    "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libnvdla-compiler" \
    || warn 'libnvdla-compiler not in the repo; TensorRT links will need -Wl,--allow-shlib-undefined'
}

# fix_cuda_alternatives <root> <cuda_version>
#
# NVIDIA's CUDA packages register /usr/local/cuda through Debian
# alternatives, which leaves absolute symlinks into /etc/alternatives.
# When the rootfs is used as a cross-compile sysroot on a host that also
# has a CUDA toolkit, those links resolve to the HOST's CUDA (x86_64
# libs), so find_library(cudart) picks up the wrong architecture and the
# link fails with `file in wrong format`. Rewrite both /usr/local/cuda
# and /usr/local/cuda-<major> to point at the versioned toolkit directory
# inside the rootfs, matching what alternatives would resolve to on a
# real Jetson device.
fix_cuda_alternatives() {
  local root=$1 cuda_version=$2
  local target="cuda-${cuda_version}"
  local major="cuda-${cuda_version%%.*}"
  if [[ -d $root/usr/local/$target ]]; then
    sudo ln -sfn "$target" "$root/usr/local/cuda"
    sudo ln -sfn "$target" "$root/usr/local/$major"
    log "Rewrote $root/usr/local/cuda -> $target (aarch64 toolkit, no host escape)"
  else
    warn "$root/usr/local/$target is missing; /usr/local/cuda may resolve to the host CUDA toolkit"
  fi
}

# probe_cudnn <root>
#
# Sets globals:
#   CUDNN_INCLUDE_DIR   path inside the rootfs (e.g. usr/include)
#   CUDNN_LIB_DIR       path inside the rootfs (e.g. usr/lib/aarch64-linux-gnu)
#
# Dies if either cudnn.h or libcudnn.so is missing.
probe_cudnn() {
  local root=$1
  local candidate
  CUDNN_INCLUDE_DIR=
  for candidate in usr/include usr/include/aarch64-linux-gnu usr/include/x86_64-linux-gnu; do
    if [[ -f $root/$candidate/cudnn.h ]]; then
      CUDNN_INCLUDE_DIR=$candidate
      break
    fi
  done
  [[ -n $CUDNN_INCLUDE_DIR ]] \
    || die 'cudnn.h missing after ARM64 apt install; the cuDNN dev package did not provide it'
  CUDNN_LIB_DIR=
  for candidate in usr/lib/aarch64-linux-gnu usr/lib usr/lib/x86_64-linux-gnu; do
    if [[ -f $root/$candidate/libcudnn.so ]]; then
      CUDNN_LIB_DIR=$candidate
      break
    fi
  done
  [[ -n $CUDNN_LIB_DIR ]] \
    || die 'libcudnn.so missing after ARM64 apt install; the cuDNN runtime package did not provide it'
  log "cuDNN headers in /$CUDNN_INCLUDE_DIR, libraries in /$CUDNN_LIB_DIR"
}

# probe_nvinfer <root>
#
# TensorRT headers can land in either /usr/include (older JetPack) or
# /usr/include/aarch64-linux-gnu (newer). Returns the directory that has
# NvInfer.h, or dies.
probe_nvinfer() {
  local root=$1
  local candidate
  for candidate in usr/include/aarch64-linux-gnu usr/include; do
    [[ -f $root/$candidate/NvInfer.h ]] && { printf '%s' "$candidate"; return; }
  done
  die 'NvInfer.h missing after ARM64 apt install; the TensorRT dev package did not provide it'
}

# build_cuda_host_include_symlinks <sdk> <root>
#
# Inside the SDK, create cuda-host-include/ that contains symlinks to the
# sysroot CUDA include tree. Used by the nvcc wrapper so a bare nvcc
# invocation (e.g. CMake's compiler-detection step) can still find CUDA
# headers without toolchain flags.
build_cuda_host_include_symlinks() {
  local sdk=$1 root=$2
  local dst="$sdk/cuda-host-include"
  local src="$root/usr/local/cuda/targets/aarch64-linux/include"
  sudo mkdir -p "$dst"
  sudo chown "$(id -un)" "$dst"
  if [[ -d $src ]]; then
    local f name
    for f in "$src"/*; do
      name=$(basename "$f")
      ln -sfn "../../Linux_for_Tegra/rootfs/usr/local/cuda/targets/aarch64-linux/include/$name" \
        "$dst/$name"
    done
  fi
}

# pkg_config_smoke_test <root>
#
# Exports PKG_CONFIG_* for the rootfs and runs `pkg-config --modversion`
# on the three packages the example project depends on. Asserts NvInfer.h
# is reachable.
pkg_config_smoke_test() {
  local root=$1
  export PKG_CONFIG_SYSROOT_DIR="$root"
  export PKG_CONFIG_LIBDIR="$root/usr/lib/aarch64-linux-gnu/pkgconfig:$root/usr/lib/pkgconfig:$root/usr/share/pkgconfig:$root/usr/local/lib/aarch64-linux-gnu/pkgconfig"
  unset PKG_CONFIG_PATH
  local pc
  for pc in opencv4 gstreamer-1.0 libavformat; do
    pkg-config --modversion "$pc" || die "pkg-config lookup failed for $pc"
  done
  probe_nvinfer "$root" >/dev/null
}