#!/usr/bin/env bash
set -euo pipefail

# JetPack 6.1 (L4T 36.4.0) must be accepted without requiring local archives.
# Stub uname so this remains deterministic on any real host architecture or
# Ubuntu release and stops before performing privileged/network operations.
output_jp61=$(mktemp)
fakebin_jp61=$(mktemp -d)
trap 'rm -f "$output_jp61"; rm -rf "$fakebin_jp61"' EXIT
printf '#!/bin/sh\nprintf "%%s\\n" aarch64\n' > "$fakebin_jp61/uname"
chmod +x "$fakebin_jp61/uname"

set +e
PATH="$fakebin_jp61:$PATH" bash ./setup-jetson-cross-sdk-offline.sh 36.4.0 >"$output_jp61" 2>&1
status_jp61=$?
set -e

[[ $status_jp61 -eq 1 ]]
grep -qx 'An x86_64 host is required' "$output_jp61"

# The no-archive path must select the JetPack 6.1 (R36.4.0) payloads.
grep -Fq 'Jetson_Linux_R36.4.0_aarch64.tbz2' ./setup-jetson-cross-sdk-offline.sh
grep -Fq 'Tegra_Linux_Sample-Root-Filesystem_r36.4.0_aarch64.tbz2' ./setup-jetson-cross-sdk-offline.sh
grep -Fq 'r36_release_v4.0/release' ./setup-jetson-cross-sdk-offline.sh

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
