#!/usr/bin/env bash

qemu_cleanup_pattern='(^|[[:space:]])(/[^[:space:]]*/)?qemu-system-x86_64([[:space:]]|$)'
qemu_cleanup_owned_marker='zig-scheduler-microvm-live-lab'

qemu_scan_processes() {
  local output_file="$1"
  {
    printf 'method=pgrep -af -- %s\n' "$qemu_cleanup_pattern"
    printf 'owned_marker=%s\n' "$qemu_cleanup_owned_marker"
    pgrep -af -- "$qemu_cleanup_pattern" 2>/dev/null || true
  } > "$output_file"
}

qemu_owned_leftovers() {
  local scan_file="$1"
  awk -v marker="$qemu_cleanup_owned_marker" 'index($0, marker) && $0 !~ /^owned_marker=/ { found=1 } END { exit(found ? 0 : 1) }' "$scan_file"
}
