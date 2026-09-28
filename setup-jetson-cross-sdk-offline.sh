#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/jetson-versions.sh
source "$script_dir/lib/jetson-versions.sh"

# No Jetson device needed. Accepts either a JetPack or L4T version.
# Usage: script [JETPACK_OR_L4T_VERSION] [SDK_DIR] [BSP_ARCHIVE ROOTFS_ARCHIVE]
# Default: JetPack 6.1 (L4T 36.4.0).
version_input=${1:-$DEFAULT_JETPACK_VERSION}
resolve_jetson_version "$version_input" || {
  echo "Usage: $0 [6.1|36.4.0] [sdk-dir] [bsp.tbz2 sample-rootfs.tbz2]" >&2; exit 2;
}
release=$L4T_VERSION
sdk=${2:-"$HOME/jetson-cross-sdk-${JETSON_VERSION_SLUG}"}
[[ $sdk = /* ]] || sdk="$PWD/$sdk"
host_arch=$(uname -m)
[[ $host_arch = x86_64 || $host_arch = aarch64 ]] \
  || { echo 'An x86_64 or aarch64 Linux host is required' >&2; exit 1; }
os_release_file=${JETSON_OS_RELEASE_FILE:-/etc/os-release}
. "$os_release_file"
[[ $ID = ubuntu && ( $VERSION_ID = 20.04 || $VERSION_ID = 22.04 ) ]] || {
  echo 'This script supports x86_64/aarch64 Ubuntu 20.04/22.04' >&2; exit 1;
}
native_arm64=false
[[ $host_arch = aarch64 ]] && native_arm64=true
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

if [[ -n $JETPACK_VERSION ]]; then
  log "Resolved JetPack $JETPACK_VERSION to L4T $release"
else
  log "Using L4T $release (no known JetPack mapping)"
fi

log 'Installing host tools'
sudo apt-get update
host_packages=(ca-certificates curl gnupg cmake ninja-build pkg-config file python3 bzip2)
if $native_arm64; then
  # Native AArch64 host: chroot runs natively, so no qemu-aarch64-static
  # binary is needed. Skip the real qemu-user-static package and install a
  # stub into the rootfs later so NVIDIA's l4t_update_initrd.sh CheckPackage
  # still passes (it checks `dpkg -s qemu-user-static`).
  host_packages+=(build-essential binutils lbzip2)
else
  # x86_64 host: needs real qemu-aarch64-static for chroot + binfmt_misc
  # registration so aarch64 binaries execute transparently.
  host_packages+=(qemu-user-static binfmt-support binutils-aarch64-linux-gnu)
fi
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${host_packages[@]}"
if ! $native_arm64; then
  sudo update-binfmts --enable qemu-aarch64
  [[ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
    && grep -qx enabled /proc/sys/fs/binfmt_misc/qemu-aarch64 \
    || die 'AArch64 binfmt registration failed; a privileged host or container is required'
fi
mkdir -p "$sdk/downloads" "$sdk/toolchain"
rm -f "$sdk/.setup-complete"

if (( $# >= 4 )); then
  bsp=$3; sample=$4
  [[ -f $bsp && -f $sample ]] || die 'Both local archives must exist'
elif (( $# <= 2 )); then
  case "$release" in
    36.4.0)
      bsp="$sdk/downloads/Jetson_Linux_R36.4.0_aarch64.tbz2"
      sample="$sdk/downloads/Tegra_Linux_Sample-Root-Filesystem_r36.4.0_aarch64.tbz2"
      download_base='https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.0/release'
      ;;
    36.4.4)
      bsp="$sdk/downloads/Jetson_Linux_R36.4.4_aarch64.tbz2"
      sample="$sdk/downloads/Tegra_Linux_Sample-Root-Filesystem_r36.4.4_aarch64.tbz2"
      download_base='https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release'
      ;;
    *)
      patch=$(cut -d. -f3 <<< "$release")
      bsp="$sdk/downloads/Jetson_Linux_R${release}_aarch64.tbz2"
      sample="$sdk/downloads/Tegra_Linux_Sample-Root-Filesystem_r${release}_aarch64.tbz2"
      download_base="https://developer.nvidia.com/downloads/embedded/l4t/r${major}_release_v${minor}.${patch}/release"
      ;;
  esac
  log "Downloading official Jetson Linux $release BSP and sample rootfs"
  [[ -s $bsp ]] || curl -fL --retry 3 -o "$bsp" \
    "$download_base/Jetson_Linux_r${release}_aarch64.tbz2"
  [[ -s $sample ]] || curl -fL --retry 3 -o "$sample" \
    "$download_base/Tegra_Linux_Sample-Root-Filesystem_r${release}_aarch64.tbz2"
else
  die "For L4T $release, pass matching official BSP and Sample Root Filesystem archives as arguments 3 and 4"
fi

log 'Preparing NVIDIA sample filesystem'
if [[ ! -f $sdk/.rootfs-initialized ]]; then
  l4t="$sdk/Linux_for_Tegra"
  if [[ -d $l4t ]]; then
    log 'Removing incomplete NVIDIA rootfs setup before retrying'
    sudo rm -rf "$l4t"
  fi
  tar -xjf "$bsp" -C "$sdk"
  [[ -x $l4t/apply_binaries.sh ]] || die 'BSP archive did not contain Linux_for_Tegra/apply_binaries.sh'
  sudo tar -xjpf "$sample" -C "$l4t/rootfs"
  if ! $native_arm64; then
    [[ -x /usr/bin/qemu-aarch64-static ]] || die 'qemu-aarch64-static missing after host tool installation'
    sudo install -m 0755 /usr/bin/qemu-aarch64-static "$sdk/qemu-aarch64-static"
  fi
  if $native_arm64; then
    # Install a stub qemu-user-static into the rootfs so the NVIDIA BSP's
    # l4t_update_initrd.sh CheckPackage passes. Native ARM64 hosts do not
    # need the real qemu-aarch64-static binary because chroot runs natively.
    install_qemu_user_static_stub
  fi
  apply_args=()
  $native_arm64 && apply_args+=(--target-overlay)
  (cd "$l4t" && sudo ./apply_binaries.sh "${apply_args[@]}")
  if ! $native_arm64; then sudo rm -f "$sdk/qemu-aarch64-static"; fi
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
if ! $native_arm64; then
  sudo install -m 0755 /usr/bin/qemu-aarch64-static "$root/usr/bin/qemu-aarch64-static"
fi
sudo tee "$root/usr/sbin/policy-rc.d" >/dev/null <<'EOF'
#!/bin/sh
exit 101
EOF
sudo chmod +x "$root/usr/sbin/policy-rc.d"
sudo cp /etc/resolv.conf "$root/etc/resolv.conf"
mounted=()
cleanup() {
  for dest in ${mounted[@]+"${mounted[@]}"}; do sudo umount -R "$dest" || true; done
  sudo rm -f "$root/usr/sbin/policy-rc.d" "$root/usr/bin/qemu-aarch64-static"
}
trap cleanup EXIT
sudo mount --rbind /dev "$root/dev"
sudo mount --make-rslave "$root/dev"
mounted=("$root/dev" ${mounted[@]+"${mounted[@]}"})
for fs in proc sys; do
  sudo mount --bind "/$fs" "$root/$fs"
  mounted=("$root/$fs" "${mounted[@]}")
done
rootfs_exec() {
  if $native_arm64; then
    sudo chroot "$root" "$@"
  else
    sudo chroot "$root" /usr/bin/qemu-aarch64-static "$@"
  fi
}

# Rewrite absolute symlinks that point back into the rootfs so the sysroot can
# never resolve them against the host root. Links whose target is outside the
# rootfs (/dev/shm, missing update-alternatives entries, systemd wants units)
# cannot be made relative without inventing a path, so they are reported
# instead of rewritten.
normalize_rootfs_symlinks() {
  local root_dir=$1 report=$2 out rewritten escaping=0
  # The rootfs is root-owned so the rewrite needs sudo, but the report must stay
  # owned by the invoking user. Let the privileged half only print, and write
  # the report from this shell.
  out=$(sudo python3 - "$root_dir" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
# Pseudo-filesystems are skipped: the script unmounts them beforehand, but a
# still-mounted /proc would otherwise make the walk try to rewrite kernel links.
skip = {'proc', 'sys', 'dev'}
rewritten, escaping = 0, []
for base, dirs, files in os.walk(root, followlinks=False):
    dirs[:] = [d for d in dirs if d not in skip]
    for name in dirs + files:
        link = pathlib.Path(base) / name
        try:
            if not link.is_symlink():
                continue
            target = os.readlink(link)
            if not target.startswith('/'):
                continue
            dest = pathlib.Path(os.path.normpath(str(root / target.lstrip('/'))))
            # Skip anything that would still resolve outside the sysroot, or
            # whose target does not exist, so no rewrite can introduce a new
            # dangling link.
            if root not in dest.parents or not dest.exists():
                escaping.append(f"{link.relative_to(root)} -> {target}")
                continue
            relative = os.path.relpath(dest, link.parent)
            link.unlink()
            link.symlink_to(relative)
            rewritten += 1
        except OSError:
            # A single unrewritable link must not abort the whole sysroot.
            continue
print(rewritten)
for entry in escaping:
    print(entry)
PY
)
  rewritten=${out%%$'\n'*}
  [[ $out == *$'\n'* ]] && escaping=$(($(printf '%s\n' "$out" | wc -l) - 1))
  {
    echo '# Absolute symlinks kept as-is because their target is not inside the'
    echo '# sysroot. They still resolve against the host root at build time and'
    echo '# do not take part in cross-compilation of the Jetson target.'
    printf '%s\n' "${out#*$'\n'}"
  } > "$report"
  printf '    %s absolute symlinks rewritten, %s left escaping (listed in %s)\n' \
    "$rewritten" "$escaping" "${report##*/}"
}

