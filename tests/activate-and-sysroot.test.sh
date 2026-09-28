#!/usr/bin/env bash
set -euo pipefail

# Guards for the relocatable activation file and the sysroot fixes. Every
# assertion here corresponds to a defect that previously produced a silently
# broken SDK.

offline=./setup-jetson-cross-sdk-offline.sh
online=./setup-jetson-cross-sdk.sh

# ---------------------------------------------------------------- activate.sh
# The activation file must not bake in the directory it was generated in, or the
# SDK stops working as soon as it is moved, copied or mounted elsewhere.
for script in "$offline" "$online"; do
  grep -Fq 'BASH_SOURCE[0]' "$script"
  grep -Fq 'JETSON_SDK=$(cd "$(dirname "$__jetson_sdk_self")" && pwd -P)' "$script"
  grep -Fq 'unset __jetson_sdk_self' "$script"

  # The old form wrote the SDK path straight into the exported variables.
  ! grep -Fq "export JETSON_SDK='" "$script"
  ! grep -Fq "export JETSON_CROSS='" "$script"
  ! grep -Fq "export PKG_CONFIG_SYSROOT_DIR='" "$script"
  # JETSON_SDK_ACTIVATE_PATH existed only to relocate the generated paths.
  ! grep -Fq 'JETSON_SDK_ACTIVATE_PATH' "$script"
done

# toolchain.cmake reads the sysroot from JETSON_ROOTFS, which activate.sh
# derives from its own location. The offline script writes it through an
# unquoted heredoc, so the literal source carries an escaped "$".
for script in "$offline" "$online"; do
  grep -Eq 'set\(CMAKE_SYSROOT "\\?\$ENV\{JETSON_ROOTFS\}"\)' "$script"
  grep -Fq 'JETSON_ROOTFS="$JETSON_SDK/' "$script"
done

# ------------------------------------------------------------------- sysroot
# Absolute symlinks inside the rootfs resolve against the host root, so they
# must be rewritten. The online script had this; the offline one did not.
grep -Fq 'normalize_rootfs_symlinks' "$offline"
grep -Fq 'root not in dest.parents or not dest.exists()' "$offline"
grep -Fq 'link.symlink_to(relative)' "$offline"
grep -Fq 'escaping-symlinks.txt' "$offline"

# The report must document why the remaining links were left alone.
grep -Fq 'Absolute symlinks kept as-is' "$offline"

# ------------------------------------------------------- toolchain.cmake paths
for script in "$offline" "$online"; do
  # Debian multiarch keeps libc headers in usr/include/aarch64-linux-gnu.
  # CMAKE_SYSROOT alone only adds usr/include, so <math.h> would not resolve.
  grep -Fq 'usr/include/aarch64-linux-gnu' "$script"
  grep -Fq 'CMAKE_CXX_FLAGS_INIT' "$script"
  # The CUDA runtime lives in a target-specific directory no default path covers.
  grep -Fq 'CMAKE_CUDA_TARGET_LIB_DIR' "$script"
  grep -Fq 'targets/aarch64-linux/lib' "$script"
  # An incomplete sysroot CUDA tree must not shadow the host nvcc headers.
  grep -Fq 'crt/host_config.h' "$script"
done

# ------------------------------------------------------------------ smoke test
# The old check compiled `int main(){return 0;}`, which passes even when the
# multiarch include path and the escaping symlinks are broken.
grep -Fq 'smoke-sysroot-aarch64' "$offline"
grep -Fq '#include <zlib.h>' "$offline"
grep -Fq 'Shared library: \[libm.so.6\]' "$offline"

# cuda_runtime.h includes "crt/host_config.h", which ships in cuda-crt only.
grep -Fq 'cuda-crt-$cuda_suffix' "$offline"
# Without CMAKE_LIBRARY_ARCHITECTURE, find_library(cudnn) never searches the
# Debian multiarch directory and silently fails.
for script in "$offline" "$online"; do
  grep -Fq 'set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)' "$script"
done

# cuda_runtime_api.h also needs crt/, so an incomplete sysroot CUDA tree must
# fall back to the headers next to CUDACXX rather than shadowing them.
for script in "$offline" "$online"; do
  grep -Fq 'CMAKE_CUDA_INCLUDE_DIR' "$script"
  grep -Fq 'CUDACXX}/../../include' "$script"
done

