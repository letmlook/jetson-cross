#!/usr/bin/env bash
set -euo pipefail

# The online setup accepts JetPack or L4T versions. With only TARGET and CUDA,
# it defaults to JetPack 6.1. Stop at an unsupported architecture before SSH.
repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/setup-jetson-cross-sdk.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/uname" <<'EOF'
#!/bin/sh
printf '%s\n' mips64
EOF
chmod +x "$tmp/uname"

for args in \
  'jetson 12.6' \
  'jetson 6.2.1 12.6' \
  'jetson 36.4.4 12.6'; do
  output="$tmp/${args// /-}.out"
  set +e
  PATH="$tmp:$PATH" bash "$script" $args >"$output" 2>&1
  status=$?
  set -e
  [[ $status -eq 1 ]]
  grep -qx 'x86_64 host required' "$output"
done

set +e
PATH="$tmp:$PATH" bash "$script" jetson 7.0 12.6 >"$tmp/invalid.out" 2>&1
status=$?
set -e
[[ $status -eq 2 ]]
grep -Fq 'Usage:' "$tmp/invalid.out"
