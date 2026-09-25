#!/usr/bin/env bash
set -euo pipefail

script=./setup-jetson-cross-sdk-offline.sh

# Minimal Ubuntu containers run as root and do not ship sudo.
grep -Fq 'if (( EUID == 0 )); then' "$script"
grep -Fq 'sudo() { command env "$@"; }' "$script"

# Containerized hosts do not start binfmt-support automatically. The script
# must enable and verify AArch64 execution before apply_binaries.sh uses chroot.
grep -Fq 'update-binfmts --enable qemu-aarch64' "$script"
grep -Fq '/proc/sys/fs/binfmt_misc/qemu-aarch64' "$script"

# JetPack 6.1's apply_binaries.sh installs ARM64 BSP packages under QEMU, so
# make its preferred adjacent static binary available before invoking it.
qemu_prepare_line=$(grep -n 'qemu-aarch64-static "$sdk/qemu-aarch64-static"' "$script" | cut -d: -f1)
apply_line=$(grep -n 'sudo ./apply_binaries.sh' "$script" | cut -d: -f1)
[[ -n $qemu_prepare_line && -n $apply_line && $qemu_prepare_line -lt $apply_line ]]

# A failed rootfs setup must be restartable without redownloading the BSP and
# Sample RootFS archives. Only the incomplete extracted BSP tree is removed.
grep -Fq 'Removing incomplete NVIDIA rootfs setup before retrying' "$script"
grep -Fq 'sudo rm -rf "$l4t"' "$script"

# apply_binaries.sh installs an unsigned-by NVIDIA source for the same URLs.
# Keeping it active alongside jetson-cross-sdk.list makes apt reject both.
grep -Fq '"$bsp_source.disabled"' "$script"

# Jetson repositories expose versioned development packages (for example
# cuda-libraries-dev-12-6), while cuda-toolkit selects the release default.
grep -Fq 'apt-cache depends cuda-toolkit' "$script"
grep -Fq 'cuda-libraries-dev-$cuda_suffix' "$script"
grep -Fq 'cuda-nvcc-$cuda_suffix' "$script"
grep -Fq 'cuda-cross-aarch64-$cuda_suffix' "$script"

# /dev/pts is a nested mount. A plain bind of /dev makes apt/dpkg emit
# posix_openpt errors, so /dev must be recursively bound and unmounted.
grep -Fq 'mount --rbind /dev "$root/dev"' "$script"
grep -Fq 'umount -R "$dest"' "$script"

# TensorRT 10 installs headers in Debian's AArch64 multiarch include path.
grep -Fq '$root/usr/include/aarch64-linux-gnu/NvInfer.h' "$script"

# Bootlin's compiler does not infer Ubuntu's multiarch startup-object path
# from --sysroot, so both generated CMake builds and the smoke test need it.
grep -Fq -- '-B\${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu/' "$script"
grep -Fq -- '-B"$root/usr/lib/aarch64-linux-gnu/"' "$script"

# A failed late-stage run must reuse an already installed host nvcc instead
# of downloading the full CUDA cross stack again. In a container-mounted
# /usr/local, the update-alternatives symlink can be broken on the host, so
# the versioned directory is the reliable fallback.
grep -Fq 'cuda-$cuda_version/bin/nvcc' "$script"
grep -Fq 'if [[ -z $nvcc ]]; then' "$script"

# A container run writes paths consumed later on the host. Allow those paths
# to be supplied separately from the paths used while the script is running.
grep -Fq 'JETSON_SDK_ACTIVATE_PATH' "$script"
grep -Fq 'JETSON_NVCC_ACTIVATE_PATH' "$script"

# Installation may run in a container whose Ninja binary is not persisted to
# the host, so the printed host-side example must not force that generator.
! grep -Fq 'cmake -S PROJECT -B BUILD -G Ninja' "$script"
