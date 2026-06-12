#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

out_dir=""
live_bundle="${ZIG_SCHEDULER_LIVE_BEHAVIOR_BUNDLE:-}"
keys="rvmmbbpiq"
width="120"
height="30"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: %s --out evidence/lab/tui-e2e/<run-id> [--live-bundle evidence/lab/run-all/<vm-live>/summary.json] [--keys rvmmbbpiq]\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || fail '--out requires value'; out_dir="$2"; shift 2 ;;
    --live-bundle) [ "$#" -ge 2 ] || fail '--live-bundle requires value'; live_bundle="$2"; shift 2 ;;
    --keys) [ "$#" -ge 2 ] || fail '--keys requires value'; keys="$2"; shift 2 ;;
    --width) [ "$#" -ge 2 ] || fail '--width requires value'; width="$2"; shift 2 ;;
    --height) [ "$#" -ge 2 ] || fail '--height requires value'; height="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$out_dir" ] || fail '--out is required'
case "$out_dir$live_bundle$keys$width$height" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"
find "$out_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

transcript="$out_dir/tui-transcript.txt"
daemon_state="$out_dir/daemon-state"
daemon_events="$daemon_state/events.jsonl"
summary="$out_dir/summary.json"
mkdir -p "$daemon_state"

zig build install >/dev/null
printf '%sq' "$keys" | ./zig-out/bin/zig-scheduler-tui \
  --interactive --test-mode \
  --fixture fixtures/lab/preflight-ready.json \
  --screen sched-ext --width "$width" --height "$height" \
  --daemon-bin ./zig-out/bin/zig-scheduler-daemon \
  --daemon-state-dir "$daemon_state" \
  > "$transcript"

[ -s "$daemon_events" ] || fail "missing daemon events: $daemon_events"

status="REFUSE"
reason="VM-live behavior bundle required"
live_behavior="MISSING"
rolled_back="false"
if [ -n "$live_bundle" ]; then
  if python3 qa/live_behavior_check.py --bundle "$live_bundle" > "$out_dir/live-behavior-check.txt" 2>&1; then
    status="PASS"
    reason="TUI transcript plus validated VM-live behavior bundle"
    live_behavior="PASS"
  else
    status="FAIL"
    reason="VM-live behavior bundle rejected"
    live_behavior="FAIL"
  fi
else
  printf 'REFUSE: ZIG_SCHEDULER_LIVE_BEHAVIOR_BUNDLE or --live-bundle is required for T31 completion\n' > "$out_dir/live-behavior-check.txt"
fi

if grep -q 'rollback completed PASS\|rollback already_rolled_back' "$transcript" || grep -q '"action":"rollback_lab_run".*"status":"PASS"\|"status":"already_rolled_back"' "$daemon_events"; then
  rolled_back="true"
fi

STATUS="$status" REASON="$reason" LIVE_BEHAVIOR="$live_behavior" ROLLED_BACK="$rolled_back" OUT_DIR="$out_dir" TRANSCRIPT="$transcript" DAEMON_EVENTS="$daemon_events" LIVE_BUNDLE="$live_bundle" SUMMARY="$summary" python3 - <<'PY'
import json, os
summary = {
    "schema": "zig-scheduler/tui-live-lab-e2e/v1",
    "status": os.environ["STATUS"],
    "reason": os.environ["REASON"],
    "host_mutation": False,
    "rolled_back": os.environ["ROLLED_BACK"] == "true",
    "live_behavior": os.environ["LIVE_BEHAVIOR"],
    "tui_transcript": os.environ["TRANSCRIPT"],
    "daemon_events": os.environ["DAEMON_EVENTS"],
    "live_behavior_bundle": os.environ["LIVE_BUNDLE"],
    "artifact_paths": [os.environ["TRANSCRIPT"], os.environ["DAEMON_EVENTS"], os.environ["SUMMARY"]],
}
if os.environ["LIVE_BUNDLE"]:
    summary["artifact_paths"].append(os.environ["LIVE_BUNDLE"])
print(json.dumps(summary, indent=2, sort_keys=True), file=open(os.environ["SUMMARY"], "w"))
PY

if [ "$status" = PASS ] && [ "$rolled_back" = true ]; then
  printf 'LAB RUN COMPLETE rolled_back=true live_behavior=PASS summary=%s\n' "$summary"
  exit 0
fi
if [ "$status" = PASS ]; then
  printf 'FAIL: live behavior passed but rollback was not observed summary=%s\n' "$summary" >&2
  exit 1
fi
printf '%s: TUI e2e incomplete rolled_back=%s live_behavior=%s summary=%s\n' "$status" "$rolled_back" "$live_behavior" "$summary"
if [ "$status" = REFUSE ]; then exit 2; fi
exit 1
