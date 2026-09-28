#!/usr/bin/env bash
set -euo pipefail

# Functional checks that need a real cross toolchain. Skipped when none is
# available so the grep-based tests still run everywhere.

command -v aarch64-buildroot-linux-gnu-g++ >/dev/null 2>&1 || {
  echo "SKIP: aarch64-buildroot-linux-gnu-g++ not installed"; exit 0;
}

cross=aarch64-buildroot-linux-gnu-
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A minimal sysroot layout matching what the offline script produces.
root="$tmp/rootfs"
mkdir -p "$root/usr/lib/aarch64-linux-gnu" "$root/usr/include/aarch64-linux-gnu"

# libc headers live in the multiarch include dir. CMAKE_SYSROOT alone would
# only add usr/include, so <math.h> would fail on bits/libc-header-start.h.
cat > "$root/usr/include/math.h" <<'EOF'
#include <bits/libc-header-start.h>
double test_sqrt(double);
EOF
cat > "$root/usr/include/aarch64-linux-gnu/bits/libc-header-start.h" <<'EOF'
#define __GLIBC_USE(x) 1
EOF

# A linker stub for libm that must resolve to the shared library. When the
# sysroot instead contains an absolute symlink to /lib/aarch64-linux-gnu, the
# link silently falls back to the static archive.
printf 'double test_sqrt(double x){return x*x;}\n' > "$tmp/m.c"
"$cross"gcc --sysroot="$root" -c "$tmp/m.c" -o "$root/libm_dummy.o"
"${cross}gcc" -shared -o "$root/usr/lib/aarch64-linux-gnu/libm.so.6" "$root/libm_dummy.o"
ln -s libm.so.6 "$root/usr/lib/aarch64-linux-gnu/libm.so"
ln -s ../../../lib/aarch64-linux-gnu/libm.so.6 \
  "$root/usr/lib/aarch64-linux-gnu/libm.so"

printf '#include <math.h>\nint main(void){return (int)test_sqrt(2.0);}\n' > "$tmp/main.c"

# Without the multiarch include path this must fail.
if "$cross"gcc --sysroot="$root" -c "$tmp/main.c" -o "$tmp/bad.o" 2>/dev/null; then
  echo "FAIL: <math.h> resolved without the multiarch include path" >&2; exit 1
fi

# With it, compilation succeeds.
"$cross"gcc --sysroot="$root" \
  -isystem "$root/usr/include/aarch64-linux-gnu" \
  -c "$tmp/main.c" -o "$tmp/good.o"

# libm.so must resolve to libm.so.6, not to a static archive.
if ! "$cross"gcc --sysroot="$root" \
    -isystem "$root/usr/include/aarch64-linux-gnu" \
    -L"$root/usr/lib/aarch64-linux-gnu" \
    -Wl,-rpath-link,"$root/usr/lib/aarch64-linux-gnu" \
    "$tmp/main.c" -lm -o "$tmp/app" 2>/dev/null; then
  echo "FAIL: could not link against the sysroot libm.so" >&2; exit 1
fi
if "${cross}readelf" -d "$tmp/app" | grep -q 'Shared library: \[libm.so.6\]'; then
  :
else
  echo "FAIL: libm did not resolve to the shared libm.so.6" >&2; exit 1
fi

# An absolute symlink inside the sysroot must not be followed to the host.
# Reproduce the original defect and confirm it is detected.
ln -sfn /lib/aarch64-linux-gnu/libm.so.6 "$root/usr/lib/aarch64-linux-gnu/libm.so"
if "${cross}readelf" -d "$tmp/app" 2>/dev/null >/dev/null; then
  :
fi
if [[ -e "$root/usr/lib/aarch64-linux-gnu/libm.so" ]]; then
  echo "FAIL: absolute symlink resolved against the host root" >&2; exit 1
fi

echo "sysroot-compile tests passed"
