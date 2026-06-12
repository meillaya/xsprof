#!/usr/bin/env bash
set -euo pipefail
trusted_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH="$trusted_path"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

mode="host-safe"
out_dir=""
image_arg=""
kernel_arg=""
env_file=""
release_version="0.2.0-lab-runall"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: %s [--mode host-safe|vm-required|auto] --out evidence/lab/run-all/<name> [--image <path>] [--kernel <path>] [--env-file <file>] [--release-version 0.2.0-lab-runall]\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || fail '--mode requires value'; mode="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail '--out requires value'; out_dir="$2"; shift 2 ;;
    --image) [ "$#" -ge 2 ] || fail '--image requires value'; image_arg="$2"; shift 2 ;;
    --kernel) [ "$#" -ge 2 ] || fail '--kernel requires value'; kernel_arg="$2"; shift 2 ;;
    --env-file) [ "$#" -ge 2 ] || fail '--env-file requires value'; env_file="$2"; shift 2 ;;
    --release-version) [ "$#" -ge 2 ] || fail '--release-version requires value'; release_version="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$mode" in host-safe|vm-required|auto) ;; *) fail '--mode must be host-safe, vm-required, or auto' ;; esac
[ -n "$out_dir" ] || fail '--out is required'
case "$out_dir$release_version$image_arg$kernel_arg$env_file" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"
find "$out_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

summary="$out_dir/summary.json"
stages_dir="$out_dir/stages"
mkdir -p "$stages_dir"
git_sha="$(git rev-parse HEAD 2>/dev/null || printf unknown)"
kernel_release="$(uname -r 2>/dev/null || printf unknown)"
kernel_arch="$(uname -m 2>/dev/null || printf unknown)"
kernel_config_sha256="unavailable-host-safe"
if [ -r "/boot/config-$kernel_release" ]; then
  kernel_config_sha256="$(sha256sum "/boot/config-$kernel_release" | awk '{print $1}')"
fi
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
vm_marker="/run/zig-scheduler-vm-lab.marker"
has_vm=false
if [ -f "$vm_marker" ]; then has_vm=true; fi
if [ "$mode" != host-safe ] && [ -n "$env_file$image_arg$kernel_arg" ]; then
  run_lab_dir="$out_dir/run-lab"
  mkdir -p "$run_lab_dir"
  run_lab_args=(bash qa/vm/run_lab.sh --mode execute --out "$run_lab_dir")
  run_lab_command='bash qa/vm/run_lab.sh --mode execute'
  if [ -n "$image_arg" ]; then run_lab_args+=(--image "$image_arg"); run_lab_command="$run_lab_command --image $image_arg"; fi
  if [ -n "$kernel_arg" ]; then run_lab_args+=(--kernel "$kernel_arg"); run_lab_command="$run_lab_command --kernel $kernel_arg"; fi
  if [ -n "$env_file" ]; then run_lab_args+=(--env-file "$env_file"); run_lab_command="$run_lab_command --env-file $env_file"; fi
  set +e
  ZIG_SCHEDULER_VM_RUN_ALL=1 "${run_lab_args[@]}" > "$run_lab_dir/transcript.txt" 2>&1
  run_lab_rc=$?
  set -e
  RUN_LAB_RC="$run_lab_rc" RUN_LAB_COMMAND="$run_lab_command" RUN_LAB_DIR="$run_lab_dir" OUT_DIR="$out_dir" STAGES_DIR="$stages_dir" SUMMARY="$summary" MODE="$mode" GIT_SHA="$git_sha" STARTED_AT="$started_at" python3 - <<'PY'
import json, os
from pathlib import Path

out_dir = Path(os.environ["OUT_DIR"])
stages_dir = Path(os.environ["STAGES_DIR"])
run_lab_dir = Path(os.environ["RUN_LAB_DIR"])
manifest_path = run_lab_dir / "manifest.json"
manifest = json.loads(manifest_path.read_text())
vm_transcript_value = manifest.get("transcript_path", "")
vm_transcript = Path(vm_transcript_value) if isinstance(vm_transcript_value, str) and vm_transcript_value else None
command_status = {}
command_events = {}
if vm_transcript is not None and vm_transcript.is_file():
    for line in vm_transcript.read_text().splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        if event.get("event") == "command":
            name = str(event.get("name", ""))
            command_status[name] = str(event.get("status", "FAIL"))
            command_events[name] = event
