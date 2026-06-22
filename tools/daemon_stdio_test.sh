#!/usr/bin/env bash
set -euo pipefail

bin="$1"
fixture="${2:-}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
assert_py="$script_dir/daemon_stdio_assert.py"

if [[ "$fixture" == "--scenario" ]]; then
  fixture="--fixture"
fi

assert_output() {
  local mode="$1" output="$2"
  printf '%s\n' "$output" | "$assert_py" "$mode"
}

usage() {
  printf 'usage: %s <daemon-bin> [--fixture stale-target|duplicate-target|missing-target|lifecycle-contract|active-rollback|stop-cleanup|incident-drill|lost-stream|timeout|failed-live-rollback|failed-live-cleanup|failed-rollback-replay|failed-cleanup-replay|journal-replay]\n' "$0" >&2
}

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
      output="$(printf '%s\n' \
        '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"live-target-2","run_id":"run-target-2","target_id":"target-duplicate","rollback_id":"RB-target-2"}' |
        "$bin" --foreground --state-dir "$state_dir")"
      printf '%s\n' "$output"
      assert_output duplicate-target "$output"
      rm -rf "$state_dir"
      exit 0
      ;;
    missing-target)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-missing-target-fixture"
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
      output="$(printf '%s\n' \
        '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"live-missing-target","run_id":"run-missing-target","rollback_id":"RB-missing-target"}' |
        "$bin" --foreground --state-dir "$state_dir")"
      printf '%s\n' "$output"
      assert_output missing-target "$output"
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
    active-rollback)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-active-rollback-fixture"
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
      printf '%s\n' \
        '{"schema":"zig-scheduler/daemon-event/v1","seq":1,"event":"lab_run_active","action":"run_lab_microvm_live","action_id":"live-rollback-1","target_id":"target-rollback","rollback_id":"RB-rollback-1","artifact":"evidence/lab/fixture","state":"partial_switch_lab","status":"active","host_mutation":false}' \
        > "$state_dir/events.jsonl"
      output="$(printf '%s\n' \
        '{"schema":"zig-scheduler/operator-action/v1","action":"rollback_lab_run","action_id":"rb-live-rollback-1","run_id":"rollback-active-fixture","target_action_id":"live-rollback-1","rollback_id":"RB-rollback-1"}' |
        "$bin" --foreground --state-dir "$state_dir")"
      printf '%s\n' "$output"
      assert_output active-rollback "$output"
      rm -rf "$state_dir" "evidence/lab/rollback-drill/rollback-active-fixture"
      exit 0
      ;;
    stop-cleanup)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-stop-cleanup-fixture"
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
      printf '%s\n' \
        '{"schema":"zig-scheduler/daemon-event/v1","seq":1,"event":"lab_run_active","action":"run_lab_microvm_live","action_id":"live-stop-1","target_id":"target-stop","rollback_id":"RB-stop-1","artifact":"evidence/lab/fixture","state":"partial_switch_lab","status":"active","host_mutation":false}' \
        > "$state_dir/events.jsonl"
      output="$(printf '%s\n%s\n' \
        '{"schema":"zig-scheduler/operator-action/v1","action":"stop_lab_run","action_id":"stop-live-1","target_action_id":"live-stop-1","rollback_id":"RB-stop-1"}' \
        '{"schema":"zig-scheduler/operator-action/v1","action":"stop_lab_run","action_id":"stop-live-2","target_action_id":"live-stop-1","rollback_id":"RB-stop-1"}' |
        "$bin" --foreground --state-dir "$state_dir")"
      printf '%s\n' "$output"
      assert_output stop-cleanup "$output"
      rm -rf "$state_dir"
      exit 0
      ;;
    incident-drill)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-incident-drill-fixture"
      rm -rf "$state_dir" "evidence/lab/incident-drill/incident-drill-fixture"
      mkdir -p "$state_dir"
      output="$(printf '%s\n' \
        '{"schema":"zig-scheduler/operator-action/v1","action":"incident_drill","action_id":"incident-drill-fixture","run_id":"incident-drill-fixture"}' |
        "$bin" --foreground --state-dir "$state_dir")"
      printf '%s\n' "$output"
      assert_output incident-drill "$output"
      rm -rf "$state_dir" "evidence/lab/incident-drill/incident-drill-fixture"
      exit 0
      ;;
    lost-stream|timeout)
      scenario="${3:-}"
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-$scenario-fixture"
      rm -rf "$state_dir" "evidence/lab/run-all/$scenario-fixture"
      mkdir -p "$state_dir"
      output="$(printf '%s\n' \
        "{\"schema\":\"zig-scheduler/operator-action/v1\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"act-$scenario\",\"run_id\":\"$scenario-fixture\",\"target_id\":\"target-$scenario\",\"audit_id\":\"AUD-20990101T000000Z-deadbee-abc123\",\"rollback_id\":\"RB-$scenario\"}" |
        ZIG_SCHEDULER_MICROVM_LIFECYCLE_FIXTURE="$scenario" "$bin" --foreground --state-dir "$state_dir")"
      printf '%s\n' "$output"
      assert_output "$scenario" "$output"
      rm -rf "$state_dir" "evidence/lab/run-all/$scenario-fixture"
      exit 0
      ;;
    failed-live-rollback|failed-live-cleanup)
      scenario="${3#failed-live-}"
      mode="${3:-}"
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-$mode-fixture"
      run_id="$mode-fixture"
      target="target-$mode"
      rm -rf "$state_dir" "evidence/lab/run-all/$run_id"
      mkdir -p "$state_dir"
      output="$(printf '%s\n%s\n' \
        "{\"schema\":\"zig-scheduler/operator-action/v1\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-$mode-1\",\"run_id\":\"$run_id\",\"target_id\":\"$target\",\"audit_id\":\"AUD-20990101T000000Z-deadbee-abc123\",\"rollback_id\":\"RB-$mode-1\"}" \
        "{\"schema\":\"zig-scheduler/operator-action/v1\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-$mode-2\",\"run_id\":\"$mode-duplicate\",\"target_id\":\"$target\",\"audit_id\":\"AUD-20990101T000000Z-deadbee-abc123\",\"rollback_id\":\"RB-$mode-2\"}" |
        ZIG_SCHEDULER_MICROVM_LIFECYCLE_FIXTURE="failed-$scenario" "$bin" --foreground --state-dir "$state_dir")"
      printf '%s\n' "$output"
      assert_output "$mode" "$output"
      rm -rf "$state_dir" "evidence/lab/run-all/$run_id" "evidence/lab/run-all/$mode-duplicate"
      exit 0
      ;;
    failed-rollback-replay)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-failed-rollback-replay-fixture"
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
      printf '%s\n%s\n' \
        '{"schema":"zig-scheduler/daemon-event/v1","seq":1,"event":"lab_run_active","action":"run_lab_microvm_live","action_id":"live-failed-rb-1","target_id":"target-failed-rb","rollback_id":"RB-failed-rb-1","artifact":"evidence/lab/fixture","state":"partial_switch_lab","status":"active","host_mutation":false}' \
        '{"schema":"zig-scheduler/daemon-event/v1","seq":2,"event":"rollback","action":"run_lab_microvm_live","action_id":"live-failed-rb-1","target_id":"target-failed-rb","rollback_id":"RB-failed-rb-1","artifact":"evidence/lab/fixture/audit-ledger.jsonl","state":"incident","status":"FAIL","host_mutation":false}' \
        > "$state_dir/events.jsonl"
      output="$(printf '%s\n' \
        '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"live-failed-rb-2","run_id":"run-failed-rb-2","target_id":"target-failed-rb","rollback_id":"RB-failed-rb-2"}' |
        "$bin" --foreground --state-dir "$state_dir")"
      printf '%s\n' "$output"
      assert_output failed-rollback-replay "$output"
      rm -rf "$state_dir"
      exit 0
      ;;
    failed-cleanup-replay)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-failed-cleanup-replay-fixture"
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
      printf '%s\n%s\n' \
        '{"schema":"zig-scheduler/daemon-event/v1","seq":1,"event":"lab_run_active","action":"run_lab_microvm_live","action_id":"live-failed-clean-1","target_id":"target-failed-clean","rollback_id":"RB-failed-clean-1","artifact":"evidence/lab/fixture","state":"partial_switch_lab","status":"active","host_mutation":false}' \
        '{"schema":"zig-scheduler/daemon-event/v1","seq":2,"event":"cleanup","action":"stop_lab_run","action_id":"stop-failed-clean-1","target_action_id":"live-failed-clean-1","target_id":"","rollback_id":"RB-failed-clean-1","artifact":"evidence/lab/fixture/summary.json","state":"incident","status":"FAIL","host_mutation":false}' \
        > "$state_dir/events.jsonl"
      output="$(printf '%s\n' \
        '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"live-failed-clean-2","run_id":"run-failed-clean-2","target_id":"target-failed-clean","rollback_id":"RB-failed-clean-2"}' |
        "$bin" --foreground --state-dir "$state_dir")"
      printf '%s\n' "$output"
      assert_output failed-cleanup-replay "$output"
      rm -rf "$state_dir"
      exit 0
      ;;
    journal-replay)
      state_dir=".zig-cache/tmp/zig-scheduler-daemon-journal-replay-fixture"
      rm -rf "$state_dir"
      mkdir -p "$state_dir"
      printf '%s\n%s\n%s\n' \
        '{"schema":"zig-scheduler/daemon-event/v1","seq":1,"event":"lab_run_active","action":"run_lab_microvm_live","action_id":"live-replay-1","target_id":"target-replay","rollback_id":"RB-replay-1","artifact":"evidence/lab/replay","state":"partial_switch_lab","status":"active","host_mutation":false}' \
        '{"schema":"zig-scheduler/daemon-event/v1","seq":2,"event":"rollback","action":"run_lab_microvm_live","action_id":"live-replay-1","target_id":"target-replay","rollback_id":"RB-replay-1","artifact":"evidence/lab/replay/audit-ledger.jsonl","state":"rolled_back","status":"PASS","host_mutation":false}' \
        '{"schema":"zig-scheduler/daemon-event/v1","seq":3,"event":"cleanup","action":"run_lab_microvm_live","action_id":"live-replay-1","target_id":"target-replay","rollback_id":"RB-replay-1","artifact":"evidence/lab/replay/summary.json","state":"clean","status":"PASS","host_mutation":false}' \
        > "$state_dir/events.jsonl"
      output="$("$bin" --foreground --state-dir "$state_dir" < /dev/null)"
      printf '%s\n' "$output"
      assert_output journal-replay "$output"
      rm -rf "$state_dir"
      exit 0
      ;;
    *) usage; exit 2 ;;
  esac
