#!/usr/bin/env bash
# Verifies every template in templates/ renders to a syntactically valid
# file. The renderer is the same code path used by jetson-cross build,
# but called with canned inputs.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Source common.sh, host-detect.sh, and the modules we need.
source "$repo/lib/common.sh"
source "$repo/lib/host-detect.sh"
source "$repo/lib/toolchain.sh"
source "$repo/lib/nvcc.sh"
source "$repo/lib/sdk-skeleton.sh"
source "$repo/lib/docs.sh"

# Build the activate.sh
sdk=$tmp/sdk
mkdir -p "$sdk"
JETPACK_VERSION=6.1
L4T_VERSION=36.4.0
JETSON_VERSION_SLUG=jp6.1-l4t36.4.0
generate_activate_sh "$sdk" "Linux_for_Tegra/rootfs" \
  "toolchain/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-" \
  "/usr/local/cuda-12.6/bin/nvcc" \
  "bin/nvcc" \
  "$JETPACK_VERSION" "$L4T_VERSION" "12.6"
[[ -x $sdk/activate.sh ]]
bash -n "$sdk/activate.sh"

# Activate.sh must derive every path from its own location (no absolute
# host paths in source).
if grep -Eq '^[^#]*['\''"]/[a-zA-Z0-9_.-]+/jetson-cross-sdk' "$sdk/activate.sh"; then
  echo "FAIL: activate.sh has an absolute path baked in" >&2
  exit 1
fi

# CUDA cross-discovery variables (FindCUDA's cross-compiling branch reads
# only these two). Without them, find_package(CUDA) either fails to locate
# CUDA_TOOLKIT_INCLUDE or runs the rootfs aarch64 nvcc on the host.
grep -Fq 'CUDA_TOOLKIT_ROOT=' "$sdk/activate.sh"
grep -Fq 'CUDA_NVCC_EXECUTABLE=' "$sdk/activate.sh"
grep -Fq 'CUDAFLAGS=' "$sdk/activate.sh"
# CUDA_TOOLKIT_ROOT must prefer the versioned directory over the
# alternatives symlink, which resolves to the host toolkit on a host with
# CUDA installed.
grep -Fq 'usr/local/cuda-12.6' "$sdk/activate.sh"
# CUDA_NVCC_EXECUTABLE must be captured BEFORE the wrapper override so
# FindCUDA runs a real host nvcc, not the SDK wrapper.
nvcc_capture_line=$(grep -n 'CUDA_NVCC_EXECUTABLE=' "$sdk/activate.sh" | head -1 | cut -d: -f1)
wrapper_override_line=$(grep -n 'CUDACXX="$__jetson_cuda_wrapper"' "$sdk/activate.sh" | head -1 | cut -d: -f1)
[[ -n $nvcc_capture_line && -n $wrapper_override_line && $nvcc_capture_line -lt $wrapper_override_line ]] \
  || { echo "FAIL: CUDA_NVCC_EXECUTABLE must be captured before the wrapper override" >&2; exit 1; }

# Sourcing activate.sh from /tmp must still resolve JETSON_SDK to the
# SDK's absolute path.
sdk_abs=$(cd "$sdk" && pwd -P)
out=$(cd / && source "$sdk/activate.sh" >/dev/null && printf '%s\n' "$JETSON_SDK")
[[ $out = "$sdk_abs" ]]

# Move the SDK dir; activate.sh must still resolve correctly.
moved=$tmp/moved
mkdir -p "$moved"
mv "$sdk/activate.sh" "$moved/activate.sh"
moved_abs=$(cd "$moved" && pwd -P)
out=$(cd / && source "$moved/activate.sh" >/dev/null && printf '%s' "$JETSON_SDK")
[[ $out = "$moved_abs" ]]

# Build the toolchain.cmake
sdk=$tmp/sdk2
mkdir -p "$sdk"
generate_toolchain_cmake "$sdk" "usr/include" "usr/lib/aarch64-linux-gnu"
[[ -f $sdk/toolchain.cmake ]]
# toolchain.cmake must not be syntactically broken (we just check it's
# not empty and contains key CMake settings).
[[ -s $sdk/toolchain.cmake ]]
grep -Fq 'CMAKE_SYSTEM_PROCESSOR aarch64' "$sdk/toolchain.cmake"
grep -Fq 'CMAKE_CUDA_TARGET_LIB_DIR' "$sdk/toolchain.cmake"
grep -Fq 'crt/host_config.h' "$sdk/toolchain.cmake"

# S5: all three link types must carry the same flags, and the flags must
# include --sysroot so Ubuntu's libc.so linker script (which bakes in
# absolute paths) is relocated into the sysroot. Without this a SHARED
# link dies with `ld: cannot find /lib/aarch64-linux-gnu/libc.so.6`.
grep -Fq 'CMAKE_EXE_LINKER_FLAGS_INIT' "$sdk/toolchain.cmake"
grep -Fq 'CMAKE_SHARED_LINKER_FLAGS_INIT' "$sdk/toolchain.cmake"
grep -Fq 'CMAKE_MODULE_LINKER_FLAGS_INIT' "$sdk/toolchain.cmake"
grep -Fq -- '--sysroot=${CMAKE_SYSROOT}' "$sdk/toolchain.cmake"
grep -Fq '_JETSON_LINK_FLAGS' "$sdk/toolchain.cmake"

