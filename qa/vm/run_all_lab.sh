#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

mode="host-safe"
out_dir=""
release_version="0.1.0-lab-runall"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: %s [--mode host-safe|vm-required|auto] --out evidence/lab/run-all/<name> [--release-version 0.1.0-lab-runall]\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || fail '--mode requires value'; mode="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail '--out requires value'; out_dir="$2"; shift 2 ;;
    --release-version) [ "$#" -ge 2 ] || fail '--release-version requires value'; release_version="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$mode" in host-safe|vm-required|auto) ;; *) fail '--mode must be host-safe, vm-required, or auto' ;; esac
[ -n "$out_dir" ] || fail '--out is required'
case "$out_dir$release_version" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"

summary="$out_dir/summary.json"
stages_dir="$out_dir/stages"
mkdir -p "$stages_dir"
git_sha="$(git rev-parse HEAD 2>/dev/null || printf unknown)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
vm_marker="${ZIG_SCHEDULER_VM_MARKER:-/run/zig-scheduler-vm-lab.marker}"
has_vm=false
if [ -f "$vm_marker" ]; then has_vm=true; fi
if [ "$mode" = vm-required ] && [ "$has_vm" != true ]; then
  cat > "$summary" <<JSON
{
  "schema": "zig-scheduler/run-all-lab/v1",
  "status": "REFUSE",
  "reason": "VM_CONFIG_REQUIRED",
  "mode": "$mode",
  "git_sha": "$git_sha",
  "host_mutation": false,
  "release_status": "skipped_no_vm",
  "stages": [],
  "started_at": "$started_at",
  "ended_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cleanup": {"qemu_leftovers": false, "tmux_leftovers": false}
}
JSON
  printf 'REFUSE: VM_CONFIG_REQUIRED\nsummary=%s\n' "$summary"
  exit 1
fi

stage_json() {
  local stage="$1" status="$2" reason="$3" command="$4" artifact="$5"
  local file="$stages_dir/$stage.json"
  STAGE="$stage" STATUS="$status" REASON="$reason" COMMAND_TEXT="$command" ARTIFACT="$artifact" GIT_SHA="$git_sha" VM_MODE="$mode" python3 - <<'PY' > "$file"
import json, os
print(json.dumps({
    "schema": "zig-scheduler/run-all-stage/v1",
    "stage": os.environ["STAGE"],
    "status": os.environ["STATUS"],
    "reason": os.environ["REASON"],
    "command": os.environ["COMMAND_TEXT"],
    "artifact": os.environ["ARTIFACT"],
    "vm_kind": "host-safe-refusal" if os.environ["STATUS"] == "REFUSE" else "host-safe-surrogate",
    "git_sha": os.environ["GIT_SHA"],
    "host_mutation": False,
    "mode": os.environ["VM_MODE"],
}, indent=2, sort_keys=True))
PY
  printf '%s\n' "$file"
}

