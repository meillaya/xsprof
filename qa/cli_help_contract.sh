#!/usr/bin/env bash
set -euo pipefail

root_help="$(zig build run -- --help)"
build_help="$(zig build --help)"

printf '%s\n' "$root_help" | grep -F 'zig build linux-preflight'
printf '%s\n' "$root_help" | grep -F 'zig build daemon'
printf '%s\n' "$root_help" | grep -F 'fail-closed'
printf '%s\n' "$root_help" | grep -F 'unsafe host mutation is refused'
printf '%s\n' "$build_help" | grep -F 'linux-preflight'
printf '%s\n' "$build_help" | grep -F 'daemon'
printf '%s\n' "$build_help" | grep -F 'package'
! printf '%s\n%s\n' "$root_help" "$build_help" | grep -E 'tui|TUI|webview|WebView|desktop' >/dev/null