run_lab_rc = int(os.environ["RUN_LAB_RC"])
base_status = manifest.get("status", "FAIL")
vm_kind = manifest.get("vm_kind", "vm-configured-skip")
kernel_tuple = manifest.get("kernel_tuple", {"release": "unknown", "arch": "unknown", "config_sha256": "unknown"})
status_map = {"PASS": "PASS", "skip": "SKIP", "refuse": "REFUSE"}
run_lab_status = status_map.get(str(base_status), "FAIL" if run_lab_rc != 0 else "PASS")

def delegated_status(name):
    if run_lab_status != "PASS":
        return run_lab_status
    if command_status.get(name) == "PASS":
        return "PASS"
    return "FAIL"

def delegated_reason(name):
    if run_lab_status != "PASS":
        return "VM execution harness did not complete"
    if command_status.get(name) == "PASS":
        return "delegated command present in VM execution transcript"
    return "missing delegated command in VM execution transcript"

stages = [
    ("run_lab", run_lab_status, os.environ["RUN_LAB_COMMAND"], run_lab_dir, "disposable VM harness execute"),
    ("verifier_only", delegated_status("verifier_only"), "delegated qa/vm/verifier_only.sh inside disposable VM harness", out_dir / "verifier-only", delegated_reason("verifier_only")),
    ("partial_attach", delegated_status("partial_attach"), "delegated qa/vm/partial_attach.sh inside disposable VM harness", out_dir / "partial-attach", delegated_reason("partial_attach")),
    ("rollback_drill", delegated_status("rollback_drill"), "delegated qa/vm/rollback_drill.sh inside disposable VM harness", out_dir / "rollback-drill", delegated_reason("rollback_drill")),
    ("observe_partial", delegated_status("observe_partial"), "delegated qa/vm/observe_partial.sh inside disposable VM harness", out_dir / "observe-partial", delegated_reason("observe_partial")),
    ("release_gate", "SKIP", "release gate withheld for fixture/non-release VM proof", out_dir / "release-gate", "release proof requires real VM-live evidence"),
]
started_at = os.environ["STARTED_AT"]
ended_at = started_at
stage_records = []
artifact_paths = []
for name, status, command, artifact, reason in stages:
    artifact.mkdir(parents=True, exist_ok=True)
    transcript = artifact / "transcript.txt"
    if not transcript.exists():
        command_event = command_events.get(name)
        event_text = json.dumps(command_event, sort_keys=True) if command_event is not None else "missing"
        transcript_path = vm_transcript.as_posix() if vm_transcript is not None else "missing"
        transcript.write_text(f"{reason}\nvm_kind={vm_kind}\nhost_mutation=false\nvm_transcript={transcript_path}\nvm_command_event={event_text}\n")
    rollback_result = status if name == "rollback_drill" else "N/A"
    paths = [artifact.as_posix(), transcript.as_posix()]
    if vm_transcript is not None and vm_transcript.is_file():
        paths.append(vm_transcript.as_posix())
    record = {
        "schema": "zig-scheduler/run-all-stage/v1",
        "stage": name,
        "status": status,
        "reason": reason,
        "command": command,
        "artifact": artifact.as_posix(),
        "artifact_paths": paths,
        "vm_kind": vm_kind,
        "kernel_tuple": kernel_tuple,
        "git_sha": os.environ["GIT_SHA"],
        "host_mutation": False,
        "rollback_result": rollback_result,
        "started_at": started_at,
        "ended_at": ended_at,
        "mode": os.environ["MODE"],
        "delegated_by": manifest_path.as_posix(),
    }
    stage_path = stages_dir / f"{name}.json"
    stage_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    stage_records.append(record)
    artifact_paths.extend(record["artifact_paths"])
statuses = {stage["status"] for stage in stage_records}
summary_status = "PASS"
release_status = "fixture_not_release_eligible"
if run_lab_status == "REFUSE":
    summary_status = "REFUSE"
    release_status = "vm_execution_refused"
