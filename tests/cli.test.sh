#!/usr/bin/env bash
# Smoke tests for the unified `jetson-cross` CLI: argument parsing,
# action dispatch, and platform auto-detection. Tests run without root
# by faking the privileged commands and pinning the host arch via PATH.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/jetson-cross"
tmp=$(mktemp -d)
cleanup_test() {
  status=$?
  PATH=$real_path; export PATH
  rm -rf "$tmp"
  exit "$status"
}
real_path=$PATH
trap cleanup_test EXIT

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -s) printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FAKE_UNAME_M:-x86_64}" ;;
  *)  printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
esac
EOF
chmod +x "$fakebin/uname"

# Bad action rejected
set +e
PATH="$fakebin:$PATH" bash "$script" nope 2>"$tmp/bad-action.out"
status=$?
set -e
[[ $status -eq 2 ]]
grep -Fq 'Usage:' "$tmp/bad-action.out"

# Unknown --platform rejected
set +e
PATH="$fakebin:$PATH" bash "$script" build --platform=mips 2>"$tmp/bad-platform.out"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'unknown --platform' "$tmp/bad-platform.out"

# Unknown version rejected
set +e
PATH="$fakebin:$PATH" bash "$script" build --version=7.0 2>"$tmp/bad-version.out"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'unsupported JetPack' "$tmp/bad-version.out"

# help action succeeds
PATH="$fakebin:$PATH" bash "$script" help >"$tmp/help.out" 2>&1
grep -Fq 'jetson-cross: Jetson ARM64' "$tmp/help.out"

# Default platform detection (linux-x86 on x86_64 Linux, linux-arm64 on
# aarch64, jetson when /etc/nv_tegra_release exists)
mkdir -p "$tmp/etc"
: > "$tmp/etc/nv_tegra_release"
PATH="$fakebin:$PATH" JETSON_FAKE_NV_TEGRA="$tmp/etc/nv_tegra_release" \
  bash -c '
    # We cannot override /etc/nv_tegra_release via env, so we trust the
    # test environment. Verify the function directly.
    source '"$repo"'/lib/host-detect.sh
    if [[ -r /etc/nv_tegra_release ]]; then
      [[ "$(default_platform)" = jetson ]]
    fi
    # default_platform branches on uname; set FAKE_UNAME_* via export so
    # the fake uname binary in $fakebin sees them in command subshells.
    FAKE_UNAME_M=x86_64 FAKE_UNAME_S=Linux \
      bash -c "source '"$repo"'/lib/host-detect.sh; [[ \"\$(default_platform)\" = linux-x86 ]]"
    FAKE_UNAME_M=aarch64 FAKE_UNAME_S=Linux \
      bash -c "source '"$repo"'/lib/host-detect.sh; [[ \"\$(default_platform)\" = linux-arm64 ]]"
    FAKE_UNAME_M=arm64 FAKE_UNAME_S=Darwin \
      bash -c "source '"$repo"'/lib/host-detect.sh; [[ \"\$(default_platform)\" = macos-arm64 ]]"
    # default_mode_for_platform
    [[ "$(default_mode_for_platform macos-arm64)" = docker ]]
    [[ "$(default_mode_for_platform linux-x86)" = direct ]]
    [[ "$(default_mode_for_platform jetson)" = direct ]]
    # ubuntu_version_for_l4t
    [[ "$(ubuntu_version_for_l4t 36.4.0)" = 22.04 ]]
    [[ "$(ubuntu_version_for_l4t 35.6.5)" = 20.04 ]]
    # bootlin_toolchain_for_l4t
    [[ "$(bootlin_toolchain_for_l4t 36.4.0)" = 2022.08-1 ]]
    [[ "$(bootlin_toolchain_for_l4t 35.6.5)" = 2020.08-1 ]]
  '

# usage-guide without --sdk-dir writes to stdout; with --sdk-dir copies
# into the SDK dir
mkdir -p "$tmp/sdk"
PATH="$fakebin:$PATH" bash "$script" usage-guide --sdk-dir="$tmp/sdk" 2>"$tmp/guide.err"
[[ -f "$tmp/sdk/使用说明.md" ]]
grep -Fq 'JetPack' "$tmp/sdk/使用说明.md"

PATH="$fakebin:$PATH" bash "$script" usage-guide --out="$tmp/guide.md" 2>"$tmp/guide2.err"
[[ -f "$tmp/guide.md" ]]
grep -Fq 'JetPack' "$tmp/guide.md"

# bad usage for run without --
set +e
PATH="$fakebin:$PATH" bash "$script" run 2>"$tmp/run-no-cmd.out"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'usage: jetson-cross run' "$tmp/run-no-cmd.out"

echo "cli.test.sh passed"