fi

if [[ -n "$fixture" ]]; then
  usage
  exit 2
fi

state_dir=".zig-cache/tmp/zig-scheduler-daemon-stdio-test"
rm -rf "$state_dir"
mkdir -p "$(dirname "$state_dir")"
output="$(printf '%s\n%s\n' '{"action":"preflight"}' '{not-json' | "$bin" --foreground --state-dir "$state_dir")"
printf '%s\n' "$output"
case "$output" in *'"event":"state_changed"'*'"status":"ready"'*) ;; *) printf 'FAIL: daemon did not emit ready state\n' >&2; exit 1 ;; esac
case "$output" in *'"action":"preflight"'*'"status":"completed"'*) ;; *) printf 'FAIL: daemon did not process preflight action\n' >&2; exit 1 ;; esac
assert_output malformed-default "$output"
cmp <(printf '%s\n' "$output") "$state_dir/events.jsonl" >/dev/null
rm -rf "$state_dir"
printf 'PASS: foreground daemon stdio action loop is fail-closed\n'

limit_dir=".zig-cache/tmp/zig-scheduler-daemon-limit-test"
rm -rf "$limit_dir"
limit_output="$(for _ in $(seq 1 140); do printf '%s\n' '{"action":"preflight"}'; done | "$bin" --foreground --state-dir "$limit_dir")"
case "$limit_output" in *'journal_limit_exceeded'*) ;; *) printf 'FAIL: daemon did not refuse over event-count limit\n' >&2; exit 1 ;; esac
cmp <(printf '%s\n' "$limit_output") "$limit_dir/events.jsonl" >/dev/null
rm -rf "$limit_dir"
printf 'PASS: foreground daemon journal limit is bounded\n'

lifecycle_output="$($0 "$bin" --fixture lifecycle-contract)"
printf '%s\n' "$lifecycle_output"
assert_output lifecycle-success "$lifecycle_output"
printf 'PASS: foreground daemon consumes incremental VM lifecycle stream\n'
