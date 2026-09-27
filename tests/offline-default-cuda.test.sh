#!/usr/bin/env bash
set -euo pipefail

# Version parsing must finish before host setup. Use an unsupported host
# architecture to stop deterministically before privileged/network work.
repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/setup-jetson-cross-sdk-offline.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/uname" <<'EOF'
#!/bin/sh
printf '%s\n' mips64
EOF
chmod +x "$tmp/uname"

for version in default 6.1 36.4.0 6.2.1 36.4.4; do
  output="$tmp/$version.out"
  args=()
  [[ $version = default ]] || args=("$version")
  set +e
  PATH="$tmp:$PATH" bash "$script" ${args[@]+"${args[@]}"} >"$output" 2>&1
  status=$?
  set -e
  [[ $status -eq 1 ]]
  grep -qx 'An x86_64 or aarch64 Linux host is required' "$output"
done

set +e
PATH="$tmp:$PATH" bash "$script" 7.0 >"$tmp/invalid.out" 2>&1
status=$?
set -e
[[ $status -eq 2 ]]
grep -Fq 'Usage:' "$tmp/invalid.out"

# With a supported ARM64 host, the no-argument form must actually select the
# JetPack 6.1/L4T 36.4.0 payload before any archive has been downloaded.
cat > "$tmp/uname" <<'EOF'
#!/bin/sh
printf '%s\n' aarch64
EOF
cat > "$tmp/apt-get" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$tmp/sudo" <<'EOF'
#!/bin/sh
exec env "$@"
EOF
cat > "$tmp/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_LOG"
exit 42
EOF
chmod +x "$tmp/uname" "$tmp/apt-get" "$tmp/sudo" "$tmp/curl"
cat > "$tmp/os-release" <<'EOF'
ID=ubuntu
VERSION_ID=22.04
VERSION_CODENAME=jammy
EOF
export CURL_LOG="$tmp/curl.log"
set +e
HOME="$tmp/home" PATH="$tmp:$PATH" JETSON_OS_RELEASE_FILE="$tmp/os-release" \
  bash "$script" >"$tmp/default-download.out" 2>&1
status=$?
set -e
[[ $status -eq 42 ]]
grep -Fq '/Jetson_Linux_r36.4.0_aarch64.tbz2' "$CURL_LOG"
