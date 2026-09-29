# shellcheck shell=bash
# Host detection: architecture, OS, distro, container/root status, and
# whether the host is itself a Jetson device. Pure read-only checks; no
# environment changes.

# Set sane defaults from /etc/os-release without overriding anything the
# caller has already set.
detect_os_release() {
  local file=${JETSON_OS_RELEASE_FILE:-/etc/os-release}
  [[ -r $file ]] || { warn "$file not readable; assuming generic Linux"; return 0; }
  # shellcheck disable=SC1090
  . "$file"
  export ID VERSION_ID VERSION_CODENAME
}

# Print 'x86_64', 'aarch64', or 'unknown'. Uses uname -m.
detect_arch() { uname -m; }

# Print 'linux' or 'darwin' or 'unknown'. Uses uname -s.
detect_kernel() { uname -s | tr '[:upper:]' '[:lower:]'; }

# Detect whether the host is a Jetson device. Looks for the
# /etc/nv_tegra_release marker NVIDIA ships on every Jetson.
is_jetson_device() { [[ -r /etc/nv_tegra_release ]]; }

# Detect whether the host is inside a Docker container.
is_in_container() {
  [[ -r /proc/1/cgroup ]] && grep -qE '/docker|/kubepods' /proc/1/cgroup 2>/dev/null
}

# Detect macOS arm64 specifically.
is_macos_arm64() {
  [[ $(detect_kernel) = darwin && $(detect_arch) = arm64 ]]
}

# Detect native AArch64 Linux (vs. an x86_64 Linux running under QEMU).
is_native_arm64() { [[ $(detect_kernel) = linux && $(detect_arch) = aarch64 ]]; }

# Determine a sensible default --platform from the host. The caller can
# still override via --platform=. Returns one of:
#   linux-x86, linux-arm64, macos-arm64, jetson
default_platform() {
  if is_jetson_device; then printf '%s' jetson; return; fi
  if is_macos_arm64; then printf '%s' macos-arm64; return; fi
  case "$(detect_arch)" in
    x86_64) printf '%s' linux-x86 ;;
    aarch64) printf '%s' linux-arm64 ;;
    *) die "Unsupported host architecture: $(detect_arch)" ;;
  esac
}

# Determine a sensible default --mode for the resolved platform.
# macos-arm64 is always docker; everything else defaults to direct.
default_mode_for_platform() {
  case "$1" in
    macos-arm64) printf '%s' docker ;;
    *) printf '%s' direct ;;
  esac
}

# Determine the appropriate Ubuntu version for the target L4T release. L4T
# 35.x targets Ubuntu 20.04; L4T 36.x targets Ubuntu 22.04. Used to pick
# the right Docker base image tag.
ubuntu_version_for_l4t() {
  local l4t=$1
  local major=${l4t%%.*}
  if [[ $major = 35 ]]; then printf '%s' 20.04
  elif [[ $major = 36 ]]; then printf '%s' 22.04
  else die "Unsupported L4T major version: $major (only 35 and 36 are wired up)"
  fi
}

# Determine the Bootlin toolchain release for the L4T major. The two
# releases are stable and pinned by the build.
bootlin_toolchain_for_l4t() {
  local l4t=$1
  local major=${l4t%%.*}
  if [[ $major = 35 ]]; then printf '%s' 2020.08-1
  elif [[ $major = 36 ]]; then printf '%s' 2022.08-1
  else die "Unsupported L4T major version: $major"
  fi
}