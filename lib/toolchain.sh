# shellcheck shell=bash
# Toolchain selection: either download a Bootlin glibc-stable cross
# compiler, or use the host's native AArch64 GCC. The offline script
# chooses native when the host is already AArch64 Linux and Bootlin when
# it is x86_64.

# toolchain_for_target <L4T_VERSION>
#
# Sets globals:
#   BOOTLIN_TOOLCHAIN_RELEASE   e.g. 2022.08-1
#   BOOTLIN_TOOLCHAIN_NAME      e.g. aarch64--glibc--stable-2022.08-1
#   BOOTLIN_TOOLCHAIN_URL       full download URL
#   BOOTLIN_TOOLCHAIN_DIR       where it lives inside the SDK ($sdk/toolchain/<name>)
toolchain_for_target() {
  local l4t=$1
  BOOTLIN_TOOLCHAIN_RELEASE=$(bootlin_toolchain_for_l4t "$l4t")
  BOOTLIN_TOOLCHAIN_NAME="aarch64--glibc--stable-${BOOTLIN_TOOLCHAIN_RELEASE}"
  BOOTLIN_TOOLCHAIN_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/${BOOTLIN_TOOLCHAIN_NAME}.tar.bz2"
}

# download_bootlin_toolchain <sdk_dir>
#
# Downloads and extracts the Bootlin compiler into <sdk_dir>/toolchain/<name>.
# Idempotent: skips the download when the compiler is already present.
download_bootlin_toolchain() {
  local sdk=$1
  : "${BOOTLIN_TOOLCHAIN_NAME:?call toolchain_for_target first}"
  : "${BOOTLIN_TOOLCHAIN_URL:?call toolchain_for_target first}"
  local dst="$sdk/toolchain/$BOOTLIN_TOOLCHAIN_NAME"
  local bin="$dst/bin/aarch64-buildroot-linux-gnu-g++"
  if [[ -x $bin ]]; then return 0; fi
  mkdir -p "$sdk/toolchain"
  local archive="$sdk/downloads/$BOOTLIN_TOOLCHAIN_NAME.tar.bz2"
  [[ -s $archive ]] || \
    run curl -fL --retry 3 --retry-all-errors -o "$archive" "$BOOTLIN_TOOLCHAIN_URL"
  run tar -xjf "$archive" -C "$sdk/toolchain"
  [[ -x $bin ]] || die "Bootlin compiler not found after extraction: $bin"
}

# cross_prefix_for_sdk <sdk_dir>
#
# Returns the cross compiler prefix path (with trailing -) for the SDK's
# Bootlin compiler. Empty string if the compiler isn't present.
cross_prefix_for_sdk() {
  local sdk=$1
  if [[ -n ${BOOTLIN_TOOLCHAIN_NAME:-} ]]; then
    [[ -x $sdk/toolchain/$BOOTLIN_TOOLCHAIN_NAME/bin/aarch64-buildroot-linux-gnu-g++ ]] \
      && { printf '%s' "$sdk/toolchain/$BOOTLIN_TOOLCHAIN_NAME/bin/aarch64-buildroot-linux-gnu-"; return; }
  fi
  # Fallback: search the SDK for any installed toolchain with the expected bin layout.
  local found
  found=$(find "$sdk/toolchain" -maxdepth 4 -name 'aarch64-buildroot-linux-gnu-g++' -print -quit 2>/dev/null || true)
  if [[ -n $found ]]; then
    printf '%s' "$(dirname "$found")/aarch64-buildroot-linux-gnu-"
  else
    printf '%s' ""
  fi
}

# assert_native_arm64_compiler
#
# Used by the native AArch64 build path. Exits with a helpful error if the
# host doesn't have a working aarch64-targeting g++/readelf.
assert_native_arm64_compiler() {
  command -v g++ >/dev/null      || die 'Native g++ is required on an AArch64 host'
  command -v readelf >/dev/null  || die 'Native readelf (binutils) is required on an AArch64 host'
}