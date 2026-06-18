#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

summary=".omo/evidence/task-T26-failure-summary.json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary) [ "$#" -ge 2 ] || { echo 'FAIL: --summary requires value' >&2; exit 1; }; summary="$2"; shift 2 ;;
    --help|-h) echo 'usage: qa/tui_live_lab_failure_matrix.sh [--summary .omo/evidence/task-T26-failure-summary.json]'; exit 0 ;;
    *) echo "FAIL: unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$summary" in .omo/evidence/*|evidence/lab/*) ;; *) echo 'FAIL: --summary must stay under .omo/evidence or evidence/lab' >&2; exit 1 ;; esac
case "$summary" in *$'\n'*|*$'\r'*|*'/../'*|../*|*/..) echo 'FAIL: unsafe summary path' >&2; exit 1 ;; esac

matrix_root="evidence/lab/tui-e2e/t26-self-test"
prepare_evidence_dir evidence/lab "$matrix_root"
find "$matrix_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
mkdir -p "$(dirname "$summary")"
results_jsonl="$matrix_root/results.jsonl"
: > "$results_jsonl"

zig build install > "$matrix_root/zig-build-install.txt" 2>&1

fake_daemon="$matrix_root/tui_live_lab_e2e_fake_daemon.sh"
cat > "$fake_daemon" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
behavior="${T26_FAKE_DAEMON_BEHAVIOR:-qemu_refuse}"
state_dir=".omo/evidence/t26-fake-daemon-state"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state-dir) state_dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$state_dir"
cat >/dev/null || true
emit() {
  local text="$1"
  printf '%s' "$text"
  printf '%s' "$text" > "$state_dir/events.jsonl"
}
event_line() {
  local seq="$1" event="$2" status="$3" reason="$4"
  printf '{"schema":"zig-scheduler/daemon-event/v1","seq":%s,"event":"%s","action":"run_lab_microvm_live","state":"vm_live_fixture","status":"%s","reason":"%s","artifact":"","host_mutation":false}\n' "$seq" "$event" "$status" "$reason"
}
case "$behavior" in
  hung_stream)
    event_line 1 stage_started active fixture_hung_stream | tee "$state_dir/events.jsonl"
    sleep 30
    ;;
  malformed_event)
    emit $'{not-json\n'
    ;;
  daemon_crash_after_active)
    event_line 1 stage_started active fixture_active_then_crash | tee "$state_dir/events.jsonl"
    exit 42
    ;;
  zero_exit_incomplete)
    event_line 1 stage_started active fixture_zero_exit_incomplete | tee "$state_dir/events.jsonl"
    exit 0
    ;;
  live_progression_no_bundle)
    {
      event_line 1 stage_started queued microvm_live_runner_start
      event_line 2 microvm_boot PASS "vm marker present"
      event_line 3 bpf_register PASS "runtime ops observed"
      event_line 4 runtime_sample PASS "runtime samples accepted"
      event_line 5 rollback PASS PASS
      event_line 6 cleanup PASS "process scan clean"
      event_line 7 validation PASS "live bundle freshness accepted"
    } | tee "$state_dir/events.jsonl"
    exit 0
    ;;
  qemu_refuse) status=REFUSE; reason=qemu_not_found ;;
  kvm_skip) status=SKIP; reason=kvm_unavailable ;;
  verifier_register_failure) status=REFUSE; reason=verifier_register_failed ;;
  lost_runtime_stream) status=REFUSE; reason=lost_runtime_stream ;;
  rollback_failure) status=REFUSE; reason="rollback drill failed" ;;
  cleanup_residue) status=REFUSE; reason="process scan dirty" ;;
  *) status=REFUSE; reason=unknown_fixture_failure ;;
esac
if [ "${status:-}" ]; then
  {
    event_line 1 stage_started active fixture_started
    event_line 2 stage_finished "$status" "$reason"
    event_line 3 cleanup PASS process_tmux_temp_cleanup_complete
  } | tee "$state_dir/events.jsonl"
fi
FAKE
chmod +x "$fake_daemon"

