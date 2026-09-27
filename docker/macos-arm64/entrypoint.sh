#!/usr/bin/env bash
set -e

if [[ -f /opt/jetson-sdk/activate.sh ]]; then
  # shellcheck disable=SC1091
  source /opt/jetson-sdk/activate.sh
fi

exec "$@"
