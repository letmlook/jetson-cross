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
  "$JETPACK_VERSION" "$L4T_VERSION"
[[ -x $sdk/activate.sh ]]
bash -n "$sdk/activate.sh"

# Activate.sh must derive every path from its own location (no absolute
# host paths in source).
if grep -Eq '^[^#]*['\''"]/[a-zA-Z0-9_.-]+/jetson-cross-sdk' "$sdk/activate.sh"; then
  echo "FAIL: activate.sh has an absolute path baked in" >&2
  exit 1
fi

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

# example-cuda-smoke template directory must contain main.cu and CMakeLists.txt
example=$repo/templates/example-cuda-smoke
[[ -f $example/CMakeLists.txt ]]
[[ -f $example/main.cu ]]
[[ -f $example/README.md ]]

echo "templates-render.test.sh passed"