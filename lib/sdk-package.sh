# shellcheck shell=bash
# Archive a finished SDK directory into a single file. zstd is the default
# (smaller output, similar speed); gzip/pigz are the fallback when zstd
# is unavailable.

# default_archive_name <sdk_dir>
#
# Returns a filename suggestion for the archive, derived from the SDK
# directory's basename. Compresses to .tar.zst unless zstd is missing,
# in which case .tar.gz.
default_archive_name() {
  local sdk=$1
  local ext=tar.zst
  if ! command -v zstd >/dev/null; then ext=tar.gz; fi
  printf '%s.%s' "$sdk" "$ext"
}

# package_sdk <sdk_dir> [<archive>]
#
# Writes the SDK to <archive>, defaulting to <sdk>.tar.zst beside the SDK.
# Verifies the archive is non-empty and that the three sentinel files
# (activate.sh, toolchain.cmake, .setup-complete) are listed inside.
package_sdk() {
  local sdk=$1
  local archive=${2:-$(default_archive_name "$sdk")}
  local list_flags=(--zstd)
  local compressor='zstd -T0 -q'
  if ! command -v zstd >/dev/null; then
    list_flags=(-z)
    if command -v pigz >/dev/null; then compressor=pigz
    else compressor=gzip
    fi
  fi
  local archive_tmp="$archive.new"
  local sdk_basename
  sdk_basename=$(basename "$sdk")
  log "Packaging SDK into ${archive##*/} (via $compressor)"
  sudo tar -I "$compressor" -cf "$archive_tmp" \
    -C "$(dirname "$sdk")" "$sdk_basename"
  # Listing the archive back decompresses the whole stream, doubling as
  # an integrity check of everything tar wrote.
  local found
  found=$(tar "${list_flags[@]}" -tf "$archive_tmp" 2>/dev/null \
    | grep -cE "^${sdk_basename}/(activate\.sh|toolchain\.cmake|\.setup-complete)$" || true)
  local required=3
  [[ $found = $required ]] || die "Packaged archive is incomplete (found $found of $required required files)"
  sudo chown "$(id -un)" "$archive_tmp"
  mv -f "$archive_tmp" "$archive"
  printf '    archive: %s\n' "$archive"
  if [[ $archive = *.zst ]]; then
    printf '    extract with: tar --zstd -xf %s\n' "$(basename "$archive")"
  else
    printf '    extract with: tar -xf %s\n' "$(basename "$archive")"
  fi
}