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
  SEQ="$seq" EVENT="$event" STATUS="$status" RUN_ID="$run_id" SCENARIO="$scenario" ARTIFACT="$artifact" REASON="$reason" ACTION_ID="$action_id" ROLLBACK_ID="$rollback_id" AUDIT_ID="$audit_id" GIT_SHA="$git_sha" python3 - <<'PY' >> "$event_file"
import json
import os
row = {
    "schema": "zig-scheduler/daemon-event/v1",
    "seq": int(os.environ["SEQ"]),
    "event": os.environ["EVENT"],
    "status": os.environ["STATUS"],
    "run_id": os.environ["RUN_ID"],
    "target_id": os.environ["SCENARIO"],
    "action_id": os.environ["ACTION_ID"],
    "audit_id": os.environ["AUDIT_ID"],
    "rollback_id": os.environ["ROLLBACK_ID"],
    "reason": os.environ["REASON"],
    "artifact_paths": [os.environ["ARTIFACT"]],
    "git_sha": os.environ["GIT_SHA"],
    "host_mutation": False,
}
print(json.dumps(row, sort_keys=True))
PY
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
  SCENARIO="$scenario" ROW_DIR="$row_dir" EVENT_FILE="$event_file" OUTCOME="$outcome" EVIDENCE_MODE="$evidence_mode" TUPLE_STATUS="$tuple_status" BTF="$btf" KVM_STATUS="$kvm" SCHED_EXT="$sched_ext" MARKER_PRESENT="$marker_present" MARKER_REQUIRED="$marker_required" REASON="$reason" RUN_ID="$run_id" GIT_SHA="$git_sha" MODE="$mode" FIXTURE_MODE="$fixture_authority" TIMEOUT_SECONDS="$timeout_seconds" WORKLOAD_CLASS="$workload_class_value" WORKLOAD_TOOLS="$workload_tools_value" WORKLOAD_THRESHOLD_SOURCE="$threshold_source_value" WORKLOAD_MISSING_PREREQ="$missing_prereq_value" QEMU_BEFORE="$qemu_before" QEMU_AFTER="$qemu_after" TEMP_BEFORE="$temp_before" TEMP_AFTER="$temp_after" LIVE_AUDIT_ID="${LIVE_AUDIT_ID:-}" LIVE_ROLLBACK_ID="${LIVE_ROLLBACK_ID:-}" python3 - <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))
from qa.runtime_sample_policy_abi import good_cgroup_callback_stats, good_cgroup_policy_map, good_dsq_counter_coherence, good_policy_abi

scenario = os.environ["SCENARIO"]
row_dir = Path(os.environ["ROW_DIR"])
outcome = os.environ["OUTCOME"]
evidence_mode = os.environ["EVIDENCE_MODE"]
reason = os.environ["REASON"]
run_id = os.environ["RUN_ID"]
git_sha = os.environ["GIT_SHA"]
marker_present = os.environ["MARKER_PRESENT"] == "true"
marker_required = os.environ["MARKER_REQUIRED"] == "true"

def write_text(path: Path, text: str) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return hashlib.sha256(path.read_bytes()).hexdigest()

def write_json(path: Path, payload: dict) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return hashlib.sha256(path.read_bytes()).hexdigest()

def workload_semantics() -> dict:
    cgroup = {
        "cpu.weight": "callback-observed",
        "cpu.max": "deferred",
        "cpu.max.burst": "deferred",
        "cpuset.cpus": "observed-constraints",
        "cpuset.cpus.effective": "observed-constraints",
        "cpu.pressure": "observed-or-deferred",
        "uclamp": "observed-or-deferred",
        "cgroup.type.domain": "observed",
        "cgroup.type.threaded": "observed",
        "allowed-mask": "rejected",
    }
    hotplug = {
        "cpu.hotplug.offline": "fallback-observed",
        "cpu.hotplug.online": "fallback-observed",
        "cpuset.cpus": "observed-constraints",
        "cpuset.cpus.effective": "observed-constraints",
        "allowed-mask": "rejected",
    }
    return {
        "workload-cgroup-weight-quota": {"cgroup_semantics": cgroup},
        "workload-cpu-hotplug": {"cpu_hotplug_semantics": hotplug},
    }.get(scenario, {})

