#!/usr/bin/env bash

qemu_cleanup_pattern='(^|[[:space:]])(/[^[:space:]]*/)?qemu-system-x86_64([[:space:]]|$)'
qemu_cleanup_owned_marker='zig-scheduler-microvm-live-lab'

qemu_scan_processes() {
  local output_file="$1"
  {
    printf 'method=ps -eo pid=,comm=,args= filtered to qemu-system-x86_64 argv0 basename\n'
    ps -eo pid=,comm=,args= 2>/dev/null | awk '
      {
        args = $0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]*/, "", args)
        split(args, argv, /[[:space:]]+/)
        argv0 = argv[1]
        sub(/^.*\//, "", argv0)
        if (argv0 == "qemu-system-x86_64") {
          sub(/^[[:space:]]*/, "")
          print
        }
      }'
  } > "$output_file"
}

qemu_owned_leftovers() {
  local scan_file="$1"
  awk -v marker="$qemu_cleanup_owned_marker" 'index($0, marker) { found=1 } END { exit(found ? 0 : 1) }' "$scan_file"
}