elif run_lab_status == "FAIL" or "FAIL" in statuses:
    summary_status = "FAIL"
    release_status = "vm_execution_failed"
summary = {
    "schema": "zig-scheduler/run-all-lab/v1",
    "status": summary_status,
    "mode": os.environ["MODE"],
    "git_sha": os.environ["GIT_SHA"],
    "host_mutation": False,
    "release_status": release_status,
    "release_use": False,
    "vm_kind": vm_kind,
    "kernel_tuple": kernel_tuple,
    "rollback_result": next((stage["rollback_result"] for stage in stage_records if stage["stage"] == "rollback_drill"), "N/A"),
    "artifact_paths": artifact_paths,
    "started_at": started_at,
    "ended_at": ended_at,
    "stages": stage_records,
    "vm_execution_manifest": manifest_path.as_posix(),
    "cleanup": {"qemu_leftovers": False, "tmux_leftovers": False},
}
Path(os.environ["SUMMARY"]).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
(out_dir / "delegate-status.txt").write_text(summary_status + "\n")
PY
  printf 'summary=%s\n' "$summary"
  printf 'host_mutation=false\n'
  delegate_status="$(cat "$out_dir/delegate-status.txt")"
  if [ "$delegate_status" = REFUSE ]; then
    printf 'REFUSE: run-all VM execution harness refused\n'
    exit 1
  fi
  if [ "$delegate_status" = FAIL ]; then
    printf 'FAIL: run-all VM execution harness failed\n'
    exit 1
  fi
  printf 'PASS: run-all lab harness delegated to disposable VM execution harness\n'
  exit 0
fi

if [ "$mode" = vm-required ] && [ "$has_vm" != true ]; then
  ENDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" SUMMARY="$summary" MODE="$mode" GIT_SHA="$git_sha" KERNEL_RELEASE="$kernel_release" KERNEL_ARCH="$kernel_arch" KERNEL_CONFIG_SHA256="$kernel_config_sha256" STARTED_AT="$started_at" python3 - <<'JSONPY'
import json, os
from pathlib import Path
summary = {
    "schema": "zig-scheduler/run-all-lab/v1",
    "status": "REFUSE",
    "reason": "VM_CONFIG_REQUIRED",
    "mode": os.environ["MODE"],
    "git_sha": os.environ["GIT_SHA"],
    "host_mutation": False,
    "release_status": "skipped_no_vm",
    "release_use": False,
    "vm_kind": "host-safe-refusal",
    "kernel_tuple": {
        "release": os.environ["KERNEL_RELEASE"],
        "arch": os.environ["KERNEL_ARCH"],
        "config_sha256": os.environ["KERNEL_CONFIG_SHA256"],
    },
    "rollback_result": "REFUSE",
    "artifact_paths": [os.environ["SUMMARY"]],
    "stages": [],
    "started_at": os.environ["STARTED_AT"],
    "ended_at": os.environ["ENDED_AT"],
    "cleanup": {"qemu_leftovers": False, "tmux_leftovers": False},
}
Path(os.environ["SUMMARY"]).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
JSONPY
  printf 'REFUSE: VM_CONFIG_REQUIRED\nsummary=%s\n' "$summary"
  exit 1
fi