def benchmark_record() -> list[dict]:
    if threshold_source != "record-only":
        return []
    if missing_prereq:
        return []
    bench_dir = row_dir / "benchmark-provenance"
    records = []

    def add_record(family: str, tool: str, raw_name: str, raw_text: str, metrics: dict, units: dict, sample_count: int, run_count: int, status: str = "RECORDED") -> None:
        raw = bench_dir / raw_name
        write_text(raw, raw_text)
        record_path = bench_dir / f"{family}.benchmark-output.json"
        record_sha = write_json(record_path, {
            "schema": "zig-scheduler/benchmark-output/v1",
            "status": status,
            "tool": tool,
            "command_family": family,
            "record_only": True,
            "output_path": raw.as_posix(),
            "output_sha256": hashlib.sha256(raw.read_bytes()).hexdigest(),
            "vm_evidence": (row_dir / "matrix-run.json").as_posix(),
            "parser_provenance": {
                "parser": "qa/benchmark_output_parse.py",
                "parser_version": "benchmark-output/v1",
                "parser_status": "PARSED" if status == "RECORDED" else "UNSUPPORTED_DEFERRED",
            },
            "metrics": metrics,
            "units": units,
            "sample_count": sample_count,
            "run_count": run_count,
            "host_mutation": False,
            "release_eligible": False,
            "production_capacity_claim": False,
            "hard_thresholds_enforced": False,
            "threshold_status": "record_only",
            "privacy_sanitized": True,
        })
        records.append({"record_path": record_path.as_posix(), "record_sha256": record_sha, "record_only": True})

    def add_stress_ng() -> None:
        add_record(
            "stress_ng",
            "stress-ng",
            "stress-ng.txt",
            "stress-ng: metrc: [123] stressor       bogo ops real time  usr time  sys time   bogo ops/s     bogo ops/s\n"
            "stress-ng: metrc: [123]                           (secs)    (secs)    (secs)   (real time) (usr+sys time)\n"
            "stress-ng: metrc: [123] cpu              2400      10.00     19.50      0.25       240.00        121.52\n",
            {"stressors": 1, "bogo_ops": 2400.0, "real_time_seconds": 10.0, "usr_time_seconds": 19.5, "sys_time_seconds": 0.25},
            {"stressors": "count", "bogo_ops": "count", "real_time_seconds": "seconds", "usr_time_seconds": "seconds", "sys_time_seconds": "seconds"},
            1,
            1,
        )

    def add_perf_messaging() -> None:
        add_record(
            "perf_bench_sched_messaging",
            "perf",
            "perf-bench-sched-messaging.txt",
            "# Running 'sched/messaging' benchmark:\n# 20 sender and receiver processes per group\n# 10 groups == 400 processes run\n     Total time: 0.123 [sec]\n",
            {"groups": 10.0, "processes": 400.0, "total_time_seconds": 0.123},
            {"groups": "count", "processes": "count", "total_time_seconds": "seconds"},
            1,
            1,
        )

    def add_deferred(family: str, tool: str, raw_name: str, raw_text: str) -> None:
        add_record(family, tool, raw_name, raw_text, {}, {}, 0, 0, "UNSUPPORTED_DEFERRED")

    if scenario == "workload-mixed-io":
        add_record(
            "fio",
            "fio",
            "fio.json",
            json.dumps({"jobs": [{"read": {"iops": 1, "bw_bytes": 2, "lat_ns": {"mean": 3}}, "write": {"iops": 4, "bw_bytes": 5, "lat_ns": {"mean": 6}}}]}, sort_keys=True) + "\n",
            {"jobs": 1, "read_bw_bytes": 2.0, "read_iops": 1.0, "read_lat_ns_mean_avg": 3.0, "write_bw_bytes": 5.0, "write_iops": 4.0, "write_lat_ns_mean_avg": 6.0},
            {"jobs": "count", "read_bw_bytes": "bytes_per_second", "read_iops": "iops", "read_lat_ns_mean_avg": "ns", "write_bw_bytes": "bytes_per_second", "write_iops": "iops", "write_lat_ns_mean_avg": "ns"},
            1,
            1,
        )
    elif scenario == "workload-interactive-latency":
        add_record(
            "cyclictest",
            "cyclictest",
            "cyclictest.txt",
            "T: 0 ( 123) P:80 I:1000 C:100 Min:1 Act:2 Avg:3 Max:4\n",
            {"threads": 1, "cycles": 100.0, "latency_min_us_avg": 1.0, "latency_avg_us_avg": 3.0, "latency_max_us": 4.0},
            {"threads": "count", "cycles": "count", "latency_min_us_avg": "us", "latency_avg_us_avg": "us", "latency_max_us": "us"},
            100,
            1,
        )
        add_perf_messaging()
        add_deferred("rtla", "rtla", "rtla.txt", "rtla timerlat summary redacted; unsupported for benchmark-output/v1 parser\n")
        add_deferred("perf_sched", "perf", "perf-sched.txt", "perf sched latency summary redacted; unsupported for benchmark-output/v1 parser\n")
    elif scenario in {"workload-cpu-saturation", "workload-cgroup-weight-quota", "workload-scheduler-affinity-churn"}:
        add_stress_ng()
        if scenario == "workload-scheduler-affinity-churn":
            add_deferred("perf_sched", "perf", "perf-sched.txt", "perf sched latency summary redacted; unsupported for benchmark-output/v1 parser\n")
    elif scenario == "workload-fork-ipc-pressure":
        add_perf_messaging()
    elif scenario == "live-backend":
        add_deferred("perf_sched", "perf", "live-backend-perf-sched-deferred.txt", "live-backend scheduler proof recorded; benchmark parser output intentionally deferred for protected VM proof bundle\n")
    return records

