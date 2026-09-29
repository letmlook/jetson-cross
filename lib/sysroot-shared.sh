# shellcheck shell=bash
# Sysroot operations used by both the online (rsync) and offline (BSP
# extract) build paths: rewriting absolute symlinks so they resolve inside
# the sysroot rather than against the host root, and slimming the sysroot
# after a successful build.

# normalize_sysroot_symlinks <root> [report_path]
#
# Rewrites every absolute symlink inside <root> whose target exists inside
# <root> into a relative link. Anything that points outside the root or to
# a missing target is left alone and recorded in the optional report.
normalize_sysroot_symlinks() {
  local root=$1 report=${2:-}
  local out rewritten escaping=0
  out=$(sudo python3 - "$root" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
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
            if root not in dest.parents or not dest.exists():
                escaping.append(f"{link.relative_to(root)} -> {target}")
                continue
            relative = os.path.relpath(dest, link.parent)
            link.unlink()
            link.symlink_to(relative)
            rewritten += 1
        except OSError:
            continue
print(rewritten)
for entry in escaping:
    print(entry)
PY
  )
  rewritten=${out%%$'\n'*}
  if [[ $out == *$'\n'* ]]; then
    escaping=$(($(printf '%s\n' "$out" | wc -l) - 1))
  fi
  if [[ -n $report ]]; then
    {
      echo '# Absolute symlinks kept as-is because their target is not inside the'
      echo '# sysroot. They still resolve against the host root at build time and'
      echo '# do not take part in cross-compilation of the Jetson target.'
      printf '%s\n' "${out#*$'\n'}"
    } > "$report"
  fi
  printf '    %s absolute symlinks rewritten, %s left escaping (recorded%s)\n' \
    "$rewritten" "$escaping" "${report:+ in ${report##*/}}"
}

# slim_sdk <sdk_dir> <root_dir>
#
# Removes install-only material from a finished SDK: the downloaded BSP
# archive, the apt cache, package index, documentation, manual pages,
# translated catalogues, compiled Python bytecode, and the OTA package
# directory. None of these participate in cross-compilation.
slim_sdk() {
  local sdk=$1 root=$2
  if [[ -d "$sdk/downloads" ]]; then
    sudo find "$sdk/downloads" -mindepth 1 -delete 2>/dev/null || true
  fi
  local path
  for path in \
    "$root/var/cache/apt" \
    "$root/var/lib/apt/lists" \
    "$root/var/cache/debconf" \
    "$root/var/log" \
    "$root/usr/share/doc" \
    "$root/usr/share/man" \
    "$root/usr/share/info" \
    "$root/usr/share/locale" \
    "$root/usr/share/i18n" \
    "$root/opt/ota_package"
  do
    [[ -d $path ]] && sudo find "$path" -mindepth 1 -delete 2>/dev/null || true
  done
  sudo find "$root" -type f -name '*.pyc' -delete 2>/dev/null || true
  sudo find "$root" -type d -name __pycache__ -prune \
    -exec find {} -mindepth 1 -delete \; 2>/dev/null || true
}

# slim_sdk_rsourced <sysroot>
#
# Same idea, used by the online path where the sysroot is named sysroot/
# rather than Linux_for_Tegra/rootfs/ and there is no downloads/ tree to
# drop. Kept separate so the two flows don't share a "where is everything"
# map.
slim_sdk_rsourced() {
  local root=$1
  local path
  for path in \
    "$root/var/cache/apt" \
    "$root/var/lib/apt/lists" \
    "$root/var/cache/debconf" \
    "$root/var/log" \
    "$root/usr/share/doc" \
    "$root/usr/share/man" \
    "$root/usr/share/info" \
    "$root/usr/share/locale" \
    "$root/usr/share/i18n"
  do
    [[ -d $path ]] && find "$path" -mindepth 1 -delete 2>/dev/null || true
  done
  find "$root" -type f -name '*.pyc' -delete 2>/dev/null || true
  find "$root" -type d -name __pycache__ -prune \
    -exec find {} -mindepth 1 -delete \; 2>/dev/null || true
}