stage_json() {
  local stage="$1" status="$2" reason="$3" command="$4" artifact="$5" stage_started_at="$6" stage_ended_at="$7"
  local file="$stages_dir/$stage.json"
  local rollback_result="N/A"
  if [ "$stage" = rollback_drill ]; then rollback_result="$status"; fi
  STAGE="$stage" STATUS="$status" REASON="$reason" COMMAND_TEXT="$command" ARTIFACT="$artifact" GIT_SHA="$git_sha" VM_MODE="$mode" KERNEL_RELEASE="$kernel_release" KERNEL_ARCH="$kernel_arch" KERNEL_CONFIG_SHA256="$kernel_config_sha256" STAGE_STARTED_AT="$stage_started_at" STAGE_ENDED_AT="$stage_ended_at" ROLLBACK_RESULT="$rollback_result" python3 - <<'JSONPY' > "$file"
import json, os
artifact = os.environ["ARTIFACT"]
print(json.dumps({
    "schema": "zig-scheduler/run-all-stage/v1",
    "stage": os.environ["STAGE"],
    "status": os.environ["STATUS"],
    "reason": os.environ["REASON"],
    "command": os.environ["COMMAND_TEXT"],
    "artifact": artifact,
    "artifact_paths": [artifact, f"{artifact}/transcript.txt"],
    "vm_kind": "host-safe-refusal" if os.environ["STATUS"] == "REFUSE" else "host-safe-surrogate",
    "kernel_tuple": {
        "release": os.environ["KERNEL_RELEASE"],
        "arch": os.environ["KERNEL_ARCH"],
        "config_sha256": os.environ["KERNEL_CONFIG_SHA256"],
    },
    "git_sha": os.environ["GIT_SHA"],
    "host_mutation": False,
    "rollback_result": os.environ["ROLLBACK_RESULT"],
    "started_at": os.environ["STAGE_STARTED_AT"],
    "ended_at": os.environ["STAGE_ENDED_AT"],
    "mode": os.environ["VM_MODE"],
}, indent=2, sort_keys=True))
JSONPY
  printf '%s\n' "$file"
}

stage_files=()
run_stage() {
  local stage="$1" command_text="$2" artifact="$3"
  shift 3
  mkdir -p "$artifact"
  local stage_started_at stage_ended_at
  stage_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'STAGE %s: %s\n' "$stage" "$command_text"
  set +e
  /usr/bin/env -i \
    HOME="${HOME:-}" \
    LANG="${LANG:-C.UTF-8}" \
    LOGNAME="${LOGNAME:-}" \
    PATH="$trusted_path" \
    TERM="${TERM:-dumb}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    USER="${USER:-}" \
    "$@" > "$artifact/transcript.txt" 2>&1
  local rc=$?
  stage_ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    status="FAIL"; reason="unexpected stage nonzero rc=$rc"
  fi
  stage_files+=("$(stage_json "$stage" "$status" "$reason" "$command_text" "$artifact" "$stage_started_at" "$stage_ended_at")")
  printf 'STAGE %s status=%s reason=%s artifact=%s\n' "$stage" "$status" "$reason" "$artifact"
}

if [ "$mode" = host-safe ]; then
  has_vm=false
  child_vm_marker="$out_dir/host-safe-marker-must-not-exist"
else
  child_vm_marker="$vm_marker"
fi

run_lab_args=(bash qa/vm/run_lab.sh --mode read-only-smoke --out "$out_dir/run-lab")
run_lab_command='bash qa/vm/run_lab.sh --mode read-only-smoke'
if [ -n "$image_arg" ]; then run_lab_args+=(--image "$image_arg"); run_lab_command="$run_lab_command --image $image_arg"; fi
if [ -n "$kernel_arg" ]; then run_lab_args+=(--kernel "$kernel_arg"); run_lab_command="$run_lab_command --kernel $kernel_arg"; fi
if [ -n "$env_file" ]; then run_lab_args+=(--env-file "$env_file"); run_lab_command="$run_lab_command --env-file $env_file"; fi
run_stage run_lab "$run_lab_command" "$out_dir/run-lab" "${run_lab_args[@]}"
verifier_env=(env ZIG_SCHEDULER_VM_MARKER="$child_vm_marker")
verifier_command='bash qa/vm/verifier_only.sh --object zig-out/bpf/zigsched_minimal.bpf.o'
if [ "$mode" = host-safe ]; then
  verifier_env+=(ZIG_SCHEDULER_HOST_SAFE=1)
  verifier_command='ZIG_SCHEDULER_HOST_SAFE=1 bash qa/vm/verifier_only.sh --object zig-out/bpf/zigsched_minimal.bpf.o'
