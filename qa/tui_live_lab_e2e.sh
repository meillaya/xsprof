#!/usr/bin/env bash
# SIZE_OK: single shell command gate; PTY setup, daemon launch, and evidence assertions are intentionally serialized in one bash entrypoint to preserve the stable CI command surface and shell-portable cleanup traps.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

out_dir=""
mode=""
live_bundle_arg=""
live_bundle_env="${ZIG_SCHEDULER_LIVE_BEHAVIOR_BUNDLE:-}"
keys="mbbq"
width="120"
height="30"
timeout_seconds="900"
self_test=false
self_test_summary=".omo/evidence/task-T26-failure-summary.json"
self_test_daemon_bin=""
daemon_bin="./zig-out/bin/zig-scheduler-daemon"
legacy_daemon_env="${ZIG_SCHEDULER_TUI_LIVE_DAEMON_BIN:-}"
self_test_daemon_env="${ZIG_SCHEDULER_TUI_LIVE_SELF_TEST_DAEMON_BIN:-}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
refuse() { printf 'REFUSE: %s\n' "$*" >&2; exit 2; }
usage() {
  cat >&2 <<'EOF'
usage: qa/tui_live_lab_e2e.sh --out evidence/lab/tui-e2e/<run-id> --mode launch-live-vm [--keys mq]
       qa/tui_live_lab_e2e.sh --out evidence/lab/tui-e2e/<run-id> --mode validate-existing-bundle --live-bundle evidence/lab/run-all/<vm-live>/summary.json
       qa/tui_live_lab_e2e.sh --self-test [--summary .omo/evidence/task-T26-failure-summary.json]

Modes:
  launch-live-vm           strict T20 proof: the TUI must launch/generate the fresh live microVM bundle; pre-existing bundle inputs are refused.
  validate-existing-bundle compatibility only: validates a supplied live behavior bundle and never counts as T20 launch proof.
  --self-test              run the T26 fail-closed failure-mode matrix with local fixtures; never launches QEMU.

Self-test internals:
  self-test-launch-live-vm  T26 fixture-only mode; accepts --self-test-daemon-bin or ZIG_SCHEDULER_TUI_LIVE_SELF_TEST_DAEMON_BIN.
                            This mode is not valid T20/T25 live proof and normal launch-live-vm refuses daemon overrides.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --self-test) self_test=true; shift ;;
    --summary) [ "$#" -ge 2 ] || fail '--summary requires value'; self_test_summary="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail '--out requires value'; out_dir="$2"; shift 2 ;;
    --mode) [ "$#" -ge 2 ] || fail '--mode requires value'; mode="$2"; shift 2 ;;
    --live-bundle) [ "$#" -ge 2 ] || fail '--live-bundle requires value'; live_bundle_arg="$2"; shift 2 ;;
    --keys) [ "$#" -ge 2 ] || fail '--keys requires value'; keys="$2"; shift 2 ;;
    --width) [ "$#" -ge 2 ] || fail '--width requires value'; width="$2"; shift 2 ;;
    --height) [ "$#" -ge 2 ] || fail '--height requires value'; height="$2"; shift 2 ;;
    --timeout-seconds) [ "$#" -ge 2 ] || fail '--timeout-seconds requires value'; timeout_seconds="$2"; shift 2 ;;
    --self-test-daemon-bin) [ "$#" -ge 2 ] || fail '--self-test-daemon-bin requires value'; self_test_daemon_bin="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

if [ "$self_test" = true ]; then
  exec bash qa/tui_live_lab_failure_matrix.sh --summary "$self_test_summary"
fi

