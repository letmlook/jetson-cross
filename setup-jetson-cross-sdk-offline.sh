#!/usr/bin/env bash
set -Eeuo pipefail

# No Jetson device needed. Default download mapping covers L4T 36.4.4.
# Usage: script L4T_FULL [SDK_DIR] [BSP_ARCHIVE ROOTFS_ARCHIVE]
# Example: script 36.4.4
# Other releases: script 35.6.4 "$HOME/sdk-r35" /path/Jetson_Linux.tbz2 /path/Sample_Rootfs.tbz2
release=${1:-}; sdk=${2:-"$HOME/jetson-cross-sdk-r${release}"}
[[ $release =~ ^(35|36)\.[0-9]+\.[0-9]+$ ]] || {
  echo "Usage: $0 36.4.4 [sdk-dir] [bsp.tbz2 sample-rootfs.tbz2]" >&2; exit 2;
}
[[ $sdk = /* ]] || sdk="$PWD/$sdk"
[[ $(uname -m) = x86_64 ]] || { echo 'An x86_64 host is required' >&2; exit 1; }
. /etc/os-release
[[ $ID = ubuntu && ( $VERSION_ID = 20.04 || $VERSION_ID = 22.04 ) ]] || {
  echo 'This script supports x86_64 Ubuntu 20.04/22.04' >&2; exit 1;
}
major=${release%%.*}; minor=$(cut -d. -f2 <<< "$release"); repo="r$major.$minor"
if [[ $major = 36 ]]; then toolver=2022.08-1; else toolver=2020.08-1; fi
toolname="aarch64--glibc--stable-$toolver"
log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
trap 'echo "Failed at line $LINENO. Files kept in $sdk" >&2' ERR
if (( EUID == 0 )); then
  # Minimal Ubuntu containers commonly run as root without installing sudo.
  sudo() { command env "$@"; }
else
  command -v sudo >/dev/null || die 'sudo is required when not running as root'
fi

log 'Installing host tools'
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg cmake ninja-build \
  pkg-config file python3 qemu-user-static binfmt-support binutils-aarch64-linux-gnu bzip2
sudo update-binfmts --enable qemu-aarch64
[[ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
  && grep -qx enabled /proc/sys/fs/binfmt_misc/qemu-aarch64 \
  || die 'AArch64 binfmt registration failed; a privileged host or container is required'
mkdir -p "$sdk/downloads" "$sdk/toolchain"

if (( $# >= 4 )); then
  bsp=$3; sample=$4
  [[ -f $bsp && -f $sample ]] || die 'Both local archives must exist'
elif (( $# == 1 || $# == 2 )) && [[ $release = 36.4.4 ]]; then
  bsp="$sdk/downloads/Jetson_Linux_R36.4.4_aarch64.tbz2"
  sample="$sdk/downloads/Tegra_Linux_Sample-Root-Filesystem_r36.4.4_aarch64.tbz2"
  log 'Downloading official Jetson Linux 36.4.4 BSP and sample rootfs'
  [[ -s $bsp ]] || curl -fL --retry 3 -o "$bsp" \
    'https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Jetson_Linux_r36.4.4_aarch64.tbz2'
  [[ -s $sample ]] || curl -fL --retry 3 -o "$sample" \
    'https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Tegra_Linux_Sample-Root-Filesystem_r36.4.4_aarch64.tbz2'
else
  die "For L4T $release, pass matching official BSP and Sample Root Filesystem archives as arguments 4 and 5"
fi

log 'Preparing NVIDIA sample filesystem'
if [[ ! -f $sdk/.rootfs-initialized ]]; then
  tar -xjf "$bsp" -C "$sdk"
  l4t="$sdk/Linux_for_Tegra"
  [[ -x $l4t/apply_binaries.sh ]] || die 'BSP archive did not contain Linux_for_Tegra/apply_binaries.sh'
  sudo tar -xjpf "$sample" -C "$l4t/rootfs"
  (cd "$l4t" && sudo ./apply_binaries.sh)
  touch "$sdk/.rootfs-initialized"
fi
root="$sdk/Linux_for_Tegra/rootfs"
[[ -d $root/usr ]] || die 'Rootfs incomplete'

log 'Installing AArch64 development packages inside the isolated rootfs'
# apply_binaries.sh adds the same NVIDIA repositories without signed-by. APT
# rejects duplicate URLs with different key configuration, so keep that file
# as a disabled reference and make the scoped-key source below authoritative.
bsp_source="$root/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
if [[ -f $bsp_source ]]; then
  sudo mv -f "$bsp_source" "$bsp_source.disabled"
fi
keytmp=$(mktemp)
curl -fsSL https://repo.download.nvidia.com/jetson/jetson-ota-public.asc -o "$keytmp"
gpg --dearmor < "$keytmp" | sudo tee "$root/usr/share/keyrings/nvidia-jetson.gpg" >/dev/null
rm -f "$keytmp"
sudo tee "$root/etc/apt/sources.list.d/jetson-cross-sdk.list" >/dev/null <<EOF
deb [signed-by=/usr/share/keyrings/nvidia-jetson.gpg] https://repo.download.nvidia.com/jetson/common $repo main
deb [signed-by=/usr/share/keyrings/nvidia-jetson.gpg] https://repo.download.nvidia.com/jetson/t234 $repo main
EOF
sudo install -m 0755 /usr/bin/qemu-aarch64-static "$root/usr/bin/qemu-aarch64-static"
sudo tee "$root/usr/sbin/policy-rc.d" >/dev/null <<'EOF'
#!/bin/sh
exit 101
EOF
sudo chmod +x "$root/usr/sbin/policy-rc.d"
sudo cp /etc/resolv.conf "$root/etc/resolv.conf"
mounted=()
cleanup() {
  for dest in "${mounted[@]}"; do sudo umount -R "$dest" || true; done
  sudo rm -f "$root/usr/sbin/policy-rc.d" "$root/usr/bin/qemu-aarch64-static"
}
trap cleanup EXIT
sudo mount --rbind /dev "$root/dev"
sudo mount --make-rslave "$root/dev"
mounted=("$root/dev" "${mounted[@]}")
for fs in proc sys; do
  sudo mount --bind "/$fs" "$root/$fs"
  mounted=("$root/$fs" "${mounted[@]}")
done
sudo chroot "$root" /usr/bin/qemu-aarch64-static /bin/sh -c 'apt-get update'
cuda_suffix=$(sudo chroot "$root" /usr/bin/qemu-aarch64-static /bin/sh -c \
  "apt-cache depends cuda-toolkit | sed -n 's/.*Depends: cuda-toolkit-\([0-9][0-9]*-[0-9][0-9]*\)$/\1/p' | head -n 1")
[[ $cuda_suffix =~ ^[0-9]+-[0-9]+$ ]] \
  || die 'Could not resolve the default versioned CUDA development package'
sudo chroot "$root" /usr/bin/qemu-aarch64-static /bin/sh -c \
  "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cuda-libraries-dev-$cuda_suffix libnvinfer-dev libopencv-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libavformat-dev libavcodec-dev libavutil-dev libswscale-dev"
cleanup
trap - EXIT
mounted=()

log 'Installing default host CUDA compiler for the selected Jetson release'
cuda_version=${cuda_suffix/-/.}
nvcc=
if [[ -x /usr/local/cuda/bin/nvcc ]]; then
  nvcc=/usr/local/cuda/bin/nvcc
elif [[ -x /usr/local/cuda-$cuda_version/bin/nvcc ]]; then
  # update-alternatives uses an absolute /etc symlink. That symlink is broken
  # when /usr/local is persisted from a container without persisting /etc.
  nvcc=/usr/local/cuda-$cuda_version/bin/nvcc
fi
if [[ -z $nvcc ]]; then
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://repo.download.nvidia.com/jetson/jetson-ota-public.asc \
    | gpg --dearmor | sudo tee /etc/apt/keyrings/nvidia-jetson.gpg >/dev/null
  codename=$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")
  printf 'deb [signed-by=/etc/apt/keyrings/nvidia-jetson.gpg] https://repo.download.nvidia.com/jetson/x86_64/%s %s main\n' "$codename" "$repo" \
    | sudo tee /etc/apt/sources.list.d/jetson-cross-sdk.list >/dev/null
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "cuda-nvcc-$cuda_suffix" "cuda-cross-aarch64-$cuda_suffix"
  if [[ -x /usr/local/cuda/bin/nvcc ]]; then
    nvcc=/usr/local/cuda/bin/nvcc
  elif [[ -x /usr/local/cuda-$cuda_version/bin/nvcc ]]; then
    nvcc=/usr/local/cuda-$cuda_version/bin/nvcc
  fi
fi
[[ -n $nvcc && -x $nvcc ]] || die "Host nvcc missing for CUDA $cuda_version"

log 'Installing reference Bootlin cross compiler'
archive="$sdk/downloads/$toolname.tar.bz2"
if [[ ! -x $sdk/toolchain/$toolname/bin/aarch64-buildroot-linux-gnu-g++ ]]; then
  [[ -s $archive ]] || curl -fL --retry 3 -o "$archive" \
    "https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/$toolname.tar.bz2"
  tar -xjf "$archive" -C "$sdk/toolchain"
fi
cross="$sdk/toolchain/$toolname/bin/aarch64-buildroot-linux-gnu-"
[[ -x ${cross}g++ ]] || die 'Cross compiler missing after extraction'

# Container users can persist the SDK and CUDA directories on the host while
# still running installation at /work and /usr/local inside the container.
# These overrides affect only the generated activation file.
activate_sdk=${JETSON_SDK_ACTIVATE_PATH:-$sdk}
activate_nvcc=${JETSON_NVCC_ACTIVATE_PATH:-$nvcc}
activate_cross="$activate_sdk/toolchain/$toolname/bin/aarch64-buildroot-linux-gnu-"
activate_root="$activate_sdk/Linux_for_Tegra/rootfs"
cat > "$sdk/activate.sh" <<EOF
#!/usr/bin/env bash
export JETSON_SDK='$activate_sdk'
export JETSON_CROSS='$activate_cross'
export CROSS_COMPILE='$activate_cross'
export CUDACXX='$activate_nvcc'
export CUDAHOSTCXX='${activate_cross}g++'
export PKG_CONFIG_SYSROOT_DIR='$activate_root'
export PKG_CONFIG_LIBDIR='$activate_root/usr/lib/aarch64-linux-gnu/pkgconfig:$activate_root/usr/lib/pkgconfig:$activate_root/usr/share/pkgconfig:$activate_root/usr/local/lib/aarch64-linux-gnu/pkgconfig'
unset PKG_CONFIG_PATH
EOF
cat > "$sdk/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_SYSROOT "\$ENV{JETSON_SDK}/Linux_for_Tegra/rootfs")
set(CMAKE_C_COMPILER "\$ENV{JETSON_CROSS}gcc")
set(CMAKE_CXX_COMPILER "\$ENV{JETSON_CROSS}g++")
set(CMAKE_CUDA_COMPILER "\$ENV{CUDACXX}")
set(CMAKE_CUDA_HOST_COMPILER "\$ENV{CUDAHOSTCXX}")
set(CMAKE_FIND_ROOT_PATH "\${CMAKE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_EXE_LINKER_FLAGS_INIT "-B\${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu/ -L\${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu -Wl,-rpath-link,\${CMAKE_SYSROOT}/lib/aarch64-linux-gnu -Wl,-rpath-link,\${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu -Wl,-rpath-link,\${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu/tegra -Wl,-rpath-link,\${CMAKE_SYSROOT}/usr/local/cuda/lib64")
EOF
export PKG_CONFIG_SYSROOT_DIR="$root"
export PKG_CONFIG_LIBDIR="$root/usr/lib/aarch64-linux-gnu/pkgconfig:$root/usr/lib/pkgconfig:$root/usr/share/pkgconfig:$root/usr/local/lib/aarch64-linux-gnu/pkgconfig"
unset PKG_CONFIG_PATH
for pc in opencv4 gstreamer-1.0 libavformat; do pkg-config --modversion "$pc"; done
[[ -f $root/usr/include/NvInfer.h || -f $root/usr/include/aarch64-linux-gnu/NvInfer.h ]] \
  || die 'NvInfer.h missing after ARM64 apt install'
printf 'int main(){return 0;}\n' | "${cross}g++" --sysroot="$root" \
  -B"$root/usr/lib/aarch64-linux-gnu/" -L"$root/usr/lib/aarch64-linux-gnu" \
  -Wl,-rpath-link,"$root/lib/aarch64-linux-gnu" \
  -Wl,-rpath-link,"$root/usr/lib/aarch64-linux-gnu" \
  -x c++ - -o "$sdk/hello-aarch64"
file "$sdk/hello-aarch64"
"${cross}readelf" -h "$sdk/hello-aarch64" | grep -q 'Machine:.*AArch64' || die 'Wrong output architecture'
log "SDK ready: source '$sdk/activate.sh'"
echo "cmake -S PROJECT -B BUILD -DCMAKE_TOOLCHAIN_FILE='$sdk/toolchain.cmake'"
