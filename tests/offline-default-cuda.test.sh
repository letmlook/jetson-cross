#!/usr/bin/env bash
set -euo pipefail

# A valid L4T release without a CUDA argument must get past argument parsing.
# Stub uname so this remains deterministic on any real host architecture or
# Ubuntu release and stops before performing privileged/network operations.
output=$(mktemp)
fakebin=$(mktemp -d)
trap 'rm -f "$output"; rm -rf "$fakebin"' EXIT
printf '#!/bin/sh\nprintf "%%s\\n" aarch64\n' > "$fakebin/uname"
chmod +x "$fakebin/uname"

set +e
PATH="$fakebin:$PATH" bash ./setup-jetson-cross-sdk-offline.sh 36.4.4 >"$output" 2>&1
status=$?
set -e

[[ $status -eq 1 ]]
grep -qx 'An x86_64 host is required' "$output"