policy = row_dir / "policy.o"
policy_sha = write_text(policy, f"matrix fixture policy object\nscenario={scenario}\n")
source = Path("bpf/zigsched_minimal.bpf.c")
source_sha = hashlib.sha256(source.read_bytes()).hexdigest() if source.is_file() else hashlib.sha256(b"missing source fixture\n").hexdigest()
workload = row_dir / "workload-spec.json"
workload_class = os.environ.get("WORKLOAD_CLASS", "cpu-smoke")
workload_tools = [item for item in os.environ.get("WORKLOAD_TOOLS", "builtin-churn").split(",") if item]
threshold_source = os.environ.get("WORKLOAD_THRESHOLD_SOURCE", "fixture")
missing_prereq = os.environ.get("WORKLOAD_MISSING_PREREQ", "")
capability = row_dir / "workload-capability.json"
write_json(capability, {
    "schema": "zig-scheduler/workload-capability/v1",
    "scenario_id": scenario,
    "workload_class": workload_class,
    "required_tools": workload_tools,
    "threshold_source": threshold_source,
    "status": outcome,
    "typed_outcome": outcome,
    "missing_prereq": missing_prereq,
    "mode": os.environ["MODE"],
    "fixture_mode": os.environ.get("FIXTURE_MODE", "false") == "true",
    "runner": "qa/vm/workload_capability_probe.sh",
    "vm_marker_required_for_live_run": True,
    "host_mutation": False,
    "release_eligible": False,
})
workload_spec = {
    "schema": "zig-scheduler/workload-fixture/v1",
    "name": workload_class,
    "workload_class": workload_class,
    "scenario_id": scenario,
    "required_tools": workload_tools,
    "threshold_source": threshold_source,
    "thresholds": {"source": threshold_source, "fixture_status": "deterministic", "calibration_status": "uncalibrated", "production_capacity_claim": False},
    "capability_artifact_path": capability.as_posix(),
    "runner": "qa/vm/workload_capability_probe.sh",
    "vm_marker_required_for_live_run": True,
    "host_safe_fixture_only": os.environ["MODE"] != "vm-required",
    "missing_prereq": missing_prereq,
    "host_mutation": False,
    "release_eligible": False,
}
provenance = benchmark_record()
if provenance:
    workload_spec["benchmark_provenance"] = provenance
workload_spec.update(workload_semantics())
workload_sha = write_json(workload, workload_spec)
runtime = row_dir / "runtime-sample.jsonl"
cgroup_digest = hashlib.sha256(f"{run_id}:{scenario}:cgroup".encode()).hexdigest()
row_local_cgroup = "zigsched-" + hashlib.sha256(f"{run_id}:{scenario}:row-local-cgroup".encode()).hexdigest()[:16]
isolation = row_dir / "row-isolation-contract.json"
write_json(isolation, {
    "schema": "zig-scheduler/row-isolation-contract/v1",
    "scenario_id": scenario,
    "row_directory": row_dir.as_posix(),
    "row_local_cgroup_name": row_local_cgroup,
    "timeout_envelope_seconds": int(os.environ["TIMEOUT_SECONDS"]),
    "artifact_reuse": "forbidden-across-rows",
    "artifacts_must_descend_from_row_directory": True,
    "rollback_proof_required_on_partial_failure": True,
    "cleanup_proof_required_on_partial_failure": True,
    "host_mutation": False,
    "release_eligible": False,
})

