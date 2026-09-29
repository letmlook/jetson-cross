# shellcheck shell=bash
# Build the SDK skeleton: activate.sh, toolchain.cmake, the CUDA host-include
# symlinks, the nvcc wrapper, the example project, and the inline smoke
# tests that prove a real cross-compile works.

# generate_activate_sh <sdk> <rootfs_rel> <cross_rel> <nvcc_rel> <cuda_wrapper_rel> <jetpack> <l4t>
#
# Writes <sdk>/activate.sh from templates/activate.sh.tmpl. The five path
# slots are stored as relative paths so the file survives being moved.
generate_activate_sh() {
  local sdk=$1 rootfs_rel=$2 cross_rel=$3 nvcc_rel=$4 wrapper_rel=$5 jetpack=$6 l4t=$7
  local template="$JETSON_CROSS_LIB_DIR/../templates/activate.sh.tmpl"
  install -m 0755 /dev/null "$sdk/activate.sh"
  sed \
    -e "s|@JETPACK@|$jetpack|g" \
    -e "s|@L4T@|$l4t|g" \
    -e "s|@ROOTFS_REL@|$rootfs_rel|g" \
    -e "s|@CROSS_REL@|$cross_rel|g" \
    -e "s|@NVCC_REL@|$nvcc_rel|g" \
    -e "s|@CUDA_WRAPPER_REL@|$wrapper_rel|g" \
    "$template" > "$sdk/activate.sh"
  chmod 0755 "$sdk/activate.sh"
}

# generate_toolchain_cmake <sdk> <cudnn_include_dir> <cudnn_lib_dir>
#
# Writes <sdk>/toolchain.cmake from templates/toolchain.cmake.tmpl,
# pre-computing the cuDNN-specific include and library flags.
generate_toolchain_cmake() {
  local sdk=$1 cudnn_inc=$2 cudnn_lib=$3
  local template="$JETSON_CROSS_LIB_DIR/../templates/toolchain.cmake.tmpl"
  local cudnn_inc_flag=""
  local cudnn_lib_flag=""
  if [[ $cudnn_inc != usr/include ]]; then
    cudnn_inc_flag=" -isystem\\\ \${CMAKE_SYSROOT}/$cudnn_inc"
  fi
  if [[ $cudnn_lib != usr/lib/aarch64-linux-gnu ]]; then
    cudnn_lib_flag=" -L\${CMAKE_SYSROOT}/$cudnn_lib -Wl,-rpath-link,\${CMAKE_SYSROOT}/$cudnn_lib"
  fi
  install -m 0644 /dev/null "$sdk/toolchain.cmake"
  sed \
    -e "s|@CUDNN_INCLUDE_DIR@|$cudnn_inc|g" \
    -e "s|@CUDNN_LIB_DIR@|$cudnn_lib|g" \
    -e "s|@CUDNN_INCLUDE_FLAG@|$(escape_for_sed "$cudnn_inc_flag")|g" \
    -e "s|@CUDNN_LIB_FLAG@|$(escape_for_sed "$cudnn_lib_flag")|g" \
    "$template" > "$sdk/toolchain.cmake"
}

# generate_nvcc_wrapper <sdk> <cuda_version>
#
# Writes <sdk>/bin/nvcc from templates/nvcc-wrapper.sh.tmpl. The CUDA
# version is used to build concrete host paths so the wrapper does not
# fall through to a hard-coded "12.6".
generate_nvcc_wrapper() {
  local sdk=$1 cuda_version=$2
  local template="$JETSON_CROSS_LIB_DIR/../templates/nvcc-wrapper.sh.tmpl"
  # Prefer sudo (root or containers) so root-owned SDKs can be built, but
  # fall back to plain install when running as a non-root user with a
  # user-owned SDK. This keeps tests runnable without sudo.
  if (( EUID == 0 )) || command -v sudo >/dev/null; then
    sudo install -d -m 0755 "$sdk/bin"
    # Remove any leftover symlink so the wrapper below is written as a
    # real file. Without this, sudo tee follows an existing symlink and
    # the script-generated wrapper never lands in the SDK.
    sudo rm -f "$sdk/bin/nvcc"
    sed "s|@CUDA_VERSION@|$cuda_version|g" "$template" | sudo tee "$sdk/bin/nvcc" >/dev/null
    sudo chmod 0755 "$sdk/bin/nvcc"
    sudo chown -R "$(id -un):$(id -gn)" "$sdk/bin"
  else
    install -d -m 0755 "$sdk/bin"
    rm -f "$sdk/bin/nvcc"
    sed "s|@CUDA_VERSION@|$cuda_version|g" "$template" > "$sdk/bin/nvcc"
    chmod 0755 "$sdk/bin/nvcc"
  fi
}

