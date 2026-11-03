#!/bin/sh
set -eu

t2d_root="$(cd "$(dirname "$0")/.." && pwd)"
t2d_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/t2d-runtime-config.XXXXXX")"
trap 'rm -rf "$t2d_check_dir"' EXIT
trap 'exit 1' HUP INT TERM

xcrun --sdk macosx swiftc \
  "$t2d_root/TalkToDrone/RuntimeConfig.swift" \
  "$t2d_root/tests/RuntimeConfigChecks.swift" \
  -o "$t2d_check_dir/runtime-config-checks"
"$t2d_check_dir/runtime-config-checks"
