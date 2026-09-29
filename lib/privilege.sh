# shellcheck shell=bash
# Privilege abstraction. Many actions (apt-get install, mount, chroot) need
# root. Minimal Ubuntu containers run as root without installing sudo, so we
# provide a uniform `sudo` function that becomes a no-op when EUID==0 and
# otherwise shells out to the host's sudo.

# Initialise the sudo shim. Validates credentials upfront when sudo is
# needed so a password prompt (or its failure in a non-interactive shell)
# surfaces immediately, not minutes into the build.
#
# Usage: init_sudo
init_sudo() {
  if (( EUID == 0 )); then
    # The container's "root" has no password and no sudo binary; emulate it.
    sudo() { command env "$@"; }
  else
    command -v sudo >/dev/null || die 'sudo is required when not running as root'
    sudo true
  fi
}

# A second helper for callers that need to know upfront whether they are
# already root. Returns 0 if EUID==0, 1 otherwise. Useful in messages.
running_as_root() { (( EUID == 0 )); }