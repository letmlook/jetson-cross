# shellcheck shell=bash
# Offline sysroot acquisition: download the NVIDIA Jetson BSP and Sample
# RootFS, extract them, run apply_binaries.sh to populate the rootfs,
# set up binfmt so chroot can execute aarch64 binaries on x86_64 hosts.

# download_bsp_and_rootfs <sdk_dir> <l4t_release>
#
# Fills in globals:
#   BSP_TARBALL      local path to the BSP archive
#   ROOTFS_TARBALL   local path to the Sample RootFS archive
# Or, if both archives are already on disk locally, copies them into
# <sdk_dir>/downloads and proceeds.
download_bsp_and_rootfs() {
  local sdk=$1 release=$2 local_bsp=${3:-} local_rootfs=${4:-}
  if [[ -n $local_bsp && -n $local_rootfs ]]; then
    [[ -f $local_bsp ]]   || die "BSP archive not found: $local_bsp"
    [[ -f $local_rootfs ]] || die "Sample RootFS archive not found: $local_rootfs"
    BSP_TARBALL="$sdk/downloads/$(basename "$local_bsp")"
    ROOTFS_TARBALL="$sdk/downloads/$(basename "$local_rootfs")"
    [[ -f $BSP_TARBALL    ]] || cp "$local_bsp"   "$BSP_TARBALL"
    [[ -f $ROOTFS_TARBALL ]] || cp "$local_rootfs" "$ROOTFS_TARBALL"
    return
  fi
  local major=${release%%.*} minor patch download_base
  minor=$(printf '%s' "$release" | cut -d. -f2)
  case "$release" in
    36.4.0)
      BSP_TARBALL="$sdk/downloads/Jetson_Linux_R36.4.0_aarch64.tbz2"
      ROOTFS_TARBALL="$sdk/downloads/Tegra_Linux_Sample-Root-Filesystem_r36.4.0_aarch64.tbz2"
      download_base='https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.0/release'
      ;;
    36.4.4)
      BSP_TARBALL="$sdk/downloads/Jetson_Linux_R36.4.4_aarch64.tbz2"
      ROOTFS_TARBALL="$sdk/downloads/Tegra_Linux_Sample-Root-Filesystem_r36.4.4_aarch64.tbz2"
      download_base='https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release'
      ;;
    *)
      patch=$(printf '%s' "$release" | cut -d. -f3)
      BSP_TARBALL="$sdk/downloads/Jetson_Linux_R${release}_aarch64.tbz2"
      ROOTFS_TARBALL="$sdk/downloads/Tegra_Linux_Sample-Root-Filesystem_r${release}_aarch64.tbz2"
      download_base="https://developer.nvidia.com/downloads/embedded/l4t/r${major}_release_v${minor}.${patch}/release"
      ;;
  esac
  [[ -s $BSP_TARBALL    ]] || run curl -fL --retry 3 --retry-all-errors -o "$BSP_TARBALL"    "$download_base/Jetson_Linux_r${release}_aarch64.tbz2"
  [[ -s $ROOTFS_TARBALL ]] || run curl -fL --retry 3 --retry-all-errors -o "$ROOTFS_TARBALL" "$download_base/Tegra_Linux_Sample-Root-Filesystem_r${release}_aarch64.tbz2"
}