# Copy <sdk>/example/ for the online path (a minimal CMake project) and
# <sdk>/example-cuda-smoke/ for the offline path (a CUDA smoke example).
copy_example_project() {
  local sdk=$1
  local src
  if [[ -d "$JETSON_CROSS_LIB_DIR/../templates/example-cuda-smoke" ]]; then
    src="$JETSON_CROSS_LIB_DIR/../templates/example-cuda-smoke"
    rm -rf "$sdk/example-cuda-smoke"
    cp -r "$src" "$sdk/example-cuda-smoke"
  fi
}

# run_offline_smoke_tests <sdk> <root> <cross_prefix>
#
# Compiles four small programs against the sysroot, each of which proves
# one of the failure modes that have historically produced a "ready"
# SDK that did not actually work:
#   hello-aarch64         -- the compiler is reachable at all
#   smoke-sysroot-aarch64 -- libc resolves to the sysroot (not the host)
#   smoke-cuda-aarch64    -- CUDA headers compile and link libcudart
#   smoke-cudnn-aarch64   -- cuDNN compiles and links libcudnn
run_offline_smoke_tests() {
  local sdk=$1 root=$2 cross=$3
  local cuda_target_lib="$root/usr/local/cuda/targets/aarch64-linux/lib"
  local cuda_target_inc="$root/usr/local/cuda/targets/aarch64-linux/include"
  local smoke_cxx_flags=(
    --sysroot="$root"
    -isystem "$root/usr/include/aarch64-linux-gnu"
    -B"$root/usr/lib/aarch64-linux-gnu/"
    -L"$root/usr/lib/aarch64-linux-gnu"
  )
  local smoke_ldflags=(
    -Wl,-rpath-link,"$root/lib/aarch64-linux-gnu"
    -Wl,-rpath-link,"$root/usr/lib/aarch64-linux-gnu"
    -Wl,-rpath-link,"$root/usr/lib/aarch64-linux-gnu/tegra"
  )
  printf 'int main(){return 0;}\n' | "${cross}g++" "${smoke_cxx_flags[@]}" "${smoke_ldflags[@]}" \
    -x c++ - -o "$sdk/hello-aarch64"
  file "$sdk/hello-aarch64"
  "${cross}readelf" -h "$sdk/hello-aarch64" | grep -q 'Machine:.*AArch64' || die 'Wrong output architecture'
  printf '#include <math.h>\n#include <zlib.h>\nint main(){return (int)compressBound(1024)+0*sqrt(2.0);}\n' \
    | "${cross}g++" "${smoke_cxx_flags[@]}" "${smoke_ldflags[@]}" -lz -lm \
      -x c++ - -o "$sdk/smoke-sysroot-aarch64"
  "${cross}readelf" -d "$sdk/smoke-sysroot-aarch64" | grep -q 'Shared library: \[libm.so.6\]' \
    || die 'libm did not resolve to the sysroot libm.so.6; an absolute symlink is still escaping the sysroot'
  if [[ -f $cuda_target_lib/libcudart.so ]]; then
    if [[ ! -f $cuda_target_inc/crt/host_config.h ]]; then
      warn "$cuda_target_inc/crt is missing (cuda-crt package not installed)"
      warn 'The sysroot CUDA headers are incomplete; an x86_64 host nvcc'
      warn 'still provides working headers, but the sysroot cannot compile CUDA on its own.'
    fi
    printf '#include <math.h>\n#include <cuda_runtime.h>\nint main(){return (int)sqrt(2.0);}\n' \
      | "${cross}g++" "${smoke_cxx_flags[@]}" "${smoke_ldflags[@]}" \
        -isystem "$cuda_target_inc" -L"$cuda_target_lib" \
        -Wl,-rpath-link,"$cuda_target_lib" -lcudart \
        -x c++ - -o "$sdk/smoke-cuda-aarch64" \
      || die 'Could not compile a CUDA translation unit against the sysroot'
    "${cross}readelf" -d "$sdk/smoke-cuda-aarch64" | grep -q 'libcudart' \
      || die 'CUDA smoke test did not link against the sysroot libcudart'
  else
    warn "skipping CUDA link test: $cuda_target_lib/libcudart.so not present"
  fi
  printf '#include <cudnn.h>\nint main(){return (int)cudnnGetVersion();}\n' \
    | "${cross}g++" "${smoke_cxx_flags[@]}" "${smoke_ldflags[@]}" \
      -isystem "$root/$CUDNN_INCLUDE_DIR" -isystem "$cuda_target_inc" \
      -L"$root/$CUDNN_LIB_DIR" -Wl,-rpath-link,"$root/$CUDNN_LIB_DIR" -lcudnn \
      -x c++ - -o "$sdk/smoke-cudnn-aarch64" \
    || die 'Could not compile a cuDNN translation unit against the sysroot'
  "${cross}readelf" -d "$sdk/smoke-cudnn-aarch64" | grep -q 'libcudnn' \
    || die 'cuDNN smoke test did not link against the sysroot libcudnn'
}

# Internal: escape a string for use as a sed replacement.
escape_for_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

# Internal: install a file with a known mode, replacing any existing one.
install_file() {
  local mode=$1 src=$2 dst=$3
  install -m "$mode" "$src" "$dst"
}