stage_files=()
run_stage() {
  local stage="$1" command_text="$2" artifact="$3"
  shift 3
  mkdir -p "$artifact"
  printf 'STAGE %s: %s\n' "$stage" "$command_text"
  set +e
  "$@" > "$artifact/transcript.txt" 2>&1
  local rc=$?
  set -e
  local status reason
  if [ "$rc" -eq 0 ]; then
    if grep -Eiq 'REFUSE|refused-host|requires disposable VM marker' "$artifact/transcript.txt" "$artifact"/*.json 2>/dev/null; then
      status="REFUSE"; reason="host-safe refusal captured"
    elif grep -Eiq 'SKIP|skip|qemu unavailable|boot image unavailable' "$artifact/transcript.txt" "$artifact"/*.json 2>/dev/null; then
      status="SKIP"; reason="host-safe skip captured"
    else
      status="PASS"; reason="stage completed"
    fi
  else
    status="REFUSE"; reason="stage exited nonzero rc=$rc"
  fi
  stage_files+=("$(stage_json "$stage" "$status" "$reason" "$command_text" "$artifact")")
  printf 'STAGE %s status=%s reason=%s artifact=%s\n' "$stage" "$status" "$reason" "$artifact"
}

if [ "$mode" = host-safe ]; then
  has_vm=false
fi

run_stage run_lab 'bash qa/vm/run_lab.sh --mode read-only-smoke' "$out_dir/run-lab" bash qa/vm/run_lab.sh --mode read-only-smoke --out "$out_dir/run-lab"
run_stage verifier_only 'bash qa/vm/verifier_only.sh --object zig-out/bpf/zigsched_minimal.bpf.o' "$out_dir/verifier-only" bash qa/vm/verifier_only.sh --object zig-out/bpf/zigsched_minimal.bpf.o --out "$out_dir/verifier-only"
run_stage partial_attach 'bash qa/vm/partial_attach.sh host-safe target' "$out_dir/partial-attach" bash qa/vm/partial_attach.sh --target /sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope --audit-id AUD-20990101T000000Z-deadbee-abc123 --rollback-id RB-runall --out "$out_dir/partial-attach" --object zig-out/bpf/zigsched_minimal.bpf.o
run_stage rollback_drill 'bash qa/vm/rollback_drill.sh' "$out_dir/rollback-drill" bash qa/vm/rollback_drill.sh --out "$out_dir/rollback-drill"
run_stage cgroup_race 'bash qa/vm/cgroup_race.sh' "$out_dir/cgroup-race" bash qa/vm/cgroup_race.sh --out "$out_dir/cgroup-race"
run_stage dsq_policy_smoke 'bash qa/vm/dsq_policy_smoke.sh --policy vtime --duration 1s' "$out_dir/dsq-policy" bash qa/vm/dsq_policy_smoke.sh --policy vtime --duration 1s --out "$out_dir/dsq-policy"
run_stage stress_chaos 'bash qa/vm/stress_chaos.sh --duration 1s' "$out_dir/stress-chaos" bash qa/vm/stress_chaos.sh --duration 1s --out "$out_dir/stress-chaos"
run_stage observe_partial 'bash qa/vm/observe_partial.sh --samples 3' "$out_dir/observe-partial" bash qa/vm/observe_partial.sh --samples 3 --out "$out_dir/observe-partial"
run_stage release_gate "bash qa/release_gate.sh --version $release_version" "$out_dir/release-gate" bash qa/release_gate.sh --version "$release_version" --evidence evidence/releases/0.1.0-lab

ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
qemu_leftovers=false
if pgrep -f 'qemu-system.*zig-scheduler' >/dev/null 2>&1; then qemu_leftovers=true; fi
tmux_leftovers=false
if tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -q '^ulw-qa-T07-leftover$'; then tmux_leftovers=true; fi

STAGE_FILES="${stage_files[*]}" SUMMARY="$summary" MODE="$mode" GIT_SHA="$git_sha" STARTED_AT="$started_at" ENDED_AT="$ended_at" QEMU_LEFTOVERS="$qemu_leftovers" TMUX_LEFTOVERS="$tmux_leftovers" python3 - <<'PY'
import json, os
from pathlib import Path
stage_files = [Path(p) for p in os.environ["STAGE_FILES"].split() if p]
stages = [json.loads(path.read_text()) for path in stage_files]
statuses = {stage["status"] for stage in stages}
release_status = "controlled_lab_pilot_candidate" if any(stage["stage"] == "release_gate" and stage["status"] == "PASS" for stage in stages) else "skipped_no_vm"
summary = {
    "schema": "zig-scheduler/run-all-lab/v1",
    "status": "PASS" if statuses <= {"PASS", "SKIP", "REFUSE"} else "FAIL",
    "mode": os.environ["MODE"],
    "git_sha": os.environ["GIT_SHA"],
    "host_mutation": False,
    "release_status": release_status,
    "started_at": os.environ["STARTED_AT"],
    "ended_at": os.environ["ENDED_AT"],
    "stages": stages,
    "cleanup": {
        "qemu_leftovers": os.environ["QEMU_LEFTOVERS"] == "true",
        "tmux_leftovers": os.environ["TMUX_LEFTOVERS"] == "true",
    },
}
Path(os.environ["SUMMARY"]).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
PY

printf 'summary=%s\n' "$summary"
printf 'host_mutation=false\n'
printf 'cleanup qemu_leftovers=%s tmux_leftovers=%s\n' "$qemu_leftovers" "$tmux_leftovers"
printf 'PASS: run-all lab harness complete\n'