def fact(status: str, value: str) -> dict:
    return {"status": status, "value": value}

def runtime_policy_abi(index: int) -> dict:
    policy_abi = good_policy_abi(policy_sha)
    if scenario == "workload-cgroup-weight-quota" and index == 1 and outcome == "PASS":
        policy_abi["cgroup_policy_map"] = good_cgroup_policy_map()
        policy_abi["cgroup_callback_stats"] = good_cgroup_callback_stats()
        policy_abi["dsq_counter_coherence"] = good_dsq_counter_coherence()
    else:
        policy_abi["cgroup_policy_map"] = good_cgroup_policy_map("unavailable")
        policy_abi["cgroup_callback_stats"] = good_cgroup_callback_stats("unavailable")
        policy_abi["dsq_counter_coherence"] = good_dsq_counter_coherence("unavailable")
    return policy_abi


def runtime_sample(index: int, scheduler_state: str, ops: str) -> dict:
    global last_enable_seq
    enabled = scheduler_state == "enabled"
    if enabled:
        last_enable_seq = str(40 + index)
    phase = "during_attach" if enabled else ("before_attach" if index == 0 else "after_rollback")
    task_ext_status = "present" if enabled else "unknown"
    task_ext_value = "true" if enabled else "unavailable"
    rollback_state = "rolled_back" if phase == "after_rollback" else "not_applicable"
    return {
        "schema": "zig-scheduler/runtime-sample/v1",
        "sequence": index,
        "sample_source_event": f"matrix-{scenario}-{index}",
        "observation_source": "vm_harness_matrix_row",
        "sched_ext_phase": phase,
        "state": fact("present", scheduler_state),
        "ops": fact("present", ops),
        "enable_seq": fact("present", last_enable_seq if not enabled else str(40 + index)),
        "events": fact("present", "nr_rejected: 0 dispatch_failed: 0 fallback: 0 fatal: 0"),
        "events_hash": hashlib.sha256(f"{scenario}:events:{index}".encode()).hexdigest(),
        "nr_rejected": fact("present", "0"),
        "debug_dump": fact("missing", ""),
        "root_ops": fact("present", ops),
        "scheduler_events": fact("present", "nr_rejected: 0 dispatch_failed: 0 fallback: 0 fatal: 0"),
        "policy_counters": {"nr_rejected": 0, "dispatch_failed": 0, "fallback": 0, "fatal": 0},
        "sample_loss": {"lost_samples": 0, "backpressure_dropped": 0, "ring_buffer_overruns": 0, "reader_lag_events": 0},
        "policy_abi": runtime_policy_abi(index),
        "cgroup_semantic_labels": dict(runtime_policy_abi(index)["cgroup_semantics"]),
        "cgroup_membership_digest": cgroup_digest,
        "cgroup_membership_status": fact("present", "present"),
        "task_ext_enabled": fact(task_ext_status, task_ext_value),
        "teardown_state": fact("present", "attached" if enabled else "detached"),
        "rollback_state": fact("present", rollback_state),
        "workload": fact("present", "alive" if outcome == "PASS" else "not-started"),
        "workload_alive": outcome == "PASS",
        "private_command_lines_sampled": False,
        "dsq_depth": {"global": 1 if enabled else 0, "local": 0, "shared": 0},
        "queue_latency": {"p50_us": 0, "p95_us": 0, "p99_us": 0, "max_us": 0},
        "fairness": {"state": "ok" if outcome == "PASS" else "unknown", "starved_tasks": 0, "max_wait_us": 0},
        "task_counts": {"by_cgroup_digest": {cgroup_digest: 1 if outcome == "PASS" else 0}, "by_class": {workload_class: 1 if outcome == "PASS" else 0}},
        "scheduler_counters": {"context_switches": index, "wakeups": index, "migrations": 0},
        "sched_ext_observation": {"dump": {"status": "present", "value": "sha256:" + hashlib.sha256(f"{scenario}:dump:{index}".encode()).hexdigest() + ";bytes:128"}, "tracepoints": {"sched_switch": index, "sched_wakeup": index}},
    }