# ----------------------------------------------------------------------- cuDNN
# An earlier package list silently omitted cuDNN and nothing detected it, so
# the SDK reported success while no cuDNN code could be built.
grep -Fq 'libcudnn9-dev-cuda-12' "$offline"
grep -Fq 'libcudnn9-cuda-12' "$offline"
# Presence on disk is not enough: the headers land in a non-obvious directory,
# so they must be located and the directory added to the toolchain.
grep -Fq 'cudnn.h missing after ARM64 apt install' "$offline"
grep -Fq 'libcudnn.so missing after ARM64 apt install' "$offline"
grep -Fq 'CMAKE_CUDNN_INCLUDE_DIR' "$offline"
grep -Fq 'CMAKE_CUDNN_LIB_DIR' "$offline"
# And it must be proven to compile and link.
grep -Fq 'smoke-cudnn-aarch64' "$offline"
grep -Fq '#include <cudnn.h>' "$offline"
grep -Fq 'did not link against the sysroot libcudnn' "$offline"

# ------------------------------------------------------- nvidia-* JetPack bundle
# The Jetson repository ships its own build of nvidia-jetpack-dev and of every
# nvidia-* package it depends on, so apt must resolve the set without a manual
# version pin, and the explicit component list stays as a fallback.
grep -Fq 'apt-cache show nvidia-jetpack-dev' "$offline"
grep -Fq 'apt-get install -y --no-install-recommends nvidia-jetpack-dev"' "$offline"
grep -Fq 'Falling back to the explicit component list' "$offline"
! grep -Fq 'nvidia-jetpack-dev=$' "$offline"
# nvidia-jetpack-dev pins the broken NVIDIA libopencv-dev 4.8.0, so the bundle
# must be dropped before the working Ubuntu 4.5 ABI is installed.
grep -Fq 'apt-get remove -y --no-install-recommends nvidia-opencv-dev nvidia-opencv' "$offline"
grep -Fq -- '--allow-downgrades' "$offline"
grep -Fq 'libopencv-dev=4.5.4+dfsg-9ubuntu4' "$offline"

# ----------------------------------------------------------------- toolchain.cmake
# The offline script must still write an executable activation file.
grep -Fq 'chmod 0755 "$sdk/activate.sh"' "$offline"
grep -Fq 'chmod 0755 "$SDK/activate.sh"' "$online"

# ------------------------------------------------------------ generated output
# Rendering both generated files must not fail or emit empty bodies.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sdk="$tmp/sdk"
mkdir -p "$sdk"
root="$sdk/Linux_for_Tegra/rootfs"

# activate.sh: derive JETSON_SDK from the script location, then build every
# other path from JETSON_ROOTFS.
cat > "$sdk/activate.sh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  __jetson_sdk_self=${BASH_SOURCE[0]}
else
  __jetson_sdk_self=$0
fi
JETSON_SDK=$(cd "$(dirname "$__jetson_sdk_self")" && pwd -P)
unset __jetson_sdk_self
JETSON_ROOTFS="$JETSON_SDK/Linux_for_Tegra/rootfs"
__jetson_cross_rel='toolchain/x/bin/aarch64-buildroot-linux-gnu-'
if [ -n "$__jetson_cross_rel" ]; then
  JETSON_CROSS="$JETSON_SDK/$__jetson_cross_rel"
else
  JETSON_CROSS=
fi
unset __jetson_cross_rel
export JETSON_SDK JETSON_ROOTFS JETSON_CROSS
export CROSS_COMPILE="$JETSON_CROSS"
printf '%s\n' "$JETSON_SDK"
EOF
chmod 0755 "$sdk/activate.sh"

# Sourcing it from an unrelated working directory must still resolve correctly.
out=$(cd / && source "$sdk/activate.sh" > /dev/null && printf '%s\n%s\n' "$JETSON_SDK" "$JETSON_ROOTFS")
[[ ${out%%$'\n'*} == "$(cd "$sdk" && pwd -P)" ]]
[[ ${out#*$'\n'} == "$(cd "$sdk" && pwd -P)/Linux_for_Tegra/rootfs" ]]

# Moving the whole SDK directory must not break the activation file.
moved="$tmp/moved-sdk"
mkdir -p "$moved"
mv "$sdk/activate.sh" "$moved/activate.sh"
out=$(cd / && source "$moved/activate.sh" > /dev/null && printf '%s' "$JETSON_SDK")
[[ $out == "$(cd "$moved" && pwd -P)" ]]

# A relative source path must work too.
out=$(cd "$moved" && source ./activate.sh > /dev/null && printf '%s' "$JETSON_SDK")
[[ $out == "$(cd "$moved" && pwd -P)" ]]

# Executing rather than sourcing exercises the $0 branch and must agree.
out=$(cd / && "$moved/activate.sh")
[[ $out == "$(cd "$moved" && pwd -P)" ]]

# The generated file must carry no absolute path from generation time.
! grep -Eq "^[^#]*['\"]/[a-zA-Z0-9_.-]+/jetson-cross-sdk" "$moved/activate.sh"

echo "activate-relocation tests passed"
