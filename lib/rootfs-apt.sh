# shellcheck shell=bash
# Configure the Jetson apt source inside the offline rootfs and install
# the development stack. Jetson ships one version of each nvidia-* /
# cuda-* / libcudnn9-* package per L4T release, so installing by package
# name is enough — no version pinning or closure walking required.

# install_rootfs_dev_stack <root> <cuda_suffix>
#
# Does an `apt-get update` then installs:
#   - nvidia-jetpack-dev        (the umbrella JetPack development bundle)
#   - GStreamer + FFmpeg dev    (not bundled with nvidia-jetpack-dev)
#   - cuda-crt                  (compiler-internal CUDA headers; warn-only)
#   - OpenCV 4.5 ABI            (the NVIDIA one links to runtime libs that
#                                the Jetson repo never published, so we drop
#                                it and install the Ubuntu ABI explicitly)
#
# All installs are by package name only. Jetson repo versions each
# package by the L4T/JetPack release, so the right version is selected
# automatically.
install_rootfs_dev_stack() {
  local root=$1 cuda_suffix=$2
  rootfs_exec "$root" /bin/sh -c 'apt-get update'
  rootfs_exec "$root" /bin/sh -c \
    "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       nvidia-jetpack-dev \
       libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
       libavformat-dev libavcodec-dev libavutil-dev libswscale-dev \
       cuda-crt-${cuda_suffix} \
       libopencv-core4.5d libopencv-imgproc4.5d libopencv-dnn4.5d libopencv-dev" \
    || {
      warn 'Some packages were unavailable; the SDK may compile a subset of the development stack'
    }
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