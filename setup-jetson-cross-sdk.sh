#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: ./setup-jetson-cross-sdk.sh user@jetson L4T_VERSION CUDA_VERSION [SDK_DIRECTORY]
# Supported: L4T R35/R36, x86_64 Ubuntu 20.04/22.04. No target package changes.
TARGET=${1:-}
REQUEST_L4T=${2:-}
cuda_version=${3:-}
SDK=${4:-"$HOME/jetson-cross-sdk-r${REQUEST_L4T}-cuda-${cuda_version}"}
[[ -n $TARGET && $TARGET != -* && $# -ge 3 && $# -le 4 ]] || {
  echo "Usage: $0 user@jetson 36.4 12.2 [sdk-directory]" >&2; exit 2;
}
[[ $REQUEST_L4T =~ ^(35|36)\.[0-9]+$ && $cuda_version =~ ^[0-9]+\.[0-9]+$ ]] || {
  echo 'Expected L4T major.minor (35.x or 36.x) and CUDA major.minor, e.g. 36.4 12.2' >&2; exit 2;
}
[[ $SDK = /* ]] || SDK="$PWD/$SDK"
[[ $(uname -m) = x86_64 ]] || { echo 'x86_64 host required' >&2; exit 1; }
. /etc/os-release
[[ $ID = ubuntu && ( $VERSION_ID = 20.04 || $VERSION_ID = 22.04 ) ]] || {
  echo 'Supported host: Ubuntu 20.04 or 22.04 x86_64' >&2; exit 1;
}
command -v ssh >/dev/null || { echo 'Install openssh-client first' >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
trap 'echo "Failed at line $LINENO. SDK path: $SDK" >&2' ERR

log 'Checking requested versions against target (read-only)'
remote=$(ssh -o BatchMode=yes "$TARGET" 'set -e; test "$(uname -m)" = aarch64; dpkg-query -W -f="${Version}" nvidia-l4t-core; echo; if test -f /usr/local/cuda/version.json; then sed -n "s/.*\"version\"[[:space:]]*:[[:space:]]*\"\([0-9]*\.[0-9]*\).*$/\1/p" /usr/local/cuda/version.json | head -1; fi; readlink -f /usr/local/cuda || true; dpkg-query -W -f="${Package} ${Version}\n" libnvinfer-dev libopencv-dev libgstreamer1.0-dev libavformat-dev 2>/dev/null || true')
l4t=$(printf '%s\n' "$remote" | sed -n '1p')
major=${l4t%%.*}; minor=$(printf '%s' "$l4t" | cut -d. -f2)
[[ $major.$minor = "$REQUEST_L4T" ]] || die "Requested L4T $REQUEST_L4T but target has $l4t"
cuda_path=$(printf '%s\n' "$remote" | grep -m1 '^/usr/local/cuda-' || true)
target_cuda=$(printf '%s\n' "$cuda_path" | sed -n 's@^/usr/local/cuda-\([0-9]*\.[0-9]*\).*@\1@p')
[[ -n $target_cuda ]] || target_cuda=$(printf '%s\n' "$remote" | sed -n '2p' | grep -E '^[0-9]+\.[0-9]+$' || true)
[[ $target_cuda = "$cuda_version" ]] || die "Requested CUDA $cuda_version but target CUDA is ${target_cuda:-undetected}. Check /usr/local/cuda."
cuda_pkg=${cuda_version/./-}
if [[ $major = 35 ]]; then toolchain_release=2020.08-1; else toolchain_release=2022.08-1; fi
toolchain_name="aarch64--glibc--stable-${toolchain_release}"
repo="r${major}.${minor}"
log "Target L4T=$l4t CUDA=$cuda_version; host repo=$repo"
printf '%s\n' "$remote" | tail -n +4

log 'Installing host prerequisites'
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg rsync openssh-client cmake ninja-build pkg-config file python3 binutils-aarch64-linux-gnu

log 'Adding NVIDIA Jetson x86 apt repository with scoped signing key'
sudo install -d -m 0755 /etc/apt/keyrings
key_tmp=$(mktemp)
trap 'rm -f "${key_tmp:-}"' EXIT
curl -fsSL https://repo.download.nvidia.com/jetson/jetson-ota-public.asc -o "$key_tmp"
gpg --dearmor < "$key_tmp" | sudo tee /etc/apt/keyrings/nvidia-jetson.gpg >/dev/null
sudo chmod 0644 /etc/apt/keyrings/nvidia-jetson.gpg
codename=$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")
printf 'deb [signed-by=/etc/apt/keyrings/nvidia-jetson.gpg] https://repo.download.nvidia.com/jetson/x86_64/%s %s main\n' "$codename" "$repo" \
  | sudo tee /etc/apt/sources.list.d/jetson-cross-sdk.list >/dev/null
sudo apt-get update

log 'Installing matching host nvcc and AArch64 CUDA cross support'
for pkg in "cuda-nvcc-$cuda_pkg" "cuda-cross-aarch64-$cuda_pkg"; do
  apt-cache show "$pkg" 2>/dev/null | grep -q '^Package:' || die "$pkg unavailable in $repo for $codename; check target compute-stack upgrade and NVIDIA host repository. No CUDA version substitution was made."
done
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "cuda-nvcc-$cuda_pkg" "cuda-cross-aarch64-$cuda_pkg"
nvcc="/usr/local/cuda-$cuda_version/bin/nvcc"
[[ -x $nvcc ]] || die "Host nvcc missing: $nvcc"

log 'Downloading the L4T-matched Bootlin compiler'
mkdir -p "$SDK/toolchain" "$SDK/sysroot" "$SDK/example"
archive="$SDK/toolchain/$toolchain_name.tar.bz2"
if [[ ! -x $SDK/toolchain/$toolchain_name/bin/aarch64-buildroot-linux-gnu-g++ ]]; then
  curl -fL --retry 3 -o "$archive.part" \
    "https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/$toolchain_name.tar.bz2"
  mv "$archive.part" "$archive"
  tar -xjf "$archive" -C "$SDK/toolchain"
fi
cross="$SDK/toolchain/$toolchain_name/bin/aarch64-buildroot-linux-gnu-"
[[ -x ${cross}g++ ]] || die 'Bootlin compiler not found after extraction'

log 'Synchronizing target sysroot (target is never modified)'
# sudo -n on target must be configured if the SSH user cannot read all target files.
for dir in lib usr opt; do
  mkdir -p "$SDK/sysroot/$dir"
  rsync -aH --numeric-ids --no-owner --no-group --delete \
    --rsync-path='sudo -n rsync' "$TARGET:/$dir/" "$SDK/sysroot/$dir/" \
    || die 'Target sudo -n rsync failed. Grant read-only filesystem access through target sudoers or run SSH as root.'
done
[[ -f $SDK/sysroot/usr/include/NvInfer.h ]] || die 'Target libnvinfer-dev/NvInfer.h missing. Install the development package on Jetson and rerun.'
for path in usr/include/opencv4/opencv2/core.hpp usr/include/gstreamer-1.0/gst/gst.h usr/include/libavformat/avformat.h; do
  [[ -f $SDK/sysroot/$path ]] || die "Target development header missing: /$path"
done

log 'Making absolute symlinks self-contained inside the host sysroot'
python3 - "$SDK/sysroot" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
for base, dirs, files in os.walk(root, followlinks=False):
    for name in dirs + files:
        link = pathlib.Path(base) / name
        if not link.is_symlink():
            continue
        target = os.readlink(link)
        if not target.startswith('/'):
            continue
        destination = root / target.lstrip('/')
        if destination.exists() or destination.is_symlink():
            link.unlink()
            link.symlink_to(os.path.relpath(destination, link.parent))
PY

cat > "$SDK/activate.sh" <<EOF
#!/usr/bin/env bash
export JETSON_SDK='$SDK'
export JETSON_CROSS='${cross}'
export CROSS_COMPILE='${cross}'
export CUDACXX='$nvcc'
export CUDAHOSTCXX='${cross}g++'
export PKG_CONFIG_SYSROOT_DIR='$SDK/sysroot'
export PKG_CONFIG_LIBDIR='$SDK/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:$SDK/sysroot/usr/lib/pkgconfig:$SDK/sysroot/usr/share/pkgconfig:$SDK/sysroot/usr/local/lib/aarch64-linux-gnu/pkgconfig:$SDK/sysroot/usr/local/lib/pkgconfig'
unset PKG_CONFIG_PATH
EOF
cat > "$SDK/toolchain.cmake" <<'EOF'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_SYSROOT "$ENV{JETSON_SDK}/sysroot")
set(CMAKE_C_COMPILER "$ENV{JETSON_CROSS}gcc")
set(CMAKE_CXX_COMPILER "$ENV{JETSON_CROSS}g++")
set(CMAKE_CUDA_COMPILER "$ENV{CUDACXX}")
set(CMAKE_CUDA_HOST_COMPILER "$ENV{CUDAHOSTCXX}")
set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_EXE_LINKER_FLAGS_INIT "-Wl,-rpath-link,${CMAKE_SYSROOT}/lib/aarch64-linux-gnu -Wl,-rpath-link,${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu -Wl,-rpath-link,${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu/tegra -Wl,-rpath-link,${CMAKE_SYSROOT}/usr/local/cuda/lib64")
EOF
cat > "$SDK/example/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.18)
project(jetson_sdk_check LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
find_package(PkgConfig REQUIRED)
pkg_check_modules(CV REQUIRED IMPORTED_TARGET opencv4)
pkg_check_modules(GST REQUIRED IMPORTED_TARGET gstreamer-1.0)
pkg_check_modules(AV REQUIRED IMPORTED_TARGET libavformat libavcodec libavutil)
find_path(TRT_INCLUDE NvInfer.h REQUIRED)
find_library(TRT_LIB nvinfer REQUIRED)
add_executable(jetson_sdk_check main.cpp)
target_include_directories(jetson_sdk_check PRIVATE "${TRT_INCLUDE}")
target_link_libraries(jetson_sdk_check PRIVATE PkgConfig::CV PkgConfig::GST PkgConfig::AV "${TRT_LIB}")
EOF
cat > "$SDK/example/main.cpp" <<'EOF'
#include <iostream>
#include <opencv2/core.hpp>
#include <gst/gst.h>
#include <libavformat/avformat.h>
#include <NvInferVersion.h>
int main() {
  gst_init(nullptr, nullptr);
  std::cout << "OpenCV " << CV_VERSION << "\nGStreamer " << gst_version_string()
            << "\nFFmpeg " << av_version_info() << "\nTensorRT "
            << NV_TENSORRT_MAJOR << '.' << NV_TENSORRT_MINOR << '\n';
}
EOF

log 'Validating pkg-config and compiling the AArch64 sample'
source "$SDK/activate.sh"
pkg-config --modversion opencv4 gstreamer-1.0 libavformat
cmake -S "$SDK/example" -B "$SDK/example/build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$SDK/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release
cmake --build "$SDK/example/build"
file "$SDK/example/build/jetson_sdk_check"
"${cross}readelf" -h "$SDK/example/build/jetson_sdk_check" | grep 'Machine:.*AArch64' >/dev/null \
  || die 'Verification failed: output is not AArch64'
"$nvcc" --version | tail -n 1
log "Ready. Run: source '$SDK/activate.sh'"
echo "Build: cmake -S /path/to/project -B /path/to/build -G Ninja -DCMAKE_TOOLCHAIN_FILE='$SDK/toolchain.cmake'"
echo "Target test: scp '$SDK/example/build/jetson_sdk_check' '$TARGET:/tmp/' && ssh '$TARGET' /tmp/jetson_sdk_check"