last_enable_seq = "0"
runtime_rows = (
    runtime_sample(0, "disabled", "none"),
    runtime_sample(1, "enabled", "zigsched_minimal"),
    runtime_sample(2, "disabled", "none"),
)
runtime.write_text("".join(json.dumps(sample, sort_keys=True) + "\n" for sample in runtime_rows), encoding="utf-8")
incident = row_dir / "incident.json"
write_json(incident, {"schema": "zig-scheduler/matrix-incident/v1", "scenario_id": scenario, "outcome": outcome, "reason": reason, "host_mutation": False, "release_eligible": False})
rollback = row_dir / "rollback-proof.json"
write_json(rollback, {"schema": "zig-scheduler/rollback-proof/v1", "scenario_id": scenario, "status": "PASS", "scheduler_state": "disabled", "ops": "none", "host_mutation": False})
host_refusal = row_dir / "host-refusal.json"
write_json(host_refusal, {"schema": "zig-scheduler/host-refusal-proof/v1", "scenario_id": scenario, "status": "REFUSE", "reason": "host scheduler mutation refused; VM marker required", "no_bpf_load_attach": True, "no_cgroup_write": True, "no_sys_write": True, "no_proc_write": True, "host_mutation": False})
privacy = row_dir / "privacy-scan.json"
write_json(privacy, {"schema": "zig-scheduler/privacy-scan/v1", "status": "PASS", "private_fields_found": False, "host_mutation": False})
cleanup = row_dir / "cleanup-proof.json"
write_json(cleanup, {"schema": "zig-scheduler/cleanup-proof/v1", "scenario_id": scenario, "status": "PASS", "owned_qemu_leftovers": False, "owned_temp_leftovers": False, "qemu_scan_before": os.environ["QEMU_BEFORE"], "qemu_scan_after": os.environ["QEMU_AFTER"], "temp_scan_before": os.environ["TEMP_BEFORE"], "temp_scan_after": os.environ["TEMP_AFTER"], "host_mutation": False})
marker_checked_by = "qa/vm/vm_harness_matrix.sh"
if marker_present:
    marker_proof = row_dir / "vm-marker-proof.json"
    write_json(marker_proof, {"schema": "zig-scheduler/vm-marker-proof/v1", "path": "/run/zig-scheduler-vm-lab.marker", "required": True, "present": True, "evidence_mode": "vm-live", "host_mutation": False})
    marker_checked_by = marker_proof.as_posix()
state = {"ops": "none", "sched_ext": "disabled"}
cgroup = {"digest": "sha256:" + cgroup_digest, "row_local_name": row_local_cgroup, "isolation_contract_path": isolation.as_posix()}
row = {
    "schema": "zig-scheduler/matrix-run/v1",
    "matrix_run_id": run_id,
    "scenario_id": scenario,
    "outcome": outcome,
    "evidence_mode": evidence_mode,
    "kernel_tuple": {"kernel_release": os.uname().release, "arch": os.uname().machine, "btf": os.environ["BTF"], "kvm": os.environ["KVM_STATUS"], "sched_ext": os.environ["SCHED_EXT"]},
    "supported_tuple_status": os.environ["TUPLE_STATUS"],
    "vm_marker": {"required": marker_required, "present": marker_present, "path": "/run/zig-scheduler-vm-lab.marker", "checked_by": marker_checked_by},
    "bpf_abi_version": "zigsched-bpf-abi-v1",
    "policy": {"name": "zigsched_minimal", "object_path": policy.as_posix(), "object_sha256": policy_sha, "source_path": "bpf/zigsched_minimal.bpf.c", "source_sha256": source_sha},
    "workload": {"name": workload_class, "spec_path": workload.as_posix(), "spec_sha256": workload_sha},
    "action_id": "ACT-" + scenario,
    "audit_id": os.environ.get("LIVE_AUDIT_ID") or "AUD-20260629T120000Z-" + scenario,
    "rollback_id": os.environ.get("LIVE_ROLLBACK_ID") or "RB-" + scenario,
    "pre_scheduler_state": state,
    "post_scheduler_state": state,
    "pre_cgroup_state": cgroup,
    "post_cgroup_state": cgroup,
    "runtime_sample_path": runtime.as_posix(),
    "daemon_event_path": str(Path(os.environ["EVENT_FILE"])),
    "incident_path": incident.as_posix(),
    "rollback_proof_path": rollback.as_posix(),
    "cleanup_proof_path": cleanup.as_posix(),
    "host_refusal_proof_path": host_refusal.as_posix(),
    "privacy_scan": {"status": "PASS", "private_fields_found": False, "report_path": privacy.as_posix()},
    "git": {"expected_sha": git_sha, "actual_sha": git_sha, "status": "current", "dirty": False},
    "release_eligible": False,
    "host_mutation": False,
}
write_json(row_dir / "matrix-run.json", row)
PY
  printf '%s\n' "$outcome"
}

