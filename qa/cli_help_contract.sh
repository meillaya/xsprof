#!/usr/bin/env bash
set -euo pipefail

root_help="$(zig build run -- --help)"
build_help="$(zig build --help)"
tui_live_help="$(zig build tui-live-vm -- --help)"

printf '%s\n' "$root_help" | grep -F 'zig build tui'
printf '%s\n' "$root_help" | grep -F 'zig build tui-live-vm'
printf '%s\n' "$root_help" | grep -F 'fail-closed'
printf '%s\n' "$root_help" | grep -F 'unsafe host mutation is refused'
printf '%s\n' "$build_help" | grep -F 'tui-live-vm'
printf '%s\n' "$build_help" | grep -F 'fail-closed'
printf '%s\n' "$tui_live_help" | grep -F 'zig build tui-live-vm'
printf '%s\n' "$tui_live_help" | grep -F 'zig-out/bin/zig-scheduler-tui --interactive --screen vm-lab'
printf '%s\n' "$tui_live_help" | grep -F 'does not attach sched_ext on the host'
printf '%s\n' "$tui_live_help" | grep -F 'QEMU/KVM'
