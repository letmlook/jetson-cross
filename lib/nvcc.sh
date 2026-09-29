# shellcheck shell=bash
# Host CUDA install + locate. The X86_64 host needs nvcc outside of the
# SDK to run the compiler-detection step (CMake's CMakeDetermineCompilerId
# runs nvcc without toolchain flags). On native AArch64 the SDK's own
# sysroot nvcc is good enough.

# resolve_cuda_suffix_in_rootfs <rootfs>
#
# Inside the rootfs, cuda-toolkit-12-6 is the version-suffixed package the
# BSP ships. Pick the suffix from apt-cache.
resolve_cuda_suffix_in_rootfs() {
  local root=$1
  local exec
  if is_native_arm64; then
    exec=(sudo chroot "$root")
  else
    exec=(sudo chroot "$root" /usr/bin/qemu-aarch64-static)
  fi
  local suffix
  suffix=$("${exec[@]}" /bin/sh -c \
    "apt-cache depends cuda-toolkit | sed -n 's/.*Depends: cuda-toolkit-\\([0-9][0-9]*-[0-9][0-9]*\\)\$/\\1/p' | head -n 1")
  [[ $suffix =~ ^[0-9]+-[0-9]+$ ]] || die 'Could not resolve the default CUDA development package inside the rootfs'
  printf '%s' "$suffix"
}

# convert_cuda_suffix_to_version <suffix>
#
# Turns 12-6 into 12.6 (used to build host paths).
cuda_suffix_to_version() { printf '%s' "${1/-/.}"; }

# add_jetson_apt_source_x86_64 <codename> <repo>
#
# Adds the NVIDIA Jetson x86_64 apt repo to the host. Used by the online
# script and by the offline x86_64 fallback when the host has no nvcc.
add_jetson_apt_source_x86_64() {
  local codename=$1 repo=$2
  sudo install -d -m 0755 /etc/apt/keyrings
  local key_tmp
  key_tmp=$(mktemp); : "${key_tmp}"
  run curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 \
    https://repo.download.nvidia.com/jetson/jetson-ota-public.asc -o "$key_tmp"
  run gpg --dearmor < "$key_tmp" | sudo tee /etc/apt/keyrings/nvidia-jetson.gpg >/dev/null
  rm -f "$key_tmp"
  sudo chmod 0644 /etc/apt/keyrings/nvidia-jetson.gpg
  printf 'deb [signed-by=/etc/apt/keyrings/nvidia-jetson.gpg] https://repo.download.nvidia.com/jetson/x86_64/%s %s main\n' \
    "$codename" "$repo" | sudo tee /etc/apt/sources.list.d/jetson-cross-sdk.list >/dev/null
  sudo apt-get update
}

# add_jetson_apt_source_rootfs <rootfs> <repo>
#
# Adds the NVIDIA Jetson apt repos inside the rootfs. NVIDIA's BSP ships
# a duplicate, unsigned source that conflicts with this one; we move it
# aside first.
add_jetson_apt_source_rootfs() {
  local root=$1 repo=$2
  local bsp_source="$root/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
  if [[ -f $bsp_source ]]; then
    sudo mv -f "$bsp_source" "$bsp_source.disabled"
  fi
  local keytmp
  keytmp=$(mktemp); : "${keytmp}"
  run curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 \
    https://repo.download.nvidia.com/jetson/jetson-ota-public.asc -o "$keytmp"
  run gpg --dearmor < "$keytmp" | sudo tee "$root/usr/share/keyrings/nvidia-jetson.gpg" >/dev/null
  rm -f "$keytmp"
  sudo tee "$root/etc/apt/sources.list.d/jetson-cross-sdk.list" >/dev/null <<EOF
deb [signed-by=/usr/share/keyrings/nvidia-jetson.gpg] https://repo.download.nvidia.com/jetson/common $repo main
deb [signed-by=/usr/share/keyrings/nvidia-jetson.gpg] https://repo.download.nvidia.com/jetson/t234 $repo main
EOF
  sudo tee "$root/etc/apt/apt.conf.d/99jetson-cross-retries" >/dev/null <<'EOF'
Acquire::Retries "3";
EOF
}

# install_host_nvcc <cuda_suffix> <codename> <repo>
#
# Installs host nvcc + cuda-cross-aarch64 on x86_64 when neither the
# /usr/local/cuda symlink nor the versioned /usr/local/cuda-* directory
# exist. Dies if installation fails.
install_host_nvcc() {
  local cuda_suffix=$1 codename=$2 repo=$3
  local codename_var repo_var
  # shellcheck disable=SC2034
  codename_var=$codename repo_var=$repo
  add_jetson_apt_source_x86_64 "$codename" "$repo"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "cuda-nvcc-$cuda_suffix" "cuda-cross-aarch64-$cuda_suffix"
}

# locate_host_nvcc <cuda_version>
#
# Returns the absolute path to a working nvcc on the host, or empty if
# none. Order of preference: /usr/local/cuda/bin/nvcc,
# /usr/local/cuda-<v>/bin/nvcc.
locate_host_nvcc() {
  local cuda_version=$1
  local candidates=(
    /usr/local/cuda/bin/nvcc
    "/usr/local/cuda-${cuda_version}/bin/nvcc"
    /usr/bin/nvcc
  )
  for c in "${candidates[@]}"; do
    [[ -x $c ]] && { printf '%s' "$c"; return; }
  done
  printf '%s' ""
}