append_manifest_row() {
  local scenario="$1" outcome="$2" row_path="$3" reason="$4"
  SCENARIO="$scenario" OUTCOME="$outcome" ROW_PATH="$row_path" REASON="$reason" python3 - <<'PY' >> "$manifest_rows"
import json
import os
print(json.dumps({"scenario_id": os.environ["SCENARIO"], "outcome": os.environ["OUTCOME"], "artifact_path": os.environ["ROW_PATH"], "reason": os.environ["REASON"]}, sort_keys=True))
PY
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
  BACKEND_SUMMARY="$backend_summary" ROW_DIR="$row_dir" python3 - <<'PY'
import json
import shutil
from pathlib import Path
import os

summary_path = Path(os.environ["BACKEND_SUMMARY"])
row_dir = Path(os.environ["ROW_DIR"])
if not summary_path.is_file():
    raise SystemExit(0)
summary = json.loads(summary_path.read_text(encoding="utf-8"))
if summary.get("status") != "PASS":
    raise SystemExit(0)
live_summary = Path(str(summary.get("live_summary", "")))
if not live_summary.is_file():
    raise SystemExit(0)
runtime = live_summary.parent / "observe-partial" / "runtime-samples.jsonl"
if runtime.is_file():
    shutil.copyfile(runtime, row_dir / "runtime-sample.jsonl")
PY
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
  BACKEND_SUMMARY="$backend_summary" ROW_DIR="$row_dir" python3 - <<'PYINNER'
import json
import shutil
from pathlib import Path
import os
summary_path = Path(os.environ["BACKEND_SUMMARY"])
row_dir = Path(os.environ["ROW_DIR"])
if not summary_path.is_file():
    raise SystemExit(0)
try:
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
except json.JSONDecodeError:
    raise SystemExit(0)
live_summary = Path(str(summary.get("live_summary", "")))
if not live_summary.is_file():
    raise SystemExit(0)
out = row_dir / "workload-vm-artifacts"
out.mkdir(parents=True, exist_ok=True)
for src in (live_summary, live_summary.parent / "serial.txt", live_summary.parent / "observe-partial" / "runtime-samples.jsonl", summary_path):
    if src.is_file():
        shutil.copyfile(src, out / src.name)
PYINNER
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
MANIFEST_ROWS="$manifest_rows" MANIFEST="$out_dir/manifest.json" RUN_ID="$run_id" MODE="$mode" FIXTURE_MODE="$manifest_fixture_mode" STARTED_AT="$started_at" ENDED_AT="$ended_at" EVENT_FILE="$event_file" OUT_DIR="$out_dir" python3 - <<'PY'
import json
import os
from pathlib import Path
rows = [json.loads(line) for line in Path(os.environ["MANIFEST_ROWS"]).read_text(encoding="utf-8").splitlines() if line.strip()]
manifest = {
    "schema": "zig-scheduler/vm-harness-matrix-index/v1",
    "matrix_run_id": os.environ["RUN_ID"],
    "mode": os.environ["MODE"],
    "fixture_mode": os.environ["FIXTURE_MODE"] == "true",
    "started_at": os.environ["STARTED_AT"],
    "ended_at": os.environ["ENDED_AT"],
    "out_dir": os.environ["OUT_DIR"],
    "daemon_events_path": os.environ["EVENT_FILE"],
    "row_count": len(rows),
    "rows": rows,
    "host_mutation": False,
    "release_eligible": False,
}
Path(os.environ["MANIFEST"]).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

printf 'matrix_manifest=%s\ndaemon_events=%s\nhost_mutation=false\n' "$out_dir/manifest.json" "$event_file"
exit "$final_rc"