[ -n "$out_dir" ] || fail '--out is required'
[ -n "$mode" ] || fail '--mode is required; use launch-live-vm for T20 proof or validate-existing-bundle for compatibility'
case "$out_dir$mode$live_bundle_arg$live_bundle_env$keys$width$height$timeout_seconds$self_test_daemon_bin$legacy_daemon_env$self_test_daemon_env" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
case "$mode" in launch-live-vm|validate-existing-bundle|self-test-launch-live-vm) ;; *) fail "invalid mode: $mode" ;; esac
case "$keys" in *$'\n'*|*$'\r'*|*/*|*..*) fail 'unsafe keys argument' ;; esac
if [ -n "$legacy_daemon_env" ]; then
  refuse 'ZIG_SCHEDULER_TUI_LIVE_DAEMON_BIN is refused; launch-live-vm always uses ./zig-out/bin/zig-scheduler-daemon and T26 fixtures must use self-test-launch-live-vm'
fi
if [ -n "$self_test_daemon_env" ] && [ "$mode" != self-test-launch-live-vm ]; then
  refuse 'ZIG_SCHEDULER_TUI_LIVE_SELF_TEST_DAEMON_BIN is only allowed with --mode self-test-launch-live-vm'
fi
if [ -n "$self_test_daemon_bin" ] && [ "$mode" != self-test-launch-live-vm ]; then
  refuse '--self-test-daemon-bin is only allowed with --mode self-test-launch-live-vm'
fi
if [ "$mode" = self-test-launch-live-vm ]; then
  daemon_bin="${self_test_daemon_bin:-$self_test_daemon_env}"
  [ -n "$daemon_bin" ] || fail 'self-test-launch-live-vm requires --self-test-daemon-bin or ZIG_SCHEDULER_TUI_LIVE_SELF_TEST_DAEMON_BIN'
  case "$out_dir" in evidence/lab/tui-e2e/t26-self-test/*) ;; *) fail 'self-test-launch-live-vm output must stay under evidence/lab/tui-e2e/t26-self-test' ;; esac
  case "$daemon_bin" in evidence/lab/tui-e2e/t26-self-test/*|./evidence/lab/tui-e2e/t26-self-test/*) ;; *) fail 'self-test daemon must stay under evidence/lab/tui-e2e/t26-self-test' ;; esac
  [ -x "$daemon_bin" ] || fail 'self-test daemon is not executable'
fi

prepare_evidence_dir evidence/lab "$out_dir"
find "$out_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
mkdir -p .omo/evidence

transcript="$out_dir/tui-transcript.txt"
daemon_state="$out_dir/daemon-state"
daemon_events="$daemon_state/events.jsonl"
summary="$out_dir/summary.json"
pty_log="$out_dir/pty-driver.log"
live_behavior_log="$out_dir/live-behavior-check.txt"
freshness_log="$out_dir/live-bundle-freshness-check.txt"
mkdir -p "$daemon_state"

write_summary() {
  local status="$1" reason="$2" live_behavior="$3" freshness="$4" rolled_back="$5" generated_bundle="$6" driver_rc="$7"
  [ -e "$transcript" ] || : > "$transcript"
  [ -e "$pty_log" ] || : > "$pty_log"
  [ -e "$live_behavior_log" ] || printf '%s\n' "$live_behavior" > "$live_behavior_log"
  [ -e "$freshness_log" ] || printf '%s\n' "$freshness" > "$freshness_log"
  STATUS="$status" REASON="$reason" LIVE_BEHAVIOR="$live_behavior" FRESHNESS="$freshness" ROLLED_BACK="$rolled_back" \
  OUT_DIR="$out_dir" MODE="$mode" KEYS="$keys" TRANSCRIPT="$transcript" DAEMON_EVENTS="$daemon_events" GENERATED_BUNDLE="$generated_bundle" \
  SUPPLIED_BUNDLE="${live_bundle_arg:-$live_bundle_env}" SUMMARY="$summary" PTY_LOG="$pty_log" LIVE_BEHAVIOR_LOG="$live_behavior_log" FRESHNESS_LOG="$freshness_log" DRIVER_RC="$driver_rc" \
  python3 - <<'PY'
import json
import os

artifact_paths = [os.environ["TRANSCRIPT"], os.environ["SUMMARY"], os.environ["PTY_LOG"], os.environ["LIVE_BEHAVIOR_LOG"], os.environ["FRESHNESS_LOG"]]
if os.path.exists(os.environ["DAEMON_EVENTS"]):
    artifact_paths.append(os.environ["DAEMON_EVENTS"])
if os.environ["GENERATED_BUNDLE"]:
    artifact_paths.append(os.environ["GENERATED_BUNDLE"])
summary = {
    "schema": "zig-scheduler/tui-live-lab-e2e/v2",
    "mode": os.environ["MODE"],
    "status": os.environ["STATUS"],
    "reason": os.environ["REASON"],
    "host_mutation": False,
    "rolled_back": os.environ["ROLLED_BACK"] == "true",
    "live_behavior": os.environ["LIVE_BEHAVIOR"],
    "freshness": os.environ["FRESHNESS"],
    "keys": os.environ["KEYS"],
    "tui_transcript": os.environ["TRANSCRIPT"],
    "daemon_events": os.environ["DAEMON_EVENTS"],
    "generated_live_bundle": os.environ["GENERATED_BUNDLE"],
    "supplied_live_bundle": os.environ["SUPPLIED_BUNDLE"],
    "pty_driver_log": os.environ["PTY_LOG"],
    "live_behavior_log": os.environ["LIVE_BEHAVIOR_LOG"],
    "freshness_log": os.environ["FRESHNESS_LOG"],
    "driver_rc": int(os.environ["DRIVER_RC"]),
    "artifact_paths": artifact_paths,
}
with open(os.environ["SUMMARY"], "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

extract_generated_bundle() {
  [ -s "$daemon_events" ] || return 1
  python3 - "$daemon_events" <<'PY'
from __future__ import annotations
import json
import sys
from pathlib import Path

found = ""
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    event = json.loads(line)
    if event.get("host_mutation") is not False:
        raise SystemExit(2)
    if event.get("action") != "run_lab_microvm_live":
        continue
    artifact = event.get("artifact")
    if isinstance(artifact, str) and artifact.endswith("/summary.json"):
        found = artifact
print(found)
raise SystemExit(0 if found else 1)
PY
}

rollback_observed() {
  [ -s "$daemon_events" ] || return 1
  python3 - "$daemon_events" <<'PY'
from __future__ import annotations
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    event = json.loads(line)
    if event.get("host_mutation") is not False:
        raise SystemExit(2)
    if event.get("event") == "rollback" and event.get("action") == "run_lab_microvm_live" and event.get("status") == "PASS":
        raise SystemExit(0)
    if event.get("event") == "rollback_completed" and event.get("status") in {"PASS", "already_rolled_back"}:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

terminal_refusal_reason() {
  [ -s "$daemon_events" ] || return 1
  python3 - "$daemon_events" <<'PY'
from __future__ import annotations
import json
import sys
from pathlib import Path

reason = ""
status = ""
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    event = json.loads(line)
    if event.get("host_mutation") is not False:
        print("unsafe_host_mutation_event")
        raise SystemExit(0)
    if event.get("action") == "run_lab_microvm_live" and event.get("status") in {"REFUSE", "SKIP"}:
        status = str(event.get("status"))
        reason = str(event.get("reason") or "runner_refused")
if status:
    print(f"{status} {reason}")
    raise SystemExit(0)
raise SystemExit(1)
PY
}

assert_transcript_visible_live_state() {
  [ -s "$transcript" ] || return 1
  python3 - "$transcript" "$generated_bundle" <<'PY'
from __future__ import annotations
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
text = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", text)
bundle = sys.argv[2]
bundle_dir = str(Path(bundle).parent)
needles = [
    "lab-only vm guest",
    "runtime samples accepted",
    "ops recorded",
    "zigsched_minimal",
    "rollback ready/completed",
    "cleanup receipt PASS",
    "live bundle freshness accepted",
    "not release eligible",
]
missing = [needle for needle in needles if needle not in text]
if bundle_dir not in text and Path(bundle_dir).name not in text:
    missing.append(bundle_dir)
for stale in ("runtime_sample │ not-started", "ops │ not-attached", "bundle │ none"):
    if stale in text:
        missing.append(f"stale:{stale}")
if missing:
    print("missing transcript live state: " + ", ".join(missing))
    raise SystemExit(1)
print("PASS: transcript-visible live VM state includes daemon-derived bundle/runtime/rollback/cleanup/validation fields")
PY
}

run_compatibility_mode() {
  local supplied="${live_bundle_arg:-$live_bundle_env}"
  [ -n "$supplied" ] || { printf 'REFUSE: --live-bundle or ZIG_SCHEDULER_LIVE_BEHAVIOR_BUNDLE required in validate-existing-bundle mode host_mutation=false\n' | tee "$live_behavior_log"; write_summary REFUSE 'compatibility bundle missing' MISSING NOT_RUN false "" 0; exit 2; }
  if python3 qa/live_behavior_check.py --bundle "$supplied" > "$live_behavior_log" 2>&1; then
    write_summary PASS 'compatibility mode validated supplied bundle; not T20 launch proof' PASS NOT_RUN true "$supplied" 0
    printf 'COMPATIBILITY COMPLETE rolled_back=true live_behavior=PASS t20_proof=false summary=%s\n' "$summary"
    exit 0
  fi
  write_summary FAIL 'compatibility bundle rejected' FAIL NOT_RUN false "$supplied" 0
  printf 'FAIL: compatibility bundle rejected host_mutation=false summary=%s\n' "$summary" >&2
  exit 1
}

if [ "$mode" = validate-existing-bundle ]; then
  run_compatibility_mode
fi

if [ "$mode" = self-test-launch-live-vm ]; then
  live_bundle_env=""
fi

if [ -n "$live_bundle_arg" ] || [ -n "$live_bundle_env" ]; then
  printf 'REFUSE: launch-live-vm mode rejects pre-existing live bundles as completion proof host_mutation=false\n' | tee "$live_behavior_log"
  write_summary REFUSE 'pre-existing bundle refused in strict launch-live-vm mode' REFUSED NOT_RUN false "" 0
  printf 'REFUSE: TUI e2e incomplete host_mutation=false rolled_back=false live_behavior=REFUSED summary=%s\n' "$summary"
  exit 2
fi

zig build install > "$out_dir/zig-build-install.txt" 2>&1
set +e
python3 tools/tui_live_vm_pty_test.py \
  --tui ./zig-out/bin/zig-scheduler-tui \
  --daemon "$daemon_bin" \
  --state-dir "$daemon_state" \
  --transcript "$transcript" \
  --keys "$keys" \
  --width "$width" \
  --height "$height" \
  --timeout-seconds "$timeout_seconds" \
  > "$pty_log" 2>&1
pty_rc=$?
set -e

if [ "$pty_rc" -ne 0 ]; then
  write_summary REFUSE 'TUI PTY driver failed or timed out' MISSING NOT_RUN false "" "$pty_rc"
  printf 'REFUSE: TUI e2e driver failed host_mutation=false summary=%s\n' "$summary"
  exit 2
fi

if [ ! -s "$daemon_events" ]; then
  write_summary REFUSE 'missing daemon events' MISSING NOT_RUN false "" "$pty_rc"
  printf 'REFUSE: missing daemon events host_mutation=false summary=%s\n' "$summary"
  exit 2
fi

if refusal="$(terminal_refusal_reason 2>/dev/null)"; then
  terminal_status="${refusal%% *}"
  printf '%s\n' "$refusal" > "$live_behavior_log"
  write_summary "$terminal_status" "$refusal" MISSING NOT_RUN false "" "$pty_rc"
  printf '%s: TUI e2e incomplete host_mutation=false rolled_back=false live_behavior=MISSING summary=%s\n' "$terminal_status" "$summary"
  exit 2
fi

generated_bundle="$(extract_generated_bundle 2>/dev/null || true)"
if [ -z "$generated_bundle" ] || [ ! -f "$generated_bundle" ]; then
  write_summary REFUSE 'TUI did not generate a live bundle summary' MISSING NOT_RUN false "$generated_bundle" "$pty_rc"
  printf 'REFUSE: TUI did not generate live bundle host_mutation=false summary=%s\n' "$summary"
  exit 2
fi

if ! assert_transcript_visible_live_state >> "$pty_log" 2>&1; then
  write_summary FAIL 'TUI transcript did not show daemon-derived live state' MISSING NOT_RUN false "$generated_bundle" "$pty_rc"
  printf 'FAIL: TUI transcript missing daemon-derived live state host_mutation=false summary=%s\n' "$summary" >&2
  exit 1
fi

rolled_back=false
if rollback_observed; then rolled_back=true; fi

live_behavior=FAIL
if python3 qa/live_behavior_check.py --bundle "$generated_bundle" > "$live_behavior_log" 2>&1; then
  live_behavior=PASS
fi
freshness=FAIL
if python3 qa/live_bundle_freshness_check.py --bundle "$generated_bundle" > "$freshness_log" 2>&1; then
  freshness=PASS
fi

if [ "$live_behavior" = PASS ] && [ "$freshness" = PASS ] && [ "$rolled_back" = true ]; then
  if [ "$mode" = self-test-launch-live-vm ]; then
    write_summary REFUSE 'self-test fixture mode cannot produce T20/T25 live proof' PASS PASS true "$generated_bundle" "$pty_rc"
    printf 'REFUSE: self-test fixture mode cannot produce live proof host_mutation=false summary=%s\n' "$summary"
    exit 2
  fi
  write_summary PASS 'TUI launched fresh live microVM bundle and validators passed' PASS PASS true "$generated_bundle" "$pty_rc"
  printf 'LAB RUN COMPLETE rolled_back=true live_behavior=PASS summary=%s\n' "$summary"
  exit 0
fi

status=FAIL
reason="live behavior, freshness, or rollback validation failed"
if grep -q 'current worktree is dirty\|bundle was generated from a dirty worktree' "$freshness_log" 2>/dev/null; then
  status=REFUSE
  reason="dirty_worktree_prevents_freshness_validation"
fi
write_summary "$status" "$reason" "$live_behavior" "$freshness" "$rolled_back" "$generated_bundle" "$pty_rc"
printf '%s: TUI e2e incomplete host_mutation=false rolled_back=%s live_behavior=%s freshness=%s summary=%s\n' "$status" "$rolled_back" "$live_behavior" "$freshness" "$summary"
if [ "$status" = REFUSE ]; then exit 2; fi
exit 1