# Build a minimal Debian package that satisfies NVIDIA l4t_update_initrd.sh's
# `dpkg -s qemu-user-static` check without pulling in the actual qemu binary
# (which is unused on a native AArch64 host where chroot executes natively).
# Run this before apply_binaries.sh so the initrd step sees the package.
install_qemu_user_static_stub() {
  local stub_dir
  stub_dir=$(mktemp -d)
  mkdir -p "$stub_dir/DEBIAN"
  cat > "$stub_dir/DEBIAN/control" <<EOF
Package: qemu-user-static
Version: 1:6.2+dfsg-2ubuntu6.31
Architecture: all
Maintainer: jetson-cross-sdk
Description: stub package for native AArch64 hosts
 Provides dpkg -s success for NVIDIA BSP l4t_update_initrd.sh CheckPackage.
 On a native AArch64 host, chroot executes natively so the qemu-aarch64-static
 binary is unnecessary; this stub satisfies the check without adding ~50MB.
EOF
  dpkg-deb -b "$stub_dir" "$stub_dir/qemu-user-static-stub.deb" >/dev/null
  sudo install -d -m 0755 "$root/tmp"
  sudo cp "$stub_dir/qemu-user-static-stub.deb" "$root/tmp/"
  rm -rf "$stub_dir"
  rootfs_exec /bin/sh -c "dpkg -i /tmp/qemu-user-static-stub.deb && rm /tmp/qemu-user-static-stub.deb"
}
rootfs_exec /bin/sh -c 'apt-get update'
cuda_suffix=$(rootfs_exec /bin/sh -c \
  "apt-cache depends cuda-toolkit | sed -n 's/.*Depends: cuda-toolkit-\([0-9][0-9]*-[0-9][0-9]*\)$/\1/p' | head -n 1")