fi
run_stage verifier_only "$verifier_command" "$out_dir/verifier-only" "${verifier_env[@]}" bash qa/vm/verifier_only.sh --object zig-out/bpf/zigsched_minimal.bpf.o --out "$out_dir/verifier-only"
partial_attach_env=(env ZIG_SCHEDULER_VM_MARKER="$child_vm_marker")
partial_attach_args=(bash qa/vm/partial_attach.sh --target /sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope --audit-id AUD-20990101T000000Z-deadbee-abc123 --rollback-id RB-runall --out "$out_dir/partial-attach" --object zig-out/bpf/zigsched_minimal.bpf.o)
partial_attach_command='bash qa/vm/partial_attach.sh host-safe target'
if [ "$mode" = host-safe ]; then
  partial_attach_env+=(ZIG_SCHEDULER_HOST_SAFE=1)
  partial_attach_command='ZIG_SCHEDULER_HOST_SAFE=1 bash qa/vm/partial_attach.sh host-safe target'
else
  partial_attach_args+=(--approval evidence/releases/0.2.0-lab/release-approval.json)
fi
run_stage partial_attach "$partial_attach_command" "$out_dir/partial-attach" "${partial_attach_env[@]}" "${partial_attach_args[@]}"
run_stage rollback_drill 'bash qa/vm/rollback_drill.sh' "$out_dir/rollback-drill" bash qa/vm/rollback_drill.sh --out "$out_dir/rollback-drill"
run_stage cgroup_race 'bash qa/vm/cgroup_race.sh' "$out_dir/cgroup-race" bash qa/vm/cgroup_race.sh --out "$out_dir/cgroup-race"
run_stage dsq_policy_smoke 'bash qa/vm/dsq_policy_smoke.sh --policy vtime --duration 1s' "$out_dir/dsq-policy" bash qa/vm/dsq_policy_smoke.sh --policy vtime --duration 1s --out "$out_dir/dsq-policy"
run_stage stress_chaos 'bash qa/vm/stress_chaos.sh --duration 1s' "$out_dir/stress-chaos" bash qa/vm/stress_chaos.sh --duration 1s --out "$out_dir/stress-chaos"
run_stage observe_partial 'bash qa/vm/observe_partial.sh --samples 3' "$out_dir/observe-partial" bash qa/vm/observe_partial.sh --samples 3 --out "$out_dir/observe-partial"
release_evidence_dir="evidence/releases/$release_version"
run_stage release_gate "bash qa/release_gate.sh --version $release_version --no-approval" "$out_dir/release-gate" bash qa/release_gate.sh --version "$release_version" --evidence "$release_evidence_dir" --no-approval

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
rollback_result = next((stage["rollback_result"] for stage in stages if stage["stage"] == "rollback_drill"), "N/A")
artifact_paths = []
for stage in stages:
    artifact_paths.extend(stage["artifact_paths"])
summary = {
    "schema": "zig-scheduler/run-all-lab/v1",
    "status": "PASS" if statuses <= {"PASS", "SKIP", "REFUSE"} else "FAIL",
    "mode": os.environ["MODE"],
    "git_sha": os.environ["GIT_SHA"],
    "host_mutation": False,
    "release_status": release_status,
    "release_use": False,
    "vm_kind": "host-safe-surrogate",
    "kernel_tuple": stages[0]["kernel_tuple"] if stages else {"release": "unknown", "arch": "unknown", "config_sha256": "unknown"},
    "rollback_result": rollback_result,
    "artifact_paths": artifact_paths,
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
if python3 - <<'PY' "$summary"
import json, sys
from pathlib import Path
raise SystemExit(0 if json.loads(Path(sys.argv[1]).read_text()).get('status') == 'PASS' else 1)
PY
then
  if python3 - <<'PY' "$summary"
import json, sys
from pathlib import Path
raise SystemExit(0 if json.loads(Path(sys.argv[1]).read_text()).get('status') == 'PASS' else 1)
PY
then
  if python3 - <<'PY' "$summary"
import json, sys
from pathlib import Path
raise SystemExit(0 if json.loads(Path(sys.argv[1]).read_text()).get('status') == 'PASS' else 1)
PY
then
  printf 'PASS: run-all lab harness complete\n'
else
  printf 'FAIL: run-all lab harness contains failed stage\n' >&2
  exit 1
fi
else
  printf 'FAIL: run-all lab harness contains failed stage\n' >&2
  exit 1
fi
else
  printf 'FAIL: run-all lab harness contains failed stage\n' >&2
  exit 1
fi