# S6: rpath-link must cover Ubuntu's subdirectory layout. Missing any of
# these surfaces as `undefined reference to cgbtrs_/sposvx_/...` when
# OpenCV pulls in the armadillo -> blas/lapack chain.
for sub in lapack blas nvidia tegra; do
  grep -Fq "usr/lib/aarch64-linux-gnu/$sub" "$sdk/toolchain.cmake" \
    || { echo "FAIL: rpath-link missing $sub subdir" >&2; exit 1; }
done

# S9: OpenCV_DIR must be auto-set when the config lives in the Debian
# multiarch directory, which find_package(OpenCV) does not search under a
# buildroot toolchain.
grep -Fq 'OpenCV_DIR' "$sdk/toolchain.cmake"
grep -Fq 'cmake/opencv4' "$sdk/toolchain.cmake"

# S10: the compile-side --sysroot discipline must be documented in the
# toolchain file itself, not only in the prose docs.
grep -Fq 'COMPILE-SIDE --sysroot DISCIPLINE' "$sdk/toolchain.cmake"
# And --sysroot must NOT appear in the compile-side flag initialisers.
if grep -E '^set\(CMAKE_(C|CXX|CUDA)_FLAGS_INIT' "$sdk/toolchain.cmake" | grep -q -- '--sysroot'; then
  echo "FAIL: --sysroot leaked into compile-side flags" >&2
  exit 1
fi

# Same again with cuDNN in a non-default directory (the lib path triggers
# the cuDNN extra flag generation).
sdk=$tmp/sdk3
mkdir -p "$sdk"
generate_toolchain_cmake "$sdk" "usr/include/aarch64-linux-gnu" "usr/lib/aarch64-linux-gnu"
grep -Fq 'CMAKE_CUDNN_INCLUDE_DIR' "$sdk/toolchain.cmake"
grep -Fq 'CMAKE_CUDNN_LIB_DIR' "$sdk/toolchain.cmake"

# Build the nvcc wrapper
sdk=$tmp/sdk4
mkdir -p "$sdk"
generate_nvcc_wrapper "$sdk" "12.6"
[[ -x $sdk/bin/nvcc ]]
bash -n "$sdk/bin/nvcc"
grep -Fq 'cuda-12.6' "$sdk/bin/nvcc"
# Critical: the old bug left an unmatched `fi` inside the wrapper; that
# would have made bash refuse to parse it.
if grep -Eq '^[[:space:]]*fi[[:space:]]*$' "$sdk/bin/nvcc" \
   && ! grep -Eq '^[[:space:]]*if[[:space:]]' "$sdk/bin/nvcc"; then
  echo "FAIL: nvcc wrapper has stray fi without matching if" >&2
  exit 1
fi

# Render the SDK usage guide (standalone, no build context needed).
guide=$tmp/usage-guide.md
JETPACK_VERSION=6.1
L4T_VERSION=36.4.0
JETSON_VERSION_SLUG=jp6.1-l4t36.4.0
cuda_version=12.6
render_usage_guide_sdk --out "$guide"
[[ -s $guide ]]
grep -Fq 'JetPack 6.1' "$guide"
grep -Fq 'L4T 36.4.0' "$guide"

# S10: the compile-side --sysroot discipline must be in the shipped guide.
grep -Fq '编译侧绝对不要自己加' "$guide"
# S11: host toolkit vs rootfs CUDA version pairing must be explained.
grep -Fq '宿主 toolkit 与 rootfs CUDA 的版本配套' "$guide"
# S7: the libnvdla / --allow-shlib-undefined workaround must be documented.
grep -Fq 'allow-shlib-undefined' "$guide"
grep -Fq 'libnvdla_compiler' "$guide"
# S8: the rootfs package inventory must be listed so consumers know which
# pkg_check_modules(...) can be REQUIRED.
grep -Fq 'rootfs 包集清单' "$guide"
grep -Fq 'libnvonnxparser' "$guide"
grep -Fq 'libavfilter' "$guide"
# S4: the FindCUDA cross variables must be documented.
grep -Fq 'CUDA_TOOLKIT_ROOT' "$guide"
grep -Fq 'CUDA_NVCC_EXECUTABLE' "$guide"

# example-cuda-smoke template directory must contain main.cu and CMakeLists.txt
example=$repo/templates/example-cuda-smoke
[[ -f $example/CMakeLists.txt ]]
[[ -f $example/main.cu ]]
[[ -f $example/README.md ]]

echo "templates-render.test.sh passed"