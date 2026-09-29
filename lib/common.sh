# shellcheck shell=bash
# Common logging, error reporting, and small helpers used by every module.
# All other lib/*.sh files source this. Do not depend on anything except bash
# builtins and the path conventions exposed here.

# Set strict mode if the caller hasn't already.
set -Eeuo pipefail

# JETSON_CROSS_LIB_DIR is the directory this file lives in. Each module sets
# it before sourcing common.sh so relatives resolve correctly.
: "${JETSON_CROSS_LIB_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# JETSON_CROSS_REPO_ROOT is the absolute path to the repository root,
# computed once from the lib directory. May be overridden by the caller.
: "${JETSON_CROSS_REPO_ROOT:=$(cd "$JETSON_CROSS_LIB_DIR/.." && pwd)}"

# Convenience for modules that need the repo root (e.g. dockerfile paths).
repo_root() { printf '%s' "$JETSON_CROSS_REPO_ROOT"; }

# Standard log/die. log writes to stdout; die writes to stderr.
log() { printf '\n==> %s\n' "$*"; }

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

warn() { printf 'WARNING: %s\n' "$*" >&2; }

# Install an ERR trap that prints the failing line number and the SDK path
# when one is in scope. Re-armable: subsequent calls overwrite the previous
# trap.
install_err_trap() {
  local sdk_label=${1:-SDK}
  trap 'printf "Failed at line %s. %s path: %s\n" "$LINENO" "'"$sdk_label"'" "${SDK:-${sdk_dir:-unset}}" >&2' ERR
}

# Disable the ERR trap (e.g. before a known EXIT-time cleanup).
clear_err_trap() { trap - ERR; }

# Replace a token @TOKEN@ in a file with a value. Used by the heredoc-based
# template renderers in lib/sdk-skeleton.sh and lib/docs.sh.
#
# Usage: render_template FILE TOKEN VALUE [TOKEN VALUE ...]
render_template() {
  local file=$1; shift
  local sed_args=()
  while (( $# >= 2 )); do
    # Escape /, &, and \ in the replacement so sed never misinterprets it.
    local token=$1 value=$2
    value=${value//\\/\\\\}
    value=${value//\//\\/}
    value=${value//&/\&}
    sed_args+=(-e "s|@${token}@|${value}|g")
    shift 2
  done
  sed -i "${sed_args[@]}" "$file"
}

# Resolve a path to an absolute one. If already absolute, normalise; if
# relative, anchor against $PWD. Empty input is left empty.
abs_path() {
  local p=$1
  [[ -z $p ]] && { printf '%s' ""; return; }
  [[ $p = /* ]] || p=$PWD/$p
  printf '%s' "$p"
}

# Run a command, but only print it when $JETSON_CROSS_DEBUG is set.
run() {
  if [[ -n ${JETSON_CROSS_DEBUG:-} ]]; then printf '+ %s\n' "$*" >&2; fi
  "$@"
}

# Wait for stdin once. Convenience for tests.
confirm() {
  local ans
  read -r -p "$1 [y/N] " ans
  [[ ${ans,,} == y ]]
}