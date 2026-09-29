# shellcheck shell=bash
# Build and execute docker run invocations. Centralizes the proxy flag
# plumbing so every caller passes a small number of intent parameters.

# proxy_run_args
#
# Echoes -e VAR=value pairs that should be appended to `docker run` so
# the proxy settings propagate. Empty when no proxy is configured.
proxy_run_args() {
  local -a args=()
  [[ -n ${DOCKER_HTTP_PROXY:-}  ]] && args+=(-e "HTTP_PROXY=$DOCKER_HTTP_PROXY" -e "http_proxy=$DOCKER_HTTP_PROXY")
  [[ -n ${DOCKER_HTTPS_PROXY:-} ]] && args+=(-e "HTTPS_PROXY=$DOCKER_HTTPS_PROXY" -e "https_proxy=$DOCKER_HTTPS_PROXY")
  [[ -n ${DOCKER_NO_PROXY:-}    ]] && args+=(-e "NO_PROXY=$DOCKER_NO_PROXY" -e "no_proxy=$DOCKER_NO_PROXY")
  printf '%s\n' "${args[@]}"
}

# docker_run_priv [<extra_args>...] -- <image> <cmd>...
#
# Runs a privileged container (used only during the initial SDK init,
# where chroot + mount + binfmt setup need root inside the container).
docker_run_priv() {
  docker run --rm --platform linux/arm64 --privileged "$@" </dev/null
}

# docker_run_unpriv [<extra_args>...] -- <image> <cmd>...
#
# Runs an unprivileged container (used for shell, run, archive, restore).
docker_run_unpriv() {
  docker run --rm --platform linux/arm64 "$@" </dev/null
}

# docker_run_it [<extra_args>...] -- <image> [<cmd>...]
#
# Same as docker_run_unpriv but with -it for interactive shells.
docker_run_it() {
  docker run --rm -it --platform linux/arm64 "$@" </dev/null
}