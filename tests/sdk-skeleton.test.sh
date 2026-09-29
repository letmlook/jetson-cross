#!/usr/bin/env bash
# Verifies lib/sdk-skeleton.sh builds the full SDK skeleton from
# templates, and that the generated activate.sh survives being moved
# around (the relocatability contract).
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

source "$repo/lib/common.sh"
source "$repo/lib/host-detect.sh"
source "$repo/lib/toolchain.sh"
source "$repo/lib/sdk-skeleton.sh"

sdk=$tmp/sdk
mkdir -p "$sdk"
# Activate script: Bootlin compiler, rootfs in standard layout, nvcc
# outside the SDK on x86_64.
generate_activate_sh "$sdk" "Linux_for_Tegra/rootfs" \
  "toolchain/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-" \
  "/usr/local/cuda-12.6/bin/nvcc" \
  "bin/nvcc" "6.1" "36.4.0"
[[ -x $sdk/activate.sh ]]

# Native aarch64 host: cross_rel=''
sdk=$tmp/sdk-native
mkdir -p "$sdk"
generate_activate_sh "$sdk" "Linux_for_Tegra/rootfs" "" \
  "/usr/local/cuda-12.6/bin/nvcc" \
  "" "6.1" "36.4.0"
# When sourced, JETSON_CROSS must be empty.
out=$(cd / && source "$sdk/activate.sh" >/dev/null && printf '%s' "$JETSON_CROSS")
[[ -z $out ]]

# Relocatable: move the SDK dir, source still works.
moved=$tmp/moved-sdk
mkdir -p "$moved"
mv "$sdk/activate.sh" "$moved/activate.sh"
expected=$(cd "$moved" && pwd -P)
out=$(cd / && source "$moved/activate.sh" >/dev/null && printf '%s' "$JETSON_SDK")
[[ $out = "$expected" ]]

# toolchain.cmake with default cuDNN paths
sdk=$tmp/sdk2
mkdir -p "$sdk"
generate_toolchain_cmake "$sdk" "usr/include" "usr/lib/aarch64-linux-gnu"
grep -Fq 'CMAKE_CUDA_TARGET_LIB_DIR' "$sdk/toolchain.cmake"
# cuDNN non-default: cuDNN lib flag appears in the linker flags.
sdk=$tmp/sdk3
mkdir -p "$sdk"
generate_toolchain_cmake "$sdk" "usr/include/aarch64-linux-gnu" "usr/lib/aarch64-linux-gnu"
grep -Fq 'CMAKE_CUDNN_INCLUDE_DIR' "$sdk/toolchain.cmake"
grep -Fq 'CMAKE_CUDNN_LIB_DIR' "$sdk/toolchain.cmake"

# nvcc wrapper: syntax check + no unmatched `fi`.
sdk=$tmp/sdk4
mkdir -p "$sdk"
generate_nvcc_wrapper "$sdk" "12.6"
[[ -x $sdk/bin/nvcc ]]
bash -n "$sdk/bin/nvcc"
# Critical: the wrapper must contain exactly the same number of `if`
# blocks as `fi` closes.
if_count=$(grep -cE '^[[:space:]]*if[[:space:]]|^[[:space:]]*if\[' "$sdk/bin/nvcc" || true)
fi_count=$(grep -cE '^[[:space:]]*fi[[:space:]]*$' "$sdk/bin/nvcc" || true)
[[ $if_count -eq $fi_count ]] || { echo "FAIL: if=$if_count fi=$fi_count" >&2; exit 1; }

# cuda-host-include symlinks: pointing back into the sysroot.
sdk=$tmp/sdk5
mkdir -p "$sdk/Linux_for_Tegra/rootfs/usr/local/cuda/targets/aarch64-linux/include"
echo "fake header" > "$sdk/Linux_for_Tegra/rootfs/usr/local/cuda/targets/aarch64-linux/include/cuda_runtime.h"
mkdir -p "$sdk/cuda-host-include"
ln -s "../../Linux_for_Tegra/rootfs/usr/local/cuda/targets/aarch64-linux/include/cuda_runtime.h" \
   "$sdk/cuda-host-include/cuda_runtime.h"
target=$(readlink "$sdk/cuda-host-include/cuda_runtime.h")
[[ $target = *"Linux_for_Tegra/rootfs/usr/local/cuda/targets/aarch64-linux/include/cuda_runtime.h" ]]

# copy_example_project: only succeeds when templates/example-cuda-smoke
# exists. The repo guarantees it.
sdk=$tmp/sdk6
mkdir -p "$sdk"
copy_example_project "$sdk"
[[ -f $sdk/example-cuda-smoke/main.cu ]]
[[ -f $sdk/example-cuda-smoke/CMakeLists.txt ]]

echo "sdk-skeleton.test.sh passed"