record_result() {
  local name="$1" class="$2" command_text="$3" rc="$4" output="$5" expected="$6"
  NAME="$name" CLASS="$class" COMMAND_TEXT="$command_text" RC="$rc" OUTPUT_PATH="$output" EXPECTED="$expected" RESULTS_JSONL="$results_jsonl" python3 - <<'PY'
import json
import os
import re
from pathlib import Path
name = os.environ['NAME']
text = Path(os.environ['OUTPUT_PATH']).read_text(encoding='utf-8', errors='replace')
plain = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', text)
expected = os.environ['EXPECTED']
rc = int(os.environ['RC'])
checks = []
passed = True
if '"host_mutation":true' in text or '"host_mutation": true' in text or 'host_mutation=true' in text:
    passed = False
    checks.append('host_mutation_true_seen')
if 'LAB RUN COMPLETE' in text:
    passed = False
    checks.append('false_lab_complete_seen')
if expected not in plain:
    passed = False
    checks.append(f'missing_expected:{expected}')
if expected.startswith('INCIDENT '):
    incident_at = plain.find(expected)
    if incident_at >= 0:
        suffix = plain[incident_at:]
        for forbidden in ('[SAFE] footer mode SAFE', 'live bundle freshness accepted', '\n│ NORMAL     ', '\n│ RUNNING     ', '\n│ ROLLBACK     ', '\n│ CLEANUP     '):
            if forbidden in suffix:
                passed = False
                checks.append(f'incident_overwritten_by_success:{forbidden}')
if name in {'missing_qemu','missing_kvm','stale_bundle','verifier_register_failure','forced_timeout','lost_runtime_stream','malformed_event','tui_quit_crash','rollback_failure','cleanup_residue','zero_exit_incomplete','live_progression_order'} and rc == 0:
    passed = False
    checks.append('failure_scenario_returned_zero')
if name == 'live_progression_order':
    ordered = ['[queued] VM run queued', '[booting]', '[attached]', '[observing]', '[rollback ready]', '[cleaned]']
    cursor = -1
    for marker in ordered:
        pos = plain.find(marker, cursor + 1)
        if pos == -1:
            passed = False
            checks.append(f'missing_ordered_marker:{marker}')
            break
        cursor = pos
if name in {'duplicate_action_id','stale_rollback_id'} and rc != 0:
    passed = False
    checks.append(f'daemon_matrix_rc:{rc}')
if not checks:
    checks.append('fail_closed_no_host_mutation_no_false_complete')
row = {
    'scenario': name,
    'adversarial_class': os.environ['CLASS'],
    'status': 'PASS' if passed else 'FAIL',
    'expected_marker': expected,
    'rc': rc,
    'command': os.environ['COMMAND_TEXT'],
    'output': os.environ['OUTPUT_PATH'],
    'checks': checks,
}
with open(os.environ['RESULTS_JSONL'], 'a', encoding='utf-8') as handle:
    handle.write(json.dumps(row, sort_keys=True) + '\n')
print(f"{row['status']}: {name} rc={rc} expected={expected}")
raise SystemExit(0 if passed else 1)
PY
}

run_fixture_scenario() {
  local name="$1" class="$2" behavior="$3" expected="$4" timeout_value="${5:-8}"
  local keys_value="${6:-mq}"
  local out="$matrix_root/$name" log="$matrix_root/$name/output.txt"
  mkdir -p "$out"
  local cmd="T26_FAKE_DAEMON_BEHAVIOR=$behavior bash qa/tui_live_lab_e2e.sh --out $out/run --mode self-test-launch-live-vm --self-test-daemon-bin $fake_daemon --timeout-seconds $timeout_value --keys $keys_value"
  set +e
  T26_FAKE_DAEMON_BEHAVIOR="$behavior" bash qa/tui_live_lab_e2e.sh --out "$out/run" --mode self-test-launch-live-vm --self-test-daemon-bin "$fake_daemon" --timeout-seconds "$timeout_value" --keys "$keys_value" > "$log" 2>&1
  local rc=$?
  set -e
  {
    printf '\n--- tui transcript ---\n'
    cat "$out/run/tui-transcript.txt" 2>/dev/null || true
    printf '\n--- pty driver ---\n'
    cat "$out/run/pty-driver.log" 2>/dev/null || true
  } >> "$log"
  record_result "$name" "$class" "$cmd" "$rc" "$log" "$expected"
}

run_fixture_scenario missing_qemu prerequisite_refusal qemu_refuse 'INCIDENT qemu_unavailable'
run_fixture_scenario missing_kvm prerequisite_refusal kvm_skip 'INCIDENT qemu_unavailable'
run_fixture_scenario verifier_register_failure verifier_fixture verifier_register_failure 'INCIDENT verifier_reject'
run_fixture_scenario lost_runtime_stream hung_commands lost_runtime_stream 'INCIDENT lost_stream'
run_fixture_scenario malformed_event malformed_input malformed_event 'INCIDENT malformed_line'
run_fixture_scenario forced_timeout hung_commands hung_stream 'INCIDENT timeout' 12 m
run_fixture_scenario zero_exit_incomplete lost_stream zero_exit_incomplete 'INCIDENT lost_stream' 8 m
run_fixture_scenario rollback_failure rollback_drill rollback_failure 'INCIDENT rollback_failure'
run_fixture_scenario cleanup_residue cleanup_scan cleanup_residue 'INCIDENT cleanup_residue'
run_fixture_scenario live_progression_order live_progression live_progression_no_bundle '[cleaned] cleanup receipt PASS'
run_fixture_scenario tui_quit_crash repeated_interruption daemon_crash_after_active 'TUI did not generate live bundle'

