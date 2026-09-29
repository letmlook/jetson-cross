#!/usr/bin/env bash
set -euo pipefail

# Regression contract: an ARM64 Ubuntu host prepares the Jetson rootfs and
# validates an ARM64 build natively, without QEMU or the x86 Bootlin compiler.
repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/setup-jetson-cross-sdk-offline.sh"
tmp=$(mktemp -d)
cleanup_test() {
  status=$?
  if [[ $status -ne 0 && -f ${COMMAND_LOG:-} ]]; then
    printf '%s\n' '--- recorded external commands ---' >&2
    cat "$COMMAND_LOG" >&2
  fi
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup_test EXIT
fakebin="$tmp/bin"
fixtures="$tmp/fixtures"
sdk="$tmp/sdk"
mkdir -p "$fakebin" "$fixtures/bsp/Linux_for_Tegra/rootfs" \
  "$fixtures/rootfs/etc/apt/sources.list.d" \
  "$fixtures/rootfs/etc/apt/apt.conf.d" \
  "$fixtures/rootfs/usr/share/keyrings" \
  "$fixtures/rootfs/usr/sbin" \
  "$fixtures/rootfs/usr/bin" \
  "$fixtures/rootfs/usr/include/aarch64-linux-gnu" \
  "$fixtures/rootfs/usr/lib/aarch64-linux-gnu" \
  "$fixtures/rootfs/usr/local/cuda-12.6/bin"

cat > "$fixtures/bsp/Linux_for_Tegra/apply_binaries.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$fixtures/bsp/Linux_for_Tegra/apply_binaries.sh"
: > "$fixtures/rootfs/usr/include/aarch64-linux-gnu/NvInfer.h"
cat > "$fixtures/rootfs/usr/local/cuda-12.6/bin/nvcc" <<'EOF'
#!/bin/sh
printf '%s\n' 'Cuda compilation tools, release 12.6, V12.6.0'
EOF
chmod +x "$fixtures/rootfs/usr/local/cuda-12.6/bin/nvcc"
# The script refuses to declare success without a usable cuDNN, so the
# fixture rootfs must carry the header and library the checks look for.
: > "$fixtures/rootfs/usr/include/cudnn.h"
: > "$fixtures/rootfs/usr/lib/aarch64-linux-gnu/libcudnn.so"
tar -cjf "$tmp/bsp.tbz2" -C "$fixtures/bsp" Linux_for_Tegra
tar -cjf "$tmp/rootfs.tbz2" -C "$fixtures/rootfs" .

cat > "$tmp/os-release" <<'EOF'
ID=ubuntu
VERSION_ID=22.04
VERSION_CODENAME=jammy
EOF

cat > "$fakebin/uname" <<'EOF'
#!/bin/sh
test "${1:-}" = -m && printf '%s\n' aarch64
EOF
cat > "$fakebin/apt-get" <<'EOF'
#!/bin/sh
printf 'apt-get %s\n' "$*" >> "$COMMAND_LOG"
EOF
cat > "$fakebin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' test-key
EOF
cat > "$fakebin/gpg" <<'EOF'
#!/bin/sh
cat
EOF
cat > "$fakebin/chroot" <<'EOF'
#!/bin/sh
printf 'chroot %s\n' "$*" >> "$COMMAND_LOG"
case "$*" in
  *'apt-cache depends cuda-toolkit'*) printf '%s\n' '12-6' ;;
esac
EOF
cat > "$fakebin/mount" <<'EOF'
#!/bin/sh
printf 'mount %s\n' "$*" >> "$COMMAND_LOG"
EOF
cat > "$fakebin/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$COMMAND_LOG"
EOF
cat > "$fakebin/pkg-config" <<'EOF'
#!/bin/sh
printf '%s\n' 1.0
EOF
cat > "$fakebin/g++" <<'EOF'
#!/bin/sh
out=
while test "$#" -gt 0; do
  if test "$1" = -o; then out=$2; shift 2; else shift; fi
done
test -n "$out"
: > "$out"
chmod +x "$out"
EOF
cat > "$fakebin/readelf" <<'EOF'
#!/bin/sh
if test "${1:-}" = -d; then
  printf '%s\n' 'Shared library: [libm.so.6]'
  printf '%s\n' 'Shared library: [libcudart]'
  printf '%s\n' 'Shared library: [libcudnn]'
else
  printf '%s\n' '  Machine: AArch64'
fi
EOF
cat > "$fakebin/file" <<'EOF'
#!/bin/sh
printf '%s: ELF 64-bit LSB executable, ARM aarch64\n' "$1"
EOF
cat > "$fakebin/sudo" <<'EOF'
#!/bin/sh
exec env "$@"
EOF
chmod +x "$fakebin"/*

export COMMAND_LOG="$tmp/commands.log"
: > "$COMMAND_LOG"
PATH="$fakebin:$PATH" JETSON_OS_RELEASE_FILE="$tmp/os-release" \
  bash "$script" 6.2.1 "$sdk" "$tmp/bsp.tbz2" "$tmp/rootfs.tbz2"

test -f "$sdk/.setup-complete"
test -x "$sdk/activate.sh"
test -x "$sdk/bin/nvcc"
test -d "$sdk/cuda-host-include"
# The activation file resolves every path from its own location instead of
# baking in build-time absolutes, so source it and assert the values a native
# ARM64 host must see rather than grep for template text.
(
  # shellcheck disable=SC1091
  . "$sdk/activate.sh"
  [[ -z $JETSON_CROSS ]]
  # CUDACXX points at the SDK-local wrapper so CMake's compiler-detection
  # step can reach sysroot CUDA headers; the wrapper forwards to the real
  # nvcc that lives next to it.
  [[ $CUDACXX = "$sdk/bin/nvcc" ]]
  [[ $JETSON_ROOTFS = "$sdk/Linux_for_Tegra/rootfs" ]]
)
grep -Fq 'chroot ' "$COMMAND_LOG"
! grep -Fq 'qemu-aarch64' "$COMMAND_LOG"
! test -d "$sdk/toolchain/aarch64--glibc--stable-2022.08-1"