[[ $cuda_suffix =~ ^[0-9]+-[0-9]+$ ]] \
  || die 'Could not resolve the default versioned CUDA development package'
# Install the JetPack development stack from NVIDIA's own nvidia-* bundle.
# NVIDIA keeps one build of nvidia-jetpack-dev, and of every nvidia-* package
# it depends on, per JetPack release ("<jp>+b<build>"). The repository serves
# all of them at once, so an unpinned install silently pulls the newest bundle,
# for example 6.2.1's, even when the requested release is 6.1. Select the build
# matching the resolved JetPack version instead.
#
# The component names also change between releases (nvidia-cudnn9-dev on 6.1
# versus nvidia-cudnn-dev on 6.2), so the pinned set is derived from the
# bundle's own Depends rather than hardcoded.
jetpack_dev_build=
if [[ -n $JETPACK_VERSION ]]; then
  # apt-cache madison right-aligns the version column, so match on whitespace.
  jetpack_dev_build=$(rootfs_exec /bin/sh -c \
    "apt-cache madison nvidia-jetpack-dev 2>/dev/null" \
    | sed -n "s/^[^|]*|[[:space:]]*\($JETPACK_VERSION+b[^[:space:]|]*\)[[:space:]]*|.*/\1/p" \
    | head -n 1)
