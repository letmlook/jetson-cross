#!/usr/bin/env bash
set -euo pipefail

sdk=${1:?usage: $0 /absolute/path/to/jetson-sdk}
example="$sdk/example-cuda-smoke"
build="$example/build-final"

test -f "$example/CMakeLists.txt"
test -f "$example/main.cu"
source "$sdk/activate.sh"
cmake -S "$example" -B "$build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$sdk/toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$build"
"${JETSON_CROSS}readelf" -h "$build/jp61_cuda_smoke" | grep -q 'Machine:.*AArch64'
