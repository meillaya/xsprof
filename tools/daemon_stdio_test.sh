#!/usr/bin/env bash
set -euo pipefail

bin="$1"
fixture="${2:-}"

if [[ "$fixture" == "--fixture" ]]; then
  case "${3:-}" in
    stale-target)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-stale-target-fixture"
      rm -rf "$state_dir"
      mkdir -p "$(dirname "$state_dir")"
      printf '%s\n' '{"schema":"zig-scheduler/operator-action/v1","action":"rollback_lab_run","action_id":"rb-stale-target","target_action_id":"missing-target","rollback_id":"RB-stale-target"}' |
        "$bin" --foreground --state-dir "$state_dir"
      rm -rf "$state_dir"
      exit 0
      ;;
    duplicate-target)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-duplicate-target-fixture"
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
      printf '%s\n' \
        '{"schema":"zig-scheduler/daemon-event/v1","seq":1,"event":"lab_run_active","action":"run_lab_microvm_live","action_id":"live-target-1","target_id":"target-duplicate","rollback_id":"RB-target-1","artifact":"evidence/lab/fixture","state":"partial_switch_lab","status":"active","host_mutation":false}' \
        > "$state_dir/events.jsonl"
      printf '%s\n' \
        '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"live-target-2","run_id":"run-target-2","target_id":"target-duplicate","rollback_id":"RB-target-2"}' |
        "$bin" --foreground --state-dir "$state_dir"
      rm -rf "$state_dir"
      exit 0
      ;;
    missing-target)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-missing-target-fixture"
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
      printf '%s\n' \
        '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"live-missing-target","run_id":"run-missing-target","rollback_id":"RB-missing-target"}' |
        "$bin" --foreground --state-dir "$state_dir"
      rm -rf "$state_dir"
      exit 0
      ;;
    lifecycle-contract)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-lifecycle-fixture"
      out=".zig-cache/tmp/zig-scheduler-daemon-lifecycle-output.jsonl"
      rm -rf "$state_dir" "$out"
      mkdir -p "$state_dir"
      token="lifecycle-$$"
      rm -rf "evidence/lab/run-all/$token"
      (
        printf '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"act-%s","run_id":"%s","target_id":"target-%s","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-%s"}\n' "$token" "$token" "$token" "$token" |
          ZIG_SCHEDULER_MICROVM_LIFECYCLE_FIXTURE=1 "$bin" --foreground --follow --state-dir "$state_dir" > "$out"
      ) &
      pid="$!"
      for _ in $(seq 1 30); do
        if grep -q '"event":"boot"' "$out" 2>/dev/null; then break; fi
        sleep 0.05
      done
      if ! grep -q '"event":"boot"' "$out" 2>/dev/null; then
        wait "$pid" || true
        cat "$out" >&2 || true
        rm -rf "$state_dir" "$out"
        printf 'FAIL: lifecycle fixture did not emit boot incrementally\n' >&2
        exit 1
      fi
      if ! kill -0 "$pid" 2>/dev/null; then
        cat "$out" >&2 || true
        rm -rf "$state_dir" "$out"
        printf 'FAIL: lifecycle fixture finished before boot could be observed incrementally\n' >&2
        exit 1
      fi
      wait "$pid"
      cat "$out"
      cmp "$out" "$state_dir/events.jsonl" >/dev/null
      rm -rf "$state_dir" "$out" "evidence/lab/run-all/$token"
      exit 0
      ;;
    *)
      printf 'usage: %s <daemon-bin> [--fixture stale-target|duplicate-target|missing-target|lifecycle-contract]\n' "$0" >&2
      exit 2
      ;;
  esac
fi

if [[ -n "$fixture" ]]; then
  printf 'usage: %s <daemon-bin> [--fixture stale-target|duplicate-target|missing-target|lifecycle-contract]\n' "$0" >&2
  exit 2
fi

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
