#!/usr/bin/env bash
set -euo pipefail

# A valid L4T release without a CUDA argument must get past argument parsing.
output=$(mktemp)
trap 'rm -f "$output"' EXIT

set +e
bash ./setup-jetson-cross-sdk-offline.sh 36.4.4 >"$output" 2>&1
status=$?
set -e

[[ $status -eq 1 ]]
grep -qx 'An x86_64 host is required' "$output"
