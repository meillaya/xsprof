#!/usr/bin/env bash
set -euo pipefail

bin="$1"
state_dir=".zig-cache/tmp/zig-scheduler-daemon-stdio-test"
rm -rf "$state_dir"
mkdir -p "$(dirname "$state_dir")"

output="$(printf '%s\n%s\n' '{"action":"preflight"}' '{not-json' | "$bin" --foreground --state-dir "$state_dir")"
printf '%s\n' "$output"

case "$output" in *'"event":"state_changed"'*'"status":"ready"'*) ;; *)
  printf 'FAIL: daemon did not emit ready state\n' >&2
  exit 1
  ;;
esac
case "$output" in *'"action":"preflight"'*'"status":"completed"'*) ;; *)
  printf 'FAIL: daemon did not process preflight action\n' >&2
  exit 1
  ;;
esac
case "$output" in *'malformed_action'*) ;; *)
  printf 'FAIL: daemon did not refuse malformed action\n' >&2
  exit 1
  ;;
esac
case "$output" in *'host_mutation":false'*) ;; *)
  printf 'FAIL: daemon output omitted host_mutation=false\n' >&2
  exit 1
  ;;
esac
cmp <(printf '%s\n' "$output") "$state_dir/events.jsonl" >/dev/null
rm -rf "$state_dir"
printf 'PASS: foreground daemon stdio action loop is fail-closed\n'


limit_dir=".zig-cache/tmp/zig-scheduler-daemon-limit-test"
rm -rf "$limit_dir"
limit_output="$(for _ in $(seq 1 140); do printf '%s\n' '{"action":"preflight"}'; done | "$bin" --foreground --state-dir "$limit_dir")"
case "$limit_output" in *'journal_limit_exceeded'*) ;; *)
  printf 'FAIL: daemon did not refuse over event-count limit\n' >&2
  exit 1
  ;;
esac
cmp <(printf '%s\n' "$limit_output") "$limit_dir/events.jsonl" >/dev/null
rm -rf "$limit_dir"
printf 'PASS: foreground daemon journal limit is bounded\n'
