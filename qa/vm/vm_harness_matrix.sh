#!/usr/bin/env bash
# SIZE_OK: integration gate driver intentionally keeps output ownership, sequential row execution, event emission, and cleanup traps in one audited CI entrypoint; split next by extracting row JSON emission and scenario-shape helpers.
# Canonical host-safe matrix runner for VM lab rows. It emits standalone
# matrix-run/v1 artifacts and only delegates to live VM scripts when an
# explicit live scenario is selected.
set -euo pipefail

trusted_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH="$trusted_path:$PATH"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/vm/vm_output_safety.sh
source qa/vm/qemu_cleanup.sh

emit_helper="qa/vm/vm_harness_matrix_emit.py"

mode="host-safe"
out_dir=""
fixture_mode=false
manifest_fixture_mode=false
timeout_seconds="120"
suite=""
declare -a scenarios=()

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
usage: qa/vm/vm_harness_matrix.sh --mode host-safe|auto|vm-required --out evidence/lab/matrix/<run-id> [--suite protected-core] [--scenario <id>[,<id>...]] [--fixture] [--timeout <seconds>]

Canonical VM harness matrix runner:
  - host-safe by default; never loads BPF, attaches sched_ext, writes cgroups, or mutates /sys or /proc on the host
  - writes a manifest index plus per-row zig-scheduler/matrix-run/v1 artifacts
  - runs selected rows sequentially and records daemon-event/v1 lifecycle rows
  - refuses output outside evidence/lab/matrix/<run-id> and never reuses an existing run directory
  - requires <run-id> to be 1-64 characters from A-Z, a-z, 0-9, underscore, dot, and dash
  - host-safe fixture PASS rows emit evidence_mode=fixture without claiming a real VM marker
  - VM-live PASS rows require a present /run/zig-scheduler-vm-lab.marker and a row-local marker proof
  - vm-required rows without the marker fail closed as REFUSE; host-safe/auto marker-missing prerequisite rows SKIP/REFUSE
  - fixture scenarios emit deterministic lab evidence without launching QEMU or claiming production/release readiness
  - live-backend delegates to qa/vm/vm_lab_backend.sh only when explicitly selected
  - protected-core suite selects live-backend, CPU saturation, cgroup weight/quota, and exactly one latency/churn row
  - protected-core uses workload-interactive-latency first and falls back to workload-scheduler-affinity-churn only when latency prerequisites are unavailable
  - suite rows use row-local directories/artifacts/names and never reuse artifacts across rows

Scenarios:
  fixture-pass        deterministic host-safe PASS row with evidence_mode=fixture unless a real VM marker is present
  missing-qemu        typed SKIP (host-safe/auto) or REFUSE (vm-required)
  missing-kvm         typed SKIP (host-safe/auto) or REFUSE (vm-required)
  missing-kernel      typed SKIP (host-safe/auto) or REFUSE (vm-required)
  missing-nix         typed SKIP (host-safe/auto) or REFUSE (vm-required)
  missing-workload    typed SKIP (host-safe/auto) or REFUSE (vm-required)
  workload-cpu-saturation             CPU saturation fixture/probe row (stress-ng)
  workload-interactive-latency        interactive latency fixture/probe row (cyclictest, perf)
  workload-scheduler-affinity-churn   scheduler/affinity churn fixture/probe row (stress-ng, taskset, chrt)
  workload-fork-ipc-pressure          bounded fork/IPC pressure fixture/probe row (hackbench-like)
  workload-mixed-io                   mixed I/O fixture/probe row (fio)
  workload-cgroup-weight-quota        cgroup weight/quota pressure fixture/probe row (stress-ng)
  workload-cpu-hotplug                CPU hotplug/offline fixture/probe row where supported
  fixture-refuse      host-refusal-only REFUSE row
  fixture-incident    deterministic fixture INCIDENT row, or vm-live only when the VM marker is present
  fixture-timeout     deterministic fixture timeout INCIDENT row, or vm-live only when the VM marker is present
  live-backend        explicit delegation to qa/vm/vm_lab_backend.sh
USAGE
}

add_scenarios() {
  local raw="$1" part rest
  rest="$raw"
  while :; do
    part="${rest%%,*}"
    [ -n "$part" ] || fail 'empty --scenario entry'
    scenarios+=("$part")
    [ "$rest" = "$part" ] && break
    rest="${rest#*,}"
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || fail '--mode requires value'; mode="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail '--out requires value'; out_dir="$2"; shift 2 ;;
    --scenario) [ "$#" -ge 2 ] || fail '--scenario requires value'; add_scenarios "$2"; shift 2 ;;
    --suite) [ "$#" -ge 2 ] || fail '--suite requires value'; suite="$2"; shift 2 ;;
    --fixture) fixture_mode=true; shift ;;
    --timeout) [ "$#" -ge 2 ] || fail '--timeout requires value'; timeout_seconds="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$mode" in host-safe|auto|vm-required) ;; *) fail '--mode must be host-safe, auto, or vm-required' ;; esac
