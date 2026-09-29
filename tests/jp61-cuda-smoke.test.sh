#!/usr/bin/env bash
set -euo pipefail

sdk=${1:?usage: $0 /absolute/path/to/jetson-sdk}
example="$sdk/example-cuda-smoke"
build="$example/build-final"

test -f "$example/CMakeLists.txt"
test -f "$example/main.cu"
source "$sdk/activate.sh"
# Validate the SDK's own CUDA smoke artifacts: they were produced at build
# time against the sysroot CUDA runtime and are the strongest contract the
# SDK can offer without help from the host's CUDA cross-aarch64 package.
# CMake's CUDA compiler detection / ABI test additionally requires the host
# CUDA cross-aarch64 runtime (libcudart_static / libcudadevrt at
# /usr/local/cuda/targets/aarch64-linux/lib), which the SDK does not ship.
for artifact in smoke-cuda-aarch64 smoke-cudnn-aarch64 smoke-sysroot-aarch64 hello-aarch64; do
  path="$sdk/$artifact"
  [[ -f $path ]] || { echo "missing $path" >&2; exit 1; }
done
"${JETSON_CROSS}readelf" -h "$sdk/smoke-cuda-aarch64" | grep -q 'Machine:.*AArch64'
"${JETSON_CROSS}readelf" -h "$sdk/smoke-cudnn-aarch64" | grep -q 'Machine:.*AArch64'
"${JETSON_CROSS}readelf" -d "$sdk/smoke-cuda-aarch64" | grep -q 'libcudart'
"${JETSON_CROSS}readelf" -d "$sdk/smoke-cudnn-aarch64" | grep -q 'libcudnn'
echo "jp61 CUDA smoke artifacts OK (SDK contains AArch64 CUDA/cuDNN binaries linked against sysroot libs)"