# enable_binfmt_aarch64
#
# On x86_64 hosts, the kernel has to know how to run aarch64 binaries
# before chroot can invoke dpkg. Installs qemu-user-static + binfmt-support
# if needed and verifies the registration.
enable_binfmt_aarch64() {
  sudo update-binfmts --enable qemu-aarch64 || true
  if [[ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
       && grep -qx enabled /proc/sys/fs/binfmt_misc/qemu-aarch64; then
    return 0
  fi
  die 'AArch64 binfmt registration failed; a privileged host or container is required'
}

# extract_bsp_and_rootfs <sdk_dir> <bsp_tarball> <rootfs_tarball>
#
# Idempotent: if the rootfs is already prepared (marker file present), the
# call is a no-op. Otherwise extracts the BSP, untars the Sample RootFS
# into Linux_for_Tegra/rootfs, copies qemu-aarch64-static into the SDK on
# x86_64, runs apply_binaries.sh, and removes the helper afterwards.
extract_bsp_and_rootfs() {
  local sdk=$1 bsp=$2 sample=$3
  if [[ -f $sdk/.rootfs-initialized ]]; then return 0; fi
  local l4t="$sdk/Linux_for_Tegra"
  if [[ -d $l4t ]]; then
    log 'Removing incomplete NVIDIA rootfs setup before retrying'
    sudo rm -rf "$l4t"
  fi
  run tar -xjf "$bsp" -C "$sdk"
  [[ -x $l4t/apply_binaries.sh ]] || die 'BSP archive did not contain Linux_for_Tegra/apply_binaries.sh'
  sudo tar -xjpf "$sample" -C "$l4t/rootfs"
  if ! is_native_arm64; then
    [[ -x /usr/bin/qemu-aarch64-static ]] || die 'qemu-aarch64-static missing after host tool installation'
    sudo install -m 0755 /usr/bin/qemu-aarch64-static "$sdk/qemu-aarch64-static"
  fi
  if is_native_arm64; then
    install_qemu_user_static_stub "$l4t/rootfs"
  fi
  local -a apply_args=()
  is_native_arm64 && apply_args+=(--target-overlay)
  (cd "$l4t" && sudo ./apply_binaries.sh "${apply_args[@]}")
  if ! is_native_arm64; then sudo rm -f "$sdk/qemu-aarch64-static"; fi
  : > "$sdk/.rootfs-initialized"
}

# install_qemu_user_static_stub <target_root>
#
# Builds a tiny Debian package that pretends to be qemu-user-static so
# NVIDIA's apply_binaries.sh CheckPackage hook is satisfied on a native
# AArch64 host, where the real qemu-aarch64-static binary is unnecessary
# because chroot runs natively.
install_qemu_user_static_stub() {
  local target_root=$1
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
  run dpkg-deb -b "$stub_dir" "$stub_dir/qemu-user-static-stub.deb"
  sudo install -d -m 0755 "$target_root/tmp"
  sudo cp "$stub_dir/qemu-user-static-stub.deb" "$target_root/tmp/"
  rm -rf "$stub_dir"
  sudo chroot "$target_root" /bin/sh -c \
    "dpkg -i /tmp/qemu-user-static-stub.deb && rm /tmp/qemu-user-static-stub.deb"
}

# mount_chroot_filesystems <root>
#
# bind-mounts /dev (recursive), /proc, /sys into the rootfs so apt/dpkg
# inside the chroot can do their normal work. Writes policy-rc.d so init
# never tries to start daemons inside the chroot. Captures the mount list
# in $JETSON_MOUNTED for cleanup.
#
# Globals used:
#   JETSON_MOUNTED   array of mounted destinations; appended in place.
mount_chroot_filesystems() {
  local root=$1
  JETSON_MOUNTED=()
  if ! is_native_arm64; then
    sudo install -m 0755 /usr/bin/qemu-aarch64-static "$root/usr/bin/qemu-aarch64-static"
  fi
  sudo tee "$root/usr/sbin/policy-rc.d" >/dev/null <<'EOF'
#!/bin/sh
exit 101
EOF
  sudo chmod +x "$root/usr/sbin/policy-rc.d"
  sudo cp /etc/resolv.conf "$root/etc/resolv.conf"
  sudo mount --rbind /dev "$root/dev"
  sudo mount --make-rslave "$root/dev"
  JETSON_MOUNTED+=("$root/dev")
  local fs
  for fs in proc sys; do
    sudo mount --bind "/$fs" "$root/$fs"
    JETSON_MOUNTED+=("$root/$fs")
  done
}

# unmount_chroot_filesystems
#
# Unmounts everything captured by mount_chroot_filesystems and removes
# the helpers we put inside the rootfs.
unmount_chroot_filesystems() {
  local root=${1:?rootfs path required}
  local dest
  for dest in "${JETSON_MOUNTED[@]:-}"; do sudo umount -R "$dest" || true; done
  sudo rm -f "$root/usr/sbin/policy-rc.d" "$root/usr/bin/qemu-aarch64-static"
  JETSON_MOUNTED=()
}

# rootfs_exec <root> [--] <command> [args...]
#
# Runs a command inside the rootfs. Uses sudo chroot directly on a native
# AArch64 host, otherwise routes through qemu-aarch64-static.
rootfs_exec() {
  local root=$1; shift
  if is_native_arm64; then
    sudo chroot "$root" "$@"
  else
    sudo chroot "$root" /usr/bin/qemu-aarch64-static "$@"
  fi
}

# install_host_prereqs_offline
#
# Apt installs every package the build needs on the host. Splits between
# x86_64 (qemu-user-static + binfmt-support + aarch64 binutils) and
# native aarch64 (build-essential + binutils + lbzip2). Used by
# build_offline_direct().
install_host_prereqs_offline() {
  local -a host_packages=(
    ca-certificates curl gnupg cmake ninja-build pkg-config file python3 bzip2
  )
  if is_native_arm64; then
    host_packages+=(build-essential binutils lbzip2)
  else
    host_packages+=(qemu-user-static binfmt-support binutils-aarch64-linux-gnu)
  fi
  sudo apt-get -o Acquire::Retries=3 update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y "${host_packages[@]}"
}