case "$suite" in ""|protected-core) ;; *) fail '--suite must be protected-core' ;; esac
manifest_fixture_mode="$fixture_mode"
[ -n "$out_dir" ] || fail '--out is required'
case "$out_dir$mode$timeout_seconds$suite" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
case "$timeout_seconds" in ''|*[!0-9]*) fail '--timeout must be a positive integer' ;; esac
[ "$timeout_seconds" -gt 0 ] || fail '--timeout must be positive'
if [ -n "$suite" ] && [ "${#scenarios[@]}" -ne 0 ]; then
  fail '--suite cannot be combined with --scenario; suites own exact row selection'
fi
if [ "${#scenarios[@]}" -eq 0 ] && [ -z "$suite" ]; then
  scenarios=(fixture-pass)
fi
matrix_base="evidence/lab/matrix"
ownership_marker=".zig-scheduler-vm-harness-matrix-owned"
run_id_max=64

validate_workload_tool_name() {
  case "$1" in
    stress-ng|cyclictest|perf|taskset|chrt|hackbench-like|fio|cpu-hotplug-online-control) return 0 ;;
    *) fail 'unsafe forced missing workload tool' ;;
  esac
}

validate_forced_missing_workload_tool_for_scenario() {
  local scenario="$1" tool="$2"
  case "$scenario:$tool" in
    workload-cpu-saturation:stress-ng) return 0 ;;
    workload-interactive-latency:cyclictest|workload-interactive-latency:perf) return 0 ;;
    workload-scheduler-affinity-churn:stress-ng|workload-scheduler-affinity-churn:taskset|workload-scheduler-affinity-churn:chrt) return 0 ;;
    workload-fork-ipc-pressure:hackbench-like) return 0 ;;
    workload-mixed-io:fio) return 0 ;;
    workload-cgroup-weight-quota:stress-ng) return 0 ;;
    workload-cpu-hotplug:cpu-hotplug-online-control) return 0 ;;
    workload-*:*) return 1 ;;
    *) return 1 ;;
  esac
}

validate_forced_missing_workload_tool_selection() {
  local forced="${ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL:-}" scenario workload_seen=false
  [ -z "$forced" ] && return 0
  validate_workload_tool_name "$forced"
  for scenario in "${scenarios[@]}"; do
    if validate_forced_missing_workload_tool_for_scenario "$scenario" "$forced"; then
      workload_seen=true
    fi
  done
  if [ "$workload_seen" != true ]; then
    case "$suite:$forced" in
      protected-core:cyclictest|protected-core:perf) return 0 ;;
    esac
    fail 'ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL requires a selected workload-* scenario that uses the named tool'
  fi
}