stale_dir="$matrix_root/stale_bundle"
mkdir -p "$stale_dir"
printf '%s\n' '{"schema":"zig-scheduler/run-all-lab/v1","status":"PASS","git_sha":"stale","git_dirty":true,"host_mutation":false}' > "$stale_dir/stale-summary.json"
stale_cmd="bash qa/tui_live_lab_e2e.sh --out $stale_dir/run --mode launch-live-vm --live-bundle $stale_dir/stale-summary.json"
set +e
bash qa/tui_live_lab_e2e.sh --out "$stale_dir/run" --mode launch-live-vm --live-bundle "$stale_dir/stale-summary.json" > "$stale_dir/output.txt" 2>&1
stale_rc=$?
set -e
record_result stale_bundle stale_state "$stale_cmd" "$stale_rc" "$stale_dir/output.txt" 'REFUSE: launch-live-vm mode rejects pre-existing live bundles'

duplicate_state="$matrix_root/daemon_matrix/duplicate/state"
mkdir -p "$duplicate_state"
duplicate_payload=$'{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"dup"}\n{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"dup"}\n'
duplicate_cmd="printf duplicate payload | ./zig-out/bin/zig-scheduler-daemon --foreground --state-dir $duplicate_state"
printf '%s' "$duplicate_payload" | ./zig-out/bin/zig-scheduler-daemon --foreground --state-dir "$duplicate_state" > "$matrix_root/daemon_matrix/duplicate/output.txt" 2>&1
record_result duplicate_action_id stale_state "$duplicate_cmd" "$?" "$matrix_root/daemon_matrix/duplicate/output.txt" duplicate_action_id

stale_state="$matrix_root/daemon_matrix/stale-rollback/state"
mkdir -p "$stale_state"
cat > "$stale_state/events.jsonl" <<'EOF'
{"schema":"zig-scheduler/daemon-event/v1","seq":1,"event":"journal_record","action":"run_lab_vm","action_id":"live-1","rollback_id":"RB-live-1","status":"accepted","host_mutation":false}
{"schema":"zig-scheduler/daemon-event/v1","seq":2,"event":"lab_run_active","action":"run_lab_vm","action_id":"live-1","rollback_id":"RB-live-1","artifact":"evidence/lab/run-all/live-1/summary.json","status":"active","host_mutation":false}
EOF
stale_payload=$'{"schema":"zig-scheduler/operator-action/v1","action":"rollback_lab_run","action_id":"rollback-stale","target_action_id":"live-1","rollback_id":"RB-wrong"}\n'
stale_cmd="printf stale rollback payload | ./zig-out/bin/zig-scheduler-daemon --foreground --state-dir $stale_state"
printf '%s' "$stale_payload" | ./zig-out/bin/zig-scheduler-daemon --foreground --state-dir "$stale_state" > "$matrix_root/daemon_matrix/stale-rollback/output.txt" 2>&1
record_result stale_rollback_id malformed_input "$stale_cmd" "$?" "$matrix_root/daemon_matrix/stale-rollback/output.txt" stale_rollback_id

python3 tools/tui_live_vm_cleanup.py --cleanup-owned-lab-tmpdirs > "$matrix_root/cleanup-owned-lab-tmpdirs.txt" 2>&1 || true
cleanup_log="$matrix_root/cleanup-scan.txt"
{
  printf 'qemu_scan:\n'
  ps -eo args= | grep '[q]emu-system-x86_64' | grep 'zig-scheduler-microvm-live-lab' || true
  printf 'tmux_scan:\n'
  if command -v tmux >/dev/null 2>&1; then tmux list-sessions 2>/dev/null | grep -E 'zig-scheduler-t26|tui-live-lab-e2e' || true; else printf 'tmux not installed\n'; fi
  printf 'temp_scan:\n'
  find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'zigsched-microvm-live.*' -print 2>/dev/null || true
} > "$cleanup_log"

CLEANUP_LOG="$cleanup_log" RESULTS_JSONL="$results_jsonl" SUMMARY="$summary" MATRIX_ROOT="$matrix_root" python3 - <<'PY'
import json
import os
from pathlib import Path
rows = [json.loads(line) for line in Path(os.environ['RESULTS_JSONL']).read_text(encoding='utf-8').splitlines() if line.strip()]
cleanup_lines = Path(os.environ['CLEANUP_LOG']).read_text(encoding='utf-8', errors='replace').splitlines()
hits = [line for line in cleanup_lines if line and not line.endswith(':') and line != 'tmux not installed']
cleanup_status = 'PASS' if not hits else 'FAIL'
summary = {
    'schema': 'zig-scheduler/t26-failure-matrix/v1',
    'status': 'PASS' if rows and all(row['status'] == 'PASS' for row in rows) and cleanup_status == 'PASS' else 'FAIL',
    'host_mutation': False,
    'false_lab_complete': False,
    'scenario_count': len(rows),
    'pass_count': sum(1 for row in rows if row['status'] == 'PASS'),
    'scenarios': rows,
    'cleanup': {'status': cleanup_status, 'log': os.environ['CLEANUP_LOG'], 'hits': hits},
    'matrix_root': os.environ['MATRIX_ROOT'],
}
Path(os.environ['SUMMARY']).write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n', encoding='utf-8')
print(json.dumps({'status': summary['status'], 'summary': os.environ['SUMMARY'], 'scenario_count': len(rows), 'cleanup': cleanup_status}, sort_keys=True))
raise SystemExit(0 if summary['status'] == 'PASS' else 1)
PY
