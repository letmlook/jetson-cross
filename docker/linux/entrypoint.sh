#!/usr/bin/env bash
# Container entrypoint for the Linux Docker base image. Sources the
# finished SDK's activate.sh so any subsequent command runs with the
# cross-compile environment exported.
set -e

# The SDK may live at /opt/jetson-sdk (init flow) or any other mount
# point the caller bind-mounted. Look in the standard place first.
if [[ -f /opt/jetson-sdk/activate.sh ]]; then
  # shellcheck disable=SC1091
  source /opt/jetson-sdk/activate.sh
fi

exec "$@"