prepare_matrix_out_dir() {
  local allowed_root parent_dir parent_real target_real run_component
  case "$out_dir" in "$matrix_base"/*) ;; *) fail "--out must be a relative path under $matrix_base/<run-id>" ;; esac
  case "$out_dir" in *$'\n'*|*$'\r'*|*'/../'*|../*|*/..|*/./*|*/.) fail 'unsafe output path' ;; esac
  run_component="${out_dir#"$matrix_base"/}"
  case "$run_component" in ''|*/*|*[!A-Za-z0-9_.-]*) fail "--out must be exactly $matrix_base/<safe-run-id>" ;; esac
  [ "${#run_component}" -le "$run_id_max" ] || fail "--out run id must be at most $run_id_max characters"
  vm_output_safety_prepare_parent "$matrix_base" "$out_dir"
  allowed_root="$(realpath "$matrix_base")"
  parent_dir="$(dirname -- "$out_dir")"
  parent_real="$(realpath "$parent_dir")"
  vm_output_safety_require_inside "$allowed_root" "$parent_real" parent
  [ ! -L "$out_dir" ] || fail '--out must not be a symlink'
  [ ! -e "$out_dir" ] || fail "output directory collision refused: $out_dir"
  mkdir "$out_dir"
  target_real="$(realpath "$out_dir")"
  vm_output_safety_require_inside "$allowed_root" "$target_real" target
  : > "$out_dir/$ownership_marker"
}


run_id=""
started_at=""
git_sha=""
event_file=""
manifest_rows=""
seq=1
final_rc=0

emit_event() {
  local event="$1" status="$2" scenario="$3" artifact="$4" reason="$5" action_id="ACT-$scenario" rollback_id="RB-$scenario" audit_id audit_suffix
  audit_suffix="$(printf '%06x' "$seq")"
  audit_id="AUD-$(date -u +%Y%m%dT%H%M%SZ)-$git_sha-$audit_suffix"
  SEQ="$seq" EVENT="$event" STATUS="$status" RUN_ID="$run_id" SCENARIO="$scenario" ARTIFACT="$artifact" REASON="$reason" ACTION_ID="$action_id" ROLLBACK_ID="$rollback_id" AUDIT_ID="$audit_id" GIT_SHA="$git_sha" python3 "$emit_helper" event >> "$event_file"
  seq=$((seq + 1))
}

scan_owned_temps() {
  local scenario="$1" output="$2" tmp_root="${TMPDIR:-/tmp}"
  find "$tmp_root" -maxdepth 1 -type d -name "zigsched-vm-harness-matrix-$run_id-$scenario-*" -print 2>/dev/null | sort > "$output"
}

workload_scenarios=" workload-cpu-saturation workload-interactive-latency workload-scheduler-affinity-churn workload-fork-ipc-pressure workload-mixed-io workload-cgroup-weight-quota workload-cpu-hotplug "

is_workload_scenario() {
  case "$workload_scenarios" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

workload_class() {
  case "$1" in
    workload-cpu-saturation) printf 'cpu-saturation' ;;
    workload-interactive-latency) printf 'interactive-latency' ;;
    workload-scheduler-affinity-churn) printf 'scheduler-affinity-churn' ;;
    workload-fork-ipc-pressure) printf 'bounded-fork-ipc-pressure' ;;
    workload-mixed-io) printf 'mixed-io' ;;
    workload-cgroup-weight-quota) printf 'cgroup-weight-quota-pressure' ;;
    workload-cpu-hotplug) printf 'cpu-hotplug-offline' ;;
    *) return 1 ;;
  esac
}

workload_tools() {
  case "$1" in
    workload-cpu-saturation) printf 'stress-ng' ;;
    workload-interactive-latency) printf 'cyclictest,perf' ;;
    workload-scheduler-affinity-churn) printf 'stress-ng,taskset,chrt' ;;
    workload-fork-ipc-pressure) printf 'hackbench-like' ;;
    workload-mixed-io) printf 'fio' ;;
    workload-cgroup-weight-quota) printf 'stress-ng' ;;
    workload-cpu-hotplug) printf 'cpu-hotplug-online-control' ;;
    *) return 1 ;;
  esac
}

vm_marker_available() { [ -e /run/zig-scheduler-vm-lab.marker ]; }

missing_vm_marker_shape() {
  if [ "$mode" = vm-required ]; then
    printf 'REFUSE host-refusal-only unknown unknown unknown unknown false false vm marker unavailable'
  else
    printf 'SKIP host-refusal-only unsupported unknown unknown unknown false false vm marker unavailable'
  fi
}

vm_live_shape_or_marker_refusal() {
  local outcome="$1" reason="$2"
  if vm_marker_available; then
    printf '%s vm-live supported present available available true true %s' "$outcome" "$reason"
  else
    missing_vm_marker_shape
  fi
}

fixture_shape_or_vm_live() {
  local outcome="$1" reason="$2"
  if vm_marker_available; then
    printf '%s vm-live supported present available available true true %s' "$outcome" "$reason"
  elif [ "$mode" = vm-required ]; then
    missing_vm_marker_shape
  else
    printf '%s fixture unknown unknown unknown unknown false false %s' "$outcome" "$reason"
  fi
}

workload_threshold_source() {
  case "$1" in
    workload-cpu-saturation|workload-interactive-latency|workload-scheduler-affinity-churn|workload-fork-ipc-pressure|workload-mixed-io|workload-cgroup-weight-quota|workload-cpu-hotplug) printf 'record-only' ;;
    *) return 1 ;;
  esac
}

command_available() { command -v "$1" >/dev/null 2>&1; }

workload_missing_prereq() {
  local scenario="$1" forced="${ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL:-}"
  if [ -n "$forced" ]; then
    validate_workload_tool_name "$forced"
    if validate_forced_missing_workload_tool_for_scenario "$scenario" "$forced"; then
      printf '%s' "$forced"
      return 0
    fi
    return 1
  fi
  [ "$mode" = vm-required ] || return 1
  case "$scenario" in
    workload-cpu-saturation|workload-cgroup-weight-quota) command_available stress-ng || { printf 'stress-ng'; return 0; } ;;
    workload-interactive-latency) command_available cyclictest || { printf 'cyclictest'; return 0; }; command_available perf || { printf 'perf'; return 0; } ;;
    workload-scheduler-affinity-churn) command_available stress-ng || { printf 'stress-ng'; return 0; }; command_available taskset || { printf 'taskset'; return 0; }; command_available chrt || { printf 'chrt'; return 0; } ;;
    workload-fork-ipc-pressure) command_available hackbench || command_available perf || { printf 'hackbench-like'; return 0; } ;;
    workload-mixed-io) command_available fio || { printf 'fio'; return 0; } ;;
    workload-cpu-hotplug) [ -w /sys/devices/system/cpu/cpu1/online ] || { printf 'cpu-hotplug-online-control'; return 0; } ;;
    *) return 1 ;;
  esac
  return 1
}

select_suite_scenarios() {
  local missing
  case "$suite" in
    "") return 0 ;;
    protected-core)
      scenarios=(live-backend workload-cpu-saturation workload-cgroup-weight-quota workload-interactive-latency)
      if missing="$(workload_missing_prereq workload-interactive-latency)"; then
        scenarios=(live-backend workload-cpu-saturation workload-cgroup-weight-quota workload-scheduler-affinity-churn)
        printf 'protected-core latency row fallback selected: workload-interactive-latency prerequisite unavailable (%s); using workload-scheduler-affinity-churn\n' "$missing" >&2
      fi
      ;;
  esac
}

validate_selected_scenarios() {
  local scenario
  for scenario in "${scenarios[@]}"; do
    case "$scenario" in *[!A-Za-z0-9_.-]*|'') fail "unsafe scenario id: $scenario" ;; esac
  done
}

initialize_run_dir() {
  prepare_matrix_out_dir
  cat > "$out_dir/.gitignore" <<'GITIGNORE'
*
!.gitignore
GITIGNORE

  run_id="$(basename -- "$out_dir")"
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git_sha="$(git rev-parse --short=12 HEAD 2>/dev/null || printf unknown)"
  event_file="$out_dir/daemon-events.jsonl"
  manifest_rows="$out_dir/manifest-rows.jsonl"
  : > "$event_file"
  : > "$manifest_rows"
  seq=1
  final_rc=0
}

workload_probe_status() {
  local scenario="$1" missing
  if missing="$(workload_missing_prereq "$scenario")"; then
    if [ "$mode" = vm-required ]; then
      printf 'REFUSE host-refusal-only unknown present available unknown false false workload-%s prerequisite unavailable' "$missing"
    else
      printf 'SKIP host-refusal-only unsupported present available unknown false false workload-%s prerequisite unavailable' "$missing"
    fi
  else
    fixture_shape_or_vm_live PASS 'workload fixture probe completed'
  fi
}

scenario_shape() {
  local scenario="$1"
  case "$scenario" in
    fixture-pass) fixture_shape_or_vm_live PASS 'fixture pass completed'; printf '\n' ;;
    missing-qemu) [ "$mode" = vm-required ] && printf 'REFUSE host-refusal-only unknown unknown unavailable unknown false false qemu prerequisite unavailable\n' || printf 'SKIP host-refusal-only unsupported unknown unavailable unknown false false qemu prerequisite unavailable\n' ;;
    missing-kvm) [ "$mode" = vm-required ] && printf 'REFUSE host-refusal-only unknown present unavailable unknown false false kvm prerequisite unavailable\n' || printf 'SKIP host-refusal-only unsupported present unavailable unknown false false kvm prerequisite unavailable\n' ;;
    missing-kernel) [ "$mode" = vm-required ] && printf 'REFUSE host-refusal-only unknown unknown unknown unknown false false kernel prerequisite unavailable\n' || printf 'SKIP host-refusal-only unsupported unknown unknown unknown false false kernel prerequisite unavailable\n' ;;
    missing-nix) [ "$mode" = vm-required ] && printf 'REFUSE host-refusal-only unknown present available unknown false false nix prerequisite unavailable\n' || printf 'SKIP host-refusal-only unsupported present available unknown false false nix prerequisite unavailable\n' ;;
    missing-workload) [ "$mode" = vm-required ] && printf 'REFUSE host-refusal-only unknown present available unknown false false workload prerequisite unavailable\n' || printf 'SKIP host-refusal-only unsupported present available unknown false false workload prerequisite unavailable\n' ;;
    fixture-refuse) printf 'REFUSE host-refusal-only unknown present available unknown false false host refusal fixture completed\n' ;;
    fixture-incident) fixture_shape_or_vm_live INCIDENT 'verifier incident fixture completed'; printf '\n' ;;
    fixture-timeout) fixture_shape_or_vm_live INCIDENT 'timeout fixture completed'; printf '\n' ;;
    workload-*) is_workload_scenario "$scenario" && { workload_probe_status "$scenario"; printf '\n'; } || return 1 ;;
    *) return 1 ;;
  esac
}

write_matrix_row() {
  local scenario="$1" row_dir="$2" outcome="$3" evidence_mode="$4" tuple_status="$5" btf="$6" kvm="$7" sched_ext="$8" marker_present="$9" marker_required="${10}" reason="${11}" fixture_authority="${12}"
  local qemu_before="$row_dir/qemu-process-scan-before.txt" qemu_after="$row_dir/qemu-process-scan-after.txt"
  local temp_before="$row_dir/temp-scan-before.txt" temp_after="$row_dir/temp-scan-after.txt"
  mkdir -p "$row_dir"
  qemu_scan_processes "$qemu_before"
  scan_owned_temps "$scenario" "$temp_before"
  scan_owned_temps "$scenario" "$temp_after"
  qemu_scan_processes "$qemu_after"
  if qemu_owned_leftovers "$qemu_after" || [ -s "$temp_after" ]; then
    outcome="FAIL"
    reason="cleanup residue detected"
  fi
  local workload_class_value="cpu-smoke" workload_tools_value="builtin-churn" threshold_source_value="fixture" missing_prereq_value=""
  if [ "$scenario" = live-backend ]; then
    threshold_source_value="record-only"
  elif is_workload_scenario "$scenario"; then
    workload_class_value="$(workload_class "$scenario")"
    workload_tools_value="$(workload_tools "$scenario")"
    threshold_source_value="$(workload_threshold_source "$scenario")"
    if missing_prereq_value="$(workload_missing_prereq "$scenario")"; then :; else missing_prereq_value=""; fi
  fi
  SCENARIO="$scenario" ROW_DIR="$row_dir" EVENT_FILE="$event_file" OUTCOME="$outcome" EVIDENCE_MODE="$evidence_mode" TUPLE_STATUS="$tuple_status" BTF="$btf" KVM_STATUS="$kvm" SCHED_EXT="$sched_ext" MARKER_PRESENT="$marker_present" MARKER_REQUIRED="$marker_required" REASON="$reason" RUN_ID="$run_id" GIT_SHA="$git_sha" MODE="$mode" FIXTURE_MODE="$fixture_authority" TIMEOUT_SECONDS="$timeout_seconds" WORKLOAD_CLASS="$workload_class_value" WORKLOAD_TOOLS="$workload_tools_value" WORKLOAD_THRESHOLD_SOURCE="$threshold_source_value" WORKLOAD_MISSING_PREREQ="$missing_prereq_value" QEMU_BEFORE="$qemu_before" QEMU_AFTER="$qemu_after" TEMP_BEFORE="$temp_before" TEMP_AFTER="$temp_after" LIVE_AUDIT_ID="${LIVE_AUDIT_ID:-}" LIVE_ROLLBACK_ID="${LIVE_ROLLBACK_ID:-}" python3 "$emit_helper" row
}

append_manifest_row() {
  local scenario="$1" outcome="$2" row_path="$3" reason="$4"
  SCENARIO="$scenario" OUTCOME="$outcome" ROW_PATH="$row_path" REASON="$reason" python3 "$emit_helper" manifest-row >> "$manifest_rows"
}

run_fixture_scenario() {
  local scenario="$1" row_dir="$out_dir/rows/$scenario" shape outcome evidence_mode tuple_status btf kvm sched_ext marker_present marker_required reason row_path fixture_authority
  if ! shape="$(scenario_shape "$scenario")"; then
    fail "unknown scenario: $scenario"
  fi
  read -r outcome evidence_mode tuple_status btf kvm sched_ext marker_present marker_required reason <<< "$shape"
  fixture_authority="$fixture_mode"
  if [ "$evidence_mode" = fixture ]; then
    fixture_authority=true
    manifest_fixture_mode=true
  fi
  case "$scenario" in
    missing-qemu) reason="forced missing QEMU prerequisite" ;;
    missing-kvm) reason="forced missing KVM prerequisite" ;;
    missing-kernel) reason="forced missing kernel prerequisite" ;;
    missing-nix) reason="forced missing Nix prerequisite" ;;
    missing-workload) reason="forced missing workload prerequisite" ;;
    fixture-timeout) reason="forced timeout row" ;;
    fixture-incident) reason="forced incident row" ;;
    fixture-refuse) reason="forced host refusal row" ;;
    fixture-pass) reason="fixture pass row" ;;
  esac
  emit_event stage_started STARTED "$scenario" "$row_dir" "$reason"
  outcome="$(write_matrix_row "$scenario" "$row_dir" "$outcome" "$evidence_mode" "$tuple_status" "$btf" "$kvm" "$sched_ext" "$marker_present" "$marker_required" "$reason" "$fixture_authority")"
  row_path="$row_dir/matrix-run.json"
  case "$outcome" in
    PASS) emit_event validation PASS "$scenario" "$row_path" "$reason" ;;
    SKIP|REFUSE) emit_event refusal "$outcome" "$scenario" "$row_path" "$reason" ;;
    INCIDENT|FAIL) emit_event incident "$outcome" "$scenario" "$row_path" "$reason" ;;
  esac
  emit_event rollback PASS "$scenario" "$row_dir/rollback-proof.json" "rollback proof recorded"
  emit_event cleanup PASS "$scenario" "$row_dir/cleanup-proof.json" "cleanup proof recorded"
  append_manifest_row "$scenario" "$outcome" "$row_path" "$reason"
  if [ "$mode" = vm-required ] && { [ "$outcome" = REFUSE ] || [ "$outcome" = SKIP ]; }; then
    final_rc=1
  fi
}

live_backend_pass_shape() {
  local summary="$1"
  [ -f "$summary" ] || return 1
  python3 - "$summary" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
summary_path = Path(sys.argv[1])
expected_live_summary = summary_path.parent / "live" / "summary.json"
try:
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if summary.get("schema") != "zig-scheduler/vm-backend-run/v1":
    raise SystemExit(1)
if summary.get("status") != "PASS" or summary.get("host_mutation") is not False:
    raise SystemExit(1)
if summary.get("vm_kind") != "qemu-vm" or summary.get("vm_marker_present") is not True:
    raise SystemExit(1)
if summary.get("vm_marker_path") != "/run/zig-scheduler-vm-lab.marker":
    raise SystemExit(1)
required = ("daemon_events", "cleanup_receipt", "staging_manifest", "live_summary")
for key in required:
    value = summary.get(key)
    if not isinstance(value, str) or not value.startswith("evidence/lab/matrix/"):
        raise SystemExit(1)
live_summary = Path(str(summary.get("live_summary", "")))
if live_summary != expected_live_summary:
    raise SystemExit(1)
try:
    live = json.loads(live_summary.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if live.get("status") != "PASS" or live.get("evidence_mode") != "vm-live":
    raise SystemExit(1)
check = subprocess.run(("python3", "qa/live_behavior_check.py", "--bundle", live_summary.as_posix()), capture_output=True, text=True)
if check.returncode != 0:
    raise SystemExit(1)
if live.get("git_dirty") is not False:
    raise SystemExit(1)
live_git_sha = live.get("git_sha")
if not isinstance(live_git_sha, str) or not live_git_sha.startswith(summary.get("audit_id", "").split("-")[-2]):
    raise SystemExit(1)
for key in ("audit_id", "rollback_id"):
    if not isinstance(summary.get(key), str) or not summary[key]:
        raise SystemExit(1)
print("PASS vm-live supported present available available true true live_backend_completed {} {}".format(summary["audit_id"], summary["rollback_id"]))
PY
}

live_backend_refusal_reason() {
  local summary="$1"
  [ -f "$summary" ] || { printf 'live backend summary unavailable'; return 0; }
  python3 - "$summary" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
summary_path = Path(sys.argv[1])
try:
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    print("live backend summary malformed")
    raise SystemExit(0)
live_summary = summary.get("live_summary")
if not isinstance(live_summary, str):
    print("live backend live_summary path missing")
    raise SystemExit(0)
try:
    live = json.loads(Path(live_summary).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    print("live backend live summary malformed")
    raise SystemExit(0)
if live.get("status") == "PASS" and live.get("evidence_mode") == "vm-live":
    check = subprocess.run(("python3", "qa/live_behavior_check.py", "--bundle", live_summary), capture_output=True, text=True)
    if check.returncode != 0:
        message = (check.stderr or check.stdout).strip()
        print(f"nested live behavior validation failed: {message}" if message else "nested live behavior validation failed")
        raise SystemExit(0)
if live.get("git_dirty") is True:
    print("live backend dirty git state refused")
    raise SystemExit(0)
if live.get("git_dirty") is not False:
    print("live backend git_dirty missing or invalid")
    raise SystemExit(0)
print("live backend refused or unavailable")
PY
}

overlay_live_backend_artifacts() {
  local row_dir="$1" backend_summary="$2"
  BACKEND_SUMMARY="$backend_summary" ROW_DIR="$row_dir" python3 "$emit_helper" overlay-backend
}

live_workload_pass_shape() {
  local scenario="$1" summary="$2"
  [ -f "$summary" ] || return 1
  SCENARIO="$scenario" SUMMARY="$summary" python3 - <<'PYINNER'
import json
from pathlib import Path
import os
scenario = os.environ["SCENARIO"]
summary_path = Path(os.environ["SUMMARY"])
expected_live_summary = summary_path.parent / "live" / "summary.json"
try:
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if summary.get("schema") != "zig-scheduler/vm-backend-run/v1" or summary.get("status") != "PASS":
    raise SystemExit(1)
if summary.get("host_mutation") is not False or summary.get("vm_kind") != "qemu-vm" or summary.get("vm_marker_present") is not True:
    raise SystemExit(1)
live_summary = Path(str(summary.get("live_summary", "")))
if live_summary != expected_live_summary or not live_summary.is_file():
    raise SystemExit(1)
runtime = live_summary.parent / "observe-partial" / "runtime-samples.jsonl"
if not runtime.is_file():
    raise SystemExit(1)
try:
    from qa.protected_core_telemetry_check import ProtectedCoreTelemetryError, validate_vm_captured_input
    from qa.runtime_sample_common import RuntimeSampleError
    validate_vm_captured_input(runtime, scenario)
except (ImportError, OSError, RuntimeSampleError, ProtectedCoreTelemetryError):
    raise SystemExit(1)
try:
    live = json.loads(live_summary.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if live.get("status") != "PASS" or live.get("evidence_mode") != "vm-live" or live.get("git_dirty") is not False:
    raise SystemExit(1)
serial = live_summary.parent / "serial.txt"
try:
    serial_text = serial.read_text(encoding="utf-8", errors="replace")
except OSError:
    raise SystemExit(1)
sys_path = Path("qa/vm").resolve()
import sys
sys.path.insert(0, sys_path.as_posix())
try:
    from workload_execution_check import WorkloadExecutionError, require_workload_pass
    require_workload_pass(serial_text, scenario)
except (ImportError, WorkloadExecutionError):
    raise SystemExit(1)
for key in ("audit_id", "rollback_id"):
    if not isinstance(summary.get(key), str) or not summary[key]:
        raise SystemExit(1)
print("PASS vm-live supported present available available true true live_workload_completed {} {}".format(summary["audit_id"], summary["rollback_id"]))
PYINNER
}

live_workload_refusal_reason() {
  local scenario="$1" summary="$2"
  [ -f "$summary" ] || { printf 'live workload %s summary unavailable' "$scenario"; return 0; }
  SCENARIO="$scenario" SUMMARY="$summary" python3 - <<'PYINNER'
import json
import os
from pathlib import Path
scenario = os.environ["SCENARIO"]
summary_path = Path(os.environ["SUMMARY"])
try:
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    print(f"live workload {scenario} summary malformed")
    raise SystemExit(0)
status = summary.get("status", "unknown")
reason = summary.get("reason") or summary.get("incident_code") or "unavailable"
print(f"live workload {scenario} refused or unavailable: status={status} reason={reason}")
PYINNER
}

overlay_live_workload_artifacts() {
  local row_dir="$1" backend_summary="$2"
  BACKEND_SUMMARY="$backend_summary" ROW_DIR="$row_dir" python3 "$emit_helper" overlay-workload
}

run_live_workload() {
  local scenario="$1" row_dir backend_dir runner_rc outcome evidence_mode tuple_status btf kvm sched_ext marker_present marker_required reason row_path shape live_audit_id live_rollback_id missing_tool
  row_dir="$out_dir/rows/$scenario"
  backend_dir="$row_dir/backend"
  mkdir -p "$row_dir"
  if missing_tool="$(workload_missing_prereq "$scenario")"; then
    reason="workload-$missing_tool prerequisite unavailable"
    emit_event stage_started STARTED "$scenario" "$row_dir" "$reason"
    if [ "$mode" = vm-required ]; then
      outcome=REFUSE; evidence_mode=host-refusal-only; tuple_status=unknown; btf=unknown; kvm=unknown; sched_ext=unknown; marker_present=false; marker_required=false; final_rc=1
    else
      outcome=SKIP; evidence_mode=host-refusal-only; tuple_status=unsupported; btf=present; kvm=available; sched_ext=unknown; marker_present=false; marker_required=false
    fi
  else
    emit_event stage_started STARTED "$scenario" "$backend_dir" "delegating protected-core workload to qa/vm/vm_lab_backend.sh"
    set +e
    if [ "$fixture_mode" = true ]; then
      printf 'fixture mode refuses live workload delegation\n' > "$row_dir/backend-skipped.txt"
      runner_rc=99
    else
      timeout "$timeout_seconds" bash qa/vm/vm_lab_backend.sh --mode "$mode" --scenario "$scenario" --out "$backend_dir" > "$row_dir/backend.stdout.txt" 2> "$row_dir/backend.stderr.txt"
      runner_rc=$?
    fi
    set -e
    if [ "$runner_rc" -eq 0 ] && shape="$(live_workload_pass_shape "$scenario" "$backend_dir/summary.json")"; then
      read -r outcome evidence_mode tuple_status btf kvm sched_ext marker_present marker_required reason live_audit_id live_rollback_id <<< "$shape"
    elif [ "$runner_rc" -eq 124 ]; then
      outcome=INCIDENT; evidence_mode=host-refusal-only; tuple_status=unknown; btf=unknown; kvm=unknown; sched_ext=unknown; marker_present=false; marker_required=false; reason="live workload timeout"; final_rc=1
    else
      outcome=REFUSE; evidence_mode=host-refusal-only; tuple_status=unknown; btf=unknown; kvm=unknown; sched_ext=unknown; marker_present=false; marker_required=false; reason="$(live_workload_refusal_reason "$scenario" "$backend_dir/summary.json")"
      [ "$mode" = vm-required ] && final_rc=1
    fi
  fi
  outcome="$(LIVE_AUDIT_ID="${live_audit_id:-}" LIVE_ROLLBACK_ID="${live_rollback_id:-}" write_matrix_row "$scenario" "$row_dir" "$outcome" "$evidence_mode" "$tuple_status" "$btf" "$kvm" "$sched_ext" "$marker_present" "$marker_required" "$reason" "$fixture_mode")"
  overlay_live_workload_artifacts "$row_dir" "$backend_dir/summary.json"
  row_path="$row_dir/matrix-run.json"
  case "$outcome" in
    PASS) emit_event validation PASS "$scenario" "$row_path" "$reason" ;;
    SKIP|REFUSE) emit_event refusal "$outcome" "$scenario" "$row_path" "$reason" ;;
    INCIDENT|FAIL) emit_event incident "$outcome" "$scenario" "$row_path" "$reason" ;;
  esac
  emit_event rollback PASS "$scenario" "$row_dir/rollback-proof.json" "rollback proof recorded"
  emit_event cleanup PASS "$scenario" "$row_dir/cleanup-proof.json" "cleanup proof recorded"
  append_manifest_row "$scenario" "$outcome" "$row_path" "$reason"
}

run_live_backend() {
  local scenario="live-backend" row_dir backend_dir runner_rc outcome evidence_mode tuple_status btf kvm sched_ext marker_present marker_required reason row_path shape live_audit_id live_rollback_id
  row_dir="$out_dir/rows/live-backend"
  backend_dir="$row_dir/backend"
  mkdir -p "$row_dir"
  emit_event stage_started STARTED "$scenario" "$backend_dir" "delegating to qa/vm/vm_lab_backend.sh"
  set +e
  if [ "$fixture_mode" = true ]; then
    printf 'fixture mode refuses live backend delegation\n' > "$row_dir/backend-skipped.txt"
    runner_rc=99
  else
    timeout "$timeout_seconds" bash qa/vm/vm_lab_backend.sh --mode "$mode" --out "$backend_dir" > "$row_dir/backend.stdout.txt" 2> "$row_dir/backend.stderr.txt"
    runner_rc=$?
  fi
  set -e
  if [ "$runner_rc" -eq 0 ] && shape="$(live_backend_pass_shape "$backend_dir/summary.json")"; then
    read -r outcome evidence_mode tuple_status btf kvm sched_ext marker_present marker_required reason live_audit_id live_rollback_id <<< "$shape"
  elif [ "$runner_rc" -eq 124 ]; then
    outcome=INCIDENT; evidence_mode=host-refusal-only; tuple_status=unknown; btf=unknown; kvm=unknown; sched_ext=unknown; marker_present=false; marker_required=false; reason="live backend timeout"
    final_rc=1
  else
    outcome=REFUSE; evidence_mode=host-refusal-only; tuple_status=unknown; btf=unknown; kvm=unknown; sched_ext=unknown; marker_present=false; marker_required=false; reason="$(live_backend_refusal_reason "$backend_dir/summary.json")"
    [ "$mode" = vm-required ] && final_rc=1
  fi
  outcome="$(LIVE_AUDIT_ID="${live_audit_id:-}" LIVE_ROLLBACK_ID="${live_rollback_id:-}" write_matrix_row "$scenario" "$row_dir" "$outcome" "$evidence_mode" "$tuple_status" "$btf" "$kvm" "$sched_ext" "$marker_present" "$marker_required" "$reason" "$fixture_mode")"
  overlay_live_backend_artifacts "$row_dir" "$backend_dir/summary.json"
  row_path="$row_dir/matrix-run.json"
  emit_event validation "$outcome" "$scenario" "$row_path" "$reason"
  emit_event rollback PASS "$scenario" "$row_dir/rollback-proof.json" "rollback proof recorded"
  emit_event cleanup PASS "$scenario" "$row_dir/cleanup-proof.json" "cleanup proof recorded"
  append_manifest_row "$scenario" "$outcome" "$row_path" "$reason"
}

select_suite_scenarios
validate_selected_scenarios
validate_forced_missing_workload_tool_selection
initialize_run_dir

for scenario in "${scenarios[@]}"; do
  if [ "$scenario" = live-backend ]; then
    run_live_backend
  elif is_workload_scenario "$scenario" && [ "$mode" = vm-required ]; then
    run_live_workload "$scenario"
  else
    run_fixture_scenario "$scenario"
  fi
done

ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MANIFEST_ROWS="$manifest_rows" MANIFEST="$out_dir/manifest.json" RUN_ID="$run_id" MODE="$mode" FIXTURE_MODE="$manifest_fixture_mode" STARTED_AT="$started_at" ENDED_AT="$ended_at" EVENT_FILE="$event_file" OUT_DIR="$out_dir" python3 "$emit_helper" manifest

printf 'matrix_manifest=%s\ndaemon_events=%s\nhost_mutation=false\n' "$out_dir/manifest.json" "$event_file"
exit "$final_rc"
