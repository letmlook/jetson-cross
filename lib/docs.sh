# shellcheck shell=bash
# Render and ship the SDK-internal usage guide. The guide is a standalone
# Markdown file kept in templates/usage-guide.md so it can be emitted
# independently of any build context.

# usage_guide_template_path
#
# Returns the absolute path to templates/usage-guide.md. Falls back to
# an empty file if the template is missing (so the build still
# succeeds in a partial checkout).
usage_guide_template_path() {
  local p
  p="$JETSON_CROSS_LIB_DIR/../templates/usage-guide.md"
  if [[ ! -f $p ]]; then
    warn "usage guide template not found at $p; SDK will ship without a usage guide"
    printf '%s' ""
  else
    printf '%s' "$p"
  fi
}

# render_usage_guide_sdk [--out PATH]
#
# Reads the usage guide template and writes it to PATH (or stdout when
# --out is omitted). Renders any @TOKEN@ placeholders the template may
# still carry. This is the single entry point that:
#   1. The build flow calls after a successful SDK is produced.
#   2. `jetson-cross usage-guide` calls to emit a doc into an existing
#      SDK without rebuilding anything.
render_usage_guide_sdk() {
  local out=""
  while (( $# )); do
    case $1 in
      --out) out=$2; shift 2 ;;
      *) die "render_usage_guide_sdk: unknown argument: $1" ;;
    esac
  done
  local template
  template=$(usage_guide_template_path)
  [[ -n $template ]] || return 1
  local rendered
  rendered=$(sed -e "s|@JETPACK@|${JETPACK_VERSION:-}|g" \
                 -e "s|@L4T@|${L4T_VERSION:-}|g" \
                 -e "s|@SDK_SLUG@|${JETSON_VERSION_SLUG:-}|g" \
                 -e "s|@CUDA@|${cuda_version:-}|g" \
                 "$template")
  if [[ -n $out ]]; then
    install -m 0644 /dev/null "$out"
    printf '%s' "$rendered" > "$out"
  else
    printf '%s' "$rendered"
  fi
}

# ship_usage_guide <sdk_dir>
#
# Convenience wrapper: copies the rendered usage guide into <sdk_dir>/使用说明.md.
# Skips with a warning if the template is missing.
ship_usage_guide() {
  local sdk=$1
  local out="$sdk/使用说明.md"
  render_usage_guide_sdk --out "$out" \
    || warn 'Skipped shipping usage guide (template missing)'
}