fi
if [[ -n $jetpack_dev_build ]]; then
  log "Installing NVIDIA JetPack development bundle $jetpack_dev_build for JetPack $JETPACK_VERSION"
  # Pin the whole exact-version dependency closure, not just the direct
  # dependencies of the bundle. nvidia-jetpack-runtime alone pulls
  # nvidia-container, nvidia-cupva, nvidia-opencv, nvidia-tensorrt,
  # nvidia-vpi and nvidia-cuda, and those in turn pin libnvidia-container*,
  # pva-allow-2 and cupva-2.5-l4t. Left to itself apt picks the newest version
  # of those and reports held broken packages. Each package is pinned at the
  # version its parent declares, which is also why the closure must not assume
  # a single build string: nvidia-* L4T packages are versioned by L4T instead.
  jetpack_dev_pinned=
  jetpack_dev_seen=' '
  jetpack_dev_count=0
  # Kept in a variable: an unquoted ")" inside [[ =~ ]] would end the pattern.
  jetpack_dep_re='^[[:space:]]*([[:alnum:]][[:alnum:].+-]*) \(= ([^)]+)\)[[:space:]]*$'
  jetpack_dev_queue=("nvidia-jetpack-dev=$jetpack_dev_build")
  while [[ ${#jetpack_dev_queue[@]} -gt 0 ]]; do
    spec=${jetpack_dev_queue[0]}
    jetpack_dev_queue=("${jetpack_dev_queue[@]:1}")
    name=${spec%%=*}
    [[ $jetpack_dev_seen == *" $name "* ]] && continue
    jetpack_dev_seen+="$name "
    jetpack_dev_pinned+="${jetpack_dev_pinned:+ }$spec"
    (( ++jetpack_dev_count > 400 )) && break
    while IFS= read -r dep; do
      # Only exact "name (= version)" constraints carry a usable pin.
      [[ $dep =~ $jetpack_dep_re ]] || continue
      jetpack_dev_queue+=("${BASH_REMATCH[1]}=${BASH_REMATCH[2]}")
    done < <(rootfs_exec /bin/sh -c "apt-cache show $spec 2>/dev/null" \
      | sed -n 's/^Depends: //p' | tr ',' '\n')
  done
  log "Pinning $jetpack_dev_count packages at their declared versions"
  # --allow-downgrades matters when an SDK directory is re-initialised for an
  # older JetPack than the bundle already present in it.
  rootfs_exec /bin/sh -c \
    "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --allow-downgrades $jetpack_dev_pinned"
  # nvidia-jetpack-dev pulls nvidia-opencv-dev, which pins the Jetson repo's
  # libopencv-dev 4.8.0. That build is broken on JetPack 6.1: its
  # libopencv-*.so.408 links point at runtime libraries the repo never
  # published. Drop the NVIDIA OpenCV bundle before installing the working
  # Ubuntu 4.5 ABI below, otherwise the two versions cannot coexist.
  rootfs_exec /bin/sh -c \
    "DEBIAN_FRONTEND=noninteractive apt-get remove -y --no-install-recommends nvidia-opencv-dev nvidia-opencv libopencv-dev libopencv-python libopencv-samples opencv-licenses opencv-samples-data" \
    || log 'WARNING: could not remove the NVIDIA OpenCV bundle; the OpenCV step below may fail'
else
  log "WARNING: no nvidia-jetpack-dev build matches JetPack ${JETPACK_VERSION:-unknown}"
  log '         Falling back to the unpinned bundle, then the explicit list'
  rootfs_exec /bin/sh -c \
    "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nvidia-jetpack-dev" \
    || {
      log '         The unpinned bundle is unavailable; using the component list'
      # Derive the versioned names from the repository default instead of
      # pinning 12-6, so the fallback is also correct on other releases.
      cuda_major=${cuda_suffix%%-*}
      rootfs_packages="cuda-toolkit-$cuda_suffix cuda-libraries-dev-$cuda_suffix libnvinfer-dev libnvinfer-bin libcudnn9-cuda-$cuda_major libcudnn9-dev-cuda-$cuda_major libcudnn9-samples nvidia-vpi-dev"
      if $native_arm64; then rootfs_packages="cuda-nvcc-$cuda_suffix $rootfs_packages"; fi
      rootfs_exec /bin/sh -c \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $rootfs_packages"
    }
fi
# GStreamer and FFmpeg development headers are not part of the nvidia-* bundle.
rootfs_exec /bin/sh -c \
  "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libavformat-dev libavcodec-dev libavutil-dev libswscale-dev"
if $native_arm64; then
  rootfs_exec /bin/sh -c \
    "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cuda-nvcc-$cuda_suffix" \
    || log "WARNING: cuda-nvcc-$cuda_suffix could not be installed in the rootfs"
fi
# The compiler-internal CUDA headers live in a separate package: cuda_runtime.h
# includes "crt/host_config.h", and cuda-cudart-dev only ships the thin
# wrappers in include/. Without cuda-crt no CUDA translation unit compiles.
# Keep this non-fatal so a repo without the package still yields a usable
# non-CUDA sysroot, but never leave the gap unreported.
rootfs_exec /bin/sh -c \
  "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cuda-crt-$cuda_suffix" \
  || log "WARNING: cuda-crt-$cuda_suffix could not be installed; the sysroot CUDA headers will be incomplete"
rootfs_exec /bin/sh -c \
  "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --allow-downgrades libopencv-core4.5d libopencv-imgproc4.5d libopencv-dnn4.5d libopencv-dev=4.5.4+dfsg-9ubuntu4"
cleanup
trap - EXIT
mounted=()

# Absolute symlinks inside the rootfs are resolved by the kernel against the
# real filesystem root, never against the sysroot root. Leaving them as-is makes
# aarch64--glibc--stable pick the *host* /lib and /usr/local when the host is
# also aarch64 (the native ARM64 flow and the macOS arm64 container), and
# silently falls back to the static archives on x86_64 hosts. Rewrite every
# absolute link whose target exists inside the rootfs into a relative one.
log 'Making absolute rootfs symlinks self-contained inside the sysroot'
normalize_rootfs_symlinks "$root" "$sdk/escaping-symlinks.txt"

log 'Installing default host CUDA compiler for the selected Jetson release'
cuda_version=${cuda_suffix/-/.}
nvcc=
if $native_arm64 && [[ -x $root/usr/local/cuda-$cuda_version/bin/nvcc ]]; then
  nvcc="$root/usr/local/cuda-$cuda_version/bin/nvcc"
elif $native_arm64 && [[ -x $root/usr/local/cuda/bin/nvcc ]]; then
  nvcc="$root/usr/local/cuda/bin/nvcc"
elif [[ -x /usr/local/cuda/bin/nvcc ]]; then
  nvcc=/usr/local/cuda/bin/nvcc
elif [[ -x /usr/local/cuda-$cuda_version/bin/nvcc ]]; then
  # update-alternatives uses an absolute /etc symlink. That symlink is broken
  # when /usr/local is persisted from a container without persisting /etc.
  nvcc=/usr/local/cuda-$cuda_version/bin/nvcc
fi
if [[ -z $nvcc ]] && ! $native_arm64; then
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

if $native_arm64; then
  log 'Using native AArch64 compiler'
  command -v g++ >/dev/null && command -v readelf >/dev/null \
    || die 'Native g++ and readelf are required'
  cross=
else
  log 'Installing reference Bootlin cross compiler'
  archive="$sdk/downloads/$toolname.tar.bz2"
  if [[ ! -x $sdk/toolchain/$toolname/bin/aarch64-buildroot-linux-gnu-g++ ]]; then
    [[ -s $archive ]] || curl -fL --retry 3 -o "$archive" \
      "https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/$toolname.tar.bz2"
    tar -xjf "$archive" -C "$sdk/toolchain"
  fi
  cross="$sdk/toolchain/$toolname/bin/aarch64-buildroot-linux-gnu-"
  [[ -x ${cross}g++ ]] || die 'Cross compiler missing after extraction'
fi

# The activation file must survive being copied, mounted or moved, so it stores
# only paths relative to its own location. A sysroot nvcc is recorded relative;
# an x86_64 host nvcc lives outside the SDK and stays absolute.
if $native_arm64; then activate_cross_rel=; else activate_cross_rel="toolchain/$toolname/bin/aarch64-buildroot-linux-gnu-"; fi
case $nvcc in
  "$root"/*) activate_nvcc_rel=${nvcc#"$root"/} ;;
  *) activate_nvcc_rel=$nvcc ;;
esac
cat > "$sdk/activate.sh" <<'EOF'
#!/usr/bin/env bash
# Generated by setup-jetson-cross-sdk-offline.sh.
# Every path is derived from this file's own location, so the SDK directory can
# be moved, copied or mounted anywhere without regenerating it.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  __jetson_sdk_self=${BASH_SOURCE[0]}
else
  __jetson_sdk_self=$0
fi
JETSON_SDK=$(cd "$(dirname "$__jetson_sdk_self")" && pwd -P)
unset __jetson_sdk_self
JETSON_ROOTFS="$JETSON_SDK/Linux_for_Tegra/rootfs"
__jetson_cross_rel='@CROSS_REL@'
if [ -n "$__jetson_cross_rel" ]; then
  JETSON_CROSS="$JETSON_SDK/$__jetson_cross_rel"
else
  # Native ARM64 host: the system compiler already targets aarch64.
  JETSON_CROSS=
fi
unset __jetson_cross_rel
__jetson_nvcc_rel='@NVCC_REL@'
case "$__jetson_nvcc_rel" in
  /*) CUDACXX=$__jetson_nvcc_rel ;;
  *)  CUDACXX="$JETSON_SDK/$__jetson_nvcc_rel" ;;
esac
# The host nvcc lives outside the SDK, so allow overriding it at source time.
[ -n "${JETSON_NVCC:-}" ] && CUDACXX=$JETSON_NVCC
unset __jetson_nvcc_rel
export JETSON_SDK JETSON_ROOTFS JETSON_CROSS
export CROSS_COMPILE="$JETSON_CROSS"
export CUDACXX
export CUDAHOSTCXX="${JETSON_CROSS}g++"
export PKG_CONFIG_SYSROOT_DIR="$JETSON_ROOTFS"
export PKG_CONFIG_LIBDIR="$JETSON_ROOTFS/usr/lib/aarch64-linux-gnu/pkgconfig:$JETSON_ROOTFS/usr/lib/pkgconfig:$JETSON_ROOTFS/usr/share/pkgconfig:$JETSON_ROOTFS/usr/local/lib/aarch64-linux-gnu/pkgconfig"
unset PKG_CONFIG_PATH
EOF
sed -i "s|@CROSS_REL@|$activate_cross_rel|; s|@NVCC_REL@|$activate_nvcc_rel|" "$sdk/activate.sh"
chmod 0755 "$sdk/activate.sh"
# cuDNN must be present, not merely requested. An earlier package list omitted
# it and nothing noticed, which left an SDK that could not build any cuDNN code
# while still reporting success. The Jetson repo installs the headers under a
# non-obvious directory, so locate them instead of assuming.
cudnn_include_dir=
for candidate in usr/include usr/include/aarch64-linux-gnu usr/include/x86_64-linux-gnu; do
  if [[ -f $root/$candidate/cudnn.h ]]; then
    cudnn_include_dir=$candidate
    break
  fi
done
[[ -n $cudnn_include_dir ]] \
  || die 'cudnn.h missing after ARM64 apt install; the cuDNN dev package did not provide it'
cudnn_lib_dir=
for candidate in usr/lib/aarch64-linux-gnu usr/lib usr/lib/x86_64-linux-gnu; do
  if [[ -f $root/$candidate/libcudnn.so ]]; then
    cudnn_lib_dir=$candidate
    break
  fi
done
[[ -n $cudnn_lib_dir ]] \
  || die 'libcudnn.so missing after ARM64 apt install; the cuDNN runtime package did not provide it'
log "cuDNN headers in /$cudnn_include_dir, libraries in /$cudnn_lib_dir"
# CMAKE_SYSROOT already adds <sysroot>/usr/include, so only a non-default
# directory needs to be passed explicitly.
cudnn_include_flag=
cudnn_include_args=()
if [[ $cudnn_include_dir != usr/include ]]; then
  cudnn_include_flag=" -isystem\ \${CMAKE_SYSROOT}/$cudnn_include_dir"
  cudnn_include_args=(-isystem "$root/$cudnn_include_dir")
fi
cudnn_lib_flag=
[[ $cudnn_lib_dir = usr/lib/aarch64-linux-gnu ]] || cudnn_lib_flag=" -L\${CMAKE_SYSROOT}/$cudnn_lib_dir -Wl,-rpath-link,\${CMAKE_SYSROOT}/$cudnn_lib_dir"

cat > "$sdk/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
# Without this, find_library and find_path never look in the Debian multiarch
# directories (usr/lib/aarch64-linux-gnu, usr/include/aarch64-linux-gnu), so
# find_library(cudnn) and friends silently fail.
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)
set(CMAKE_SYSROOT "\$ENV{JETSON_ROOTFS}")
set(CMAKE_C_COMPILER "\$ENV{JETSON_CROSS}gcc")
set(CMAKE_CXX_COMPILER "\$ENV{JETSON_CROSS}g++")
set(CMAKE_AR "\$ENV{JETSON_CROSS}ar")
set(CMAKE_RANLIB "\$ENV{JETSON_CROSS}ranlib")
set(CMAKE_CUDA_COMPILER "\$ENV{CUDACXX}")
set(CMAKE_CUDA_HOST_COMPILER "\$ENV{CUDAHOSTCXX}")
set(CMAKE_CUDA_ARCHIVE_FINISH "<CMAKE_RANLIB> <TARGET>")
# Debian multiarch keeps libc headers in <sysroot>/usr/include/aarch64-linux-gnu.
# CMAKE_SYSROOT alone only adds <sysroot>/usr/include, so a plain #include
# <math.h> would fail on bits/wordsize.h without this.
set(CMAKE_C_FLAGS_INIT "-isystem\ \${CMAKE_SYSROOT}/usr/include/aarch64-linux-gnu$cudnn_include_flag")
set(CMAKE_CXX_FLAGS_INIT "-isystem\ \${CMAKE_SYSROOT}/usr/include/aarch64-linux-gnu$cudnn_include_flag")
set(CMAKE_CUDA_FLAGS_INIT "-isystem\ \${CMAKE_SYSROOT}/usr/include/aarch64-linux-gnu$cudnn_include_flag")
set(CMAKE_FIND_ROOT_PATH "\${CMAKE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
# JetPack installs the CUDA runtime under
# <sysroot>/usr/local/cuda/targets/aarch64-linux/{include,lib}. /usr/local/cuda
# is itself an absolute symlink into /etc/alternatives, so the versioned
# directory is referenced directly.
set(CMAKE_CUDA_TARGET_INCLUDE_DIR "\${CMAKE_SYSROOT}/usr/local/cuda/targets/aarch64-linux/include")
set(CMAKE_CUDA_TARGET_LIB_DIR "\${CMAKE_SYSROOT}/usr/local/cuda/targets/aarch64-linux/lib")
# find_library never reads the linker flags, so the CUDA target directory must
# also be registered as a search path for find_library(cudart) to succeed.
list(APPEND CMAKE_LIBRARY_PATH "\${CMAKE_CUDA_TARGET_LIB_DIR}")
set(CMAKE_CUDNN_INCLUDE_DIR "\${CMAKE_SYSROOT}/$cudnn_include_dir")
set(CMAKE_CUDNN_LIB_DIR "\${CMAKE_SYSROOT}/$cudnn_lib_dir")
# Every CUDA public header, cuda_runtime_api.h included, includes
# "crt/host_defines.h", which ships in the separate cuda-crt package. When the
# sysroot CUDA tree is incomplete, fall back to the headers that sit next to
# CUDACXX: on an x86_64 host those come from cuda-crt-cross-aarch64 and are
# complete. Adding the incomplete sysroot tree instead would shadow them and
# break both CUDA and cuDNN, since cudnn.h includes cuda_runtime_api.h.
if(EXISTS "\${CMAKE_CUDA_TARGET_INCLUDE_DIR}/crt/host_config.h")
  set(CMAKE_CUDA_INCLUDE_DIR "\${CMAKE_CUDA_TARGET_INCLUDE_DIR}")
else()
  # CUDACXX points at <cuda-home>/bin/nvcc, so the headers are one level up.
  get_filename_component(CMAKE_CUDA_INCLUDE_DIR "\$ENV{CUDACXX}/../../include" ABSOLUTE)
endif()
set(CMAKE_C_FLAGS_INIT "\${CMAKE_C_FLAGS_INIT} -isystem \${CMAKE_CUDA_INCLUDE_DIR}")
set(CMAKE_CXX_FLAGS_INIT "\${CMAKE_CXX_FLAGS_INIT} -isystem \${CMAKE_CUDA_INCLUDE_DIR}")
set(CMAKE_CUDA_FLAGS_INIT "\${CMAKE_CUDA_FLAGS_INIT} -isystem \${CMAKE_CUDA_INCLUDE_DIR}")
list(APPEND CMAKE_INCLUDE_PATH "\${CMAKE_CUDA_INCLUDE_DIR}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-B\${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu/ -L\${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu -L\${CMAKE_CUDA_TARGET_LIB_DIR}$cudnn_lib_flag -Wl,-rpath-link,\${CMAKE_SYSROOT}/lib/aarch64-linux-gnu -Wl,-rpath-link,\${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu -Wl,-rpath-link,\${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu/tegra -Wl,-rpath-link,\${CMAKE_CUDA_TARGET_LIB_DIR}")
EOF
export PKG_CONFIG_SYSROOT_DIR="$root"
export PKG_CONFIG_LIBDIR="$root/usr/lib/aarch64-linux-gnu/pkgconfig:$root/usr/lib/pkgconfig:$root/usr/share/pkgconfig:$root/usr/local/lib/aarch64-linux-gnu/pkgconfig"
unset PKG_CONFIG_PATH
for pc in opencv4 gstreamer-1.0 libavformat; do pkg-config --modversion "$pc"; done
[[ -f $root/usr/include/NvInfer.h || -f $root/usr/include/aarch64-linux-gnu/NvInfer.h ]] \
  || die 'NvInfer.h missing after ARM64 apt install'


# The smoke test must include headers and link real libraries. A bare
# `int main(){return 0;}` passes even when the sysroot multiarch include path
# and the escaping absolute symlinks are broken, which is exactly how those
# regressions previously reached a "ready" SDK.
smoke_cxx_flags=(--sysroot="$root"
  -isystem "$root/usr/include/aarch64-linux-gnu"
  -B"$root/usr/lib/aarch64-linux-gnu/"
  -L"$root/usr/lib/aarch64-linux-gnu")
smoke_ldflags=(-Wl,-rpath-link,"$root/lib/aarch64-linux-gnu"
  -Wl,-rpath-link,"$root/usr/lib/aarch64-linux-gnu"
  -Wl,-rpath-link,"$root/usr/lib/aarch64-linux-gnu/tegra")
cuda_target_lib="$root/usr/local/cuda/targets/aarch64-linux/lib"
cuda_target_inc="$root/usr/local/cuda/targets/aarch64-linux/include"
printf 'int main(){return 0;}\n' | "${cross}g++" "${smoke_cxx_flags[@]}" "${smoke_ldflags[@]}" \
  -x c++ - -o "$sdk/hello-aarch64"
file "$sdk/hello-aarch64"
"${cross}readelf" -h "$sdk/hello-aarch64" | grep -q 'Machine:.*AArch64' || die 'Wrong output architecture'

# libc headers live in the multiarch include dir, and libm.so plus zlib are
# reached through the sysroot symlinks. Linking both proves the sysroot
# resolves entirely inside itself instead of falling back to the host.
printf '#include <math.h>\n#include <zlib.h>\nint main(){return (int)compressBound(1024)+0*sqrt(2.0);}\n' \
  | "${cross}g++" "${smoke_cxx_flags[@]}" "${smoke_ldflags[@]}" -lz -lm \
    -x c++ - -o "$sdk/smoke-sysroot-aarch64"
file "$sdk/smoke-sysroot-aarch64"
"${cross}readelf" -d "$sdk/smoke-sysroot-aarch64" | grep -q 'Shared library: \[libm.so.6\]' \
  || die 'libm did not resolve to the sysroot libm.so.6; an absolute symlink is still escaping the sysroot'

# The CUDA runtime library must be linkable from the sysroot. On an x86_64 host
# the headers come from the host nvcc, so only the library path is exercised
# here; on a native ARM64 host the sysroot headers are used as well.
if [[ -f $cuda_target_lib/libcudart.so ]]; then
  if [[ ! -f $cuda_target_inc/crt/host_config.h ]]; then
    log "WARNING: $cuda_target_inc/crt is missing (package cuda-crt-$cuda_suffix)"
    log '         The sysroot CUDA headers are incomplete. An x86_64 host nvcc'
    log '         still provides working headers, but the sysroot cannot compile'
    log '         CUDA on its own. Install cuda-crt and rerun to fix this.'
  fi
  printf '#include <math.h>\n#include <cuda_runtime.h>\nint main(){return (int)sqrt(2.0);}\n' \
    | "${cross}g++" "${smoke_cxx_flags[@]}" "${smoke_ldflags[@]}" \
      -isystem "$cuda_target_inc" -L"$cuda_target_lib" \
      -Wl,-rpath-link,"$cuda_target_lib" -lcudart \
      -x c++ - -o "$sdk/smoke-cuda-aarch64" \
    || die 'Could not compile a CUDA translation unit against the sysroot; see the warnings above'
  file "$sdk/smoke-cuda-aarch64"
  "${cross}readelf" -d "$sdk/smoke-cuda-aarch64" | grep -q 'libcudart' \
    || die 'CUDA smoke test did not link against the sysroot libcudart'
else
  printf '    skipping CUDA link test: %s\n' "$cuda_target_lib/libcudart.so not present"
fi

# cuDNN must compile and link from the sysroot, not merely exist on disk.
printf '#include <cudnn.h>\nint main(){return (int)cudnnGetVersion();}\n' \
  | "${cross}g++" "${smoke_cxx_flags[@]}" "${smoke_ldflags[@]}" \
    ${cudnn_include_args[@]+"${cudnn_include_args[@]}"} \
    -L"$root/$cudnn_lib_dir" -Wl,-rpath-link,"$root/$cudnn_lib_dir" -lcudnn \
    -x c++ - -o "$sdk/smoke-cudnn-aarch64" \
  || die 'Could not compile a cuDNN translation unit against the sysroot'
file "$sdk/smoke-cudnn-aarch64"
"${cross}readelf" -d "$sdk/smoke-cudnn-aarch64" | grep -q 'libcudnn' \
  || die 'cuDNN smoke test did not link against the sysroot libcudnn'

# A completed SDK carries roughly 7 GB of material that cannot affect a
# cross-compile: the downloaded BSP and Sample RootFS archives, the apt cache
# and package index, documentation, manual pages and translated catalogues.
# Drop them once the SDK is verified, so a copied or archived SDK stays
# reasonably sized. Nothing removed here is reachable from a compiler include
# or link path.
slim_sdk() {
  local sdk_dir=$1 root_dir=$2 path
  # find -delete rather than rm -rf: it never recurses above the given path.
  if [[ -d $sdk_dir/downloads ]]; then
    sudo find "$sdk_dir/downloads" -mindepth 1 -delete 2>/dev/null || true
  fi
  for path in \
    "$root_dir/var/cache/apt" \
    "$root_dir/var/lib/apt/lists" \
    "$root_dir/var/cache/debconf" \
    "$root_dir/var/log" \
    "$root_dir/usr/share/doc" \
    "$root_dir/usr/share/man" \
    "$root_dir/usr/share/info" \
    "$root_dir/usr/share/locale" \
    "$root_dir/usr/share/i18n" \
    "$root_dir/opt/ota_package"
  do
    [[ -d $path ]] && sudo find "$path" -mindepth 1 -delete 2>/dev/null || true
  done
  # Compiled Python bytecode is rebuilt on the target and is never linked.
  sudo find "$root_dir" -type f -name '*.pyc' -delete 2>/dev/null || true
  sudo find "$root_dir" -type d -name __pycache__ -prune \
    -exec find {} -mindepth 1 -delete \; 2>/dev/null || true
}
log 'Removing install-only caches and documentation'
slim_sdk "$sdk" "$root"
touch "$sdk/.setup-complete"
log "SDK ready: source '$sdk/activate.sh'"
echo "cmake -S PROJECT -B BUILD -DCMAKE_TOOLCHAIN_FILE='$sdk/toolchain.cmake'"
echo "Full usage guide: see docs/使用说明.md in the jetson-cross repository."
