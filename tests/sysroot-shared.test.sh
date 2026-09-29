#!/usr/bin/env bash
# Verifies lib/sysroot-shared.sh rewrites absolute symlinks inside a
# sysroot to relative ones and reports the ones it could not rewrite.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

source "$repo/lib/common.sh"
source "$repo/lib/sysroot-shared.sh"

# Build a small fake sysroot that contains:
#  - one absolute symlink that points inside (must be rewritten)
#  - one absolute symlink that points outside (must be reported)
#  - one relative symlink (must be left alone)
root=$tmp/rootfs
mkdir -p "$root/lib/aarch64-linux-gnu" "$root/usr/lib/aarch64-linux-gnu" "$root/etc"
echo ok > "$root/lib/aarch64-linux-gnu/libfoo.so.6"
ln -s /lib/aarch64-linux-gnu/libfoo.so.6 "$root/usr/lib/aarch64-linux-gnu/libfoo.so"
ln -s /dev/null "$root/etc/devnull"
ln -s ../lib/aarch64-linux-gnu/libfoo.so.6 "$root/usr/lib/aarch64-linux-gnu/libfoo-relative.so"

report=$tmp/escaping.txt
normalize_sysroot_symlinks "$root" "$report"

# Absolute inside-target link: must now be relative.
link_target=$(readlink "$root/usr/lib/aarch64-linux-gnu/libfoo.so")
[[ $link_target = "../../../lib/aarch64-linux-gnu/libfoo.so.6" ]]

# Absolute outside-target link: must still be absolute.
[[ $(readlink "$root/etc/devnull") = "/dev/null" ]]

# Relative symlink: must be unchanged.
[[ $(readlink "$root/usr/lib/aarch64-linux-gnu/libfoo-relative.so") = "../lib/aarch64-linux-gnu/libfoo.so.6" ]]

# Report file must mention the outside link and not the rewritten one.
[[ -f $report ]]
grep -Fq 'etc/devnull -> /dev/null' "$report"
! grep -Fq 'libfoo.so' "$report"

# slim_sdk removes the expected paths without touching dev-null links.
slim_sdk "$tmp/sdk" "$root"
[[ ! -d $root/usr/share/doc ]]
# dev-null symlink survives the slimming.
[[ $(readlink "$root/etc/devnull") = "/dev/null" ]]

echo "sysroot-shared.test.sh passed"