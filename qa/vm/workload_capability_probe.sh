#!/usr/bin/env bash
# Host-safe workload capability discovery. It only checks prerequisites and
# writes JSON; live workload execution is VM-only and guarded by the matrix
# runner plus /run/zig-scheduler-vm-lab.marker.
set -euo pipefail

mode="host-safe"
scenario=""
out_file=""

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
usage: qa/vm/workload_capability_probe.sh --scenario <workload-id> [--mode host-safe|auto|vm-required] [--out <relative-json>]

Emits zig-scheduler/workload-capability/v1 JSON. This is a read-only
capability/prerequisite probe; it does not run stressors, write cgroups,
change affinity, offline CPUs, load BPF, or attach sched_ext on the host.
Set ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL=<tool> to exercise typed SKIP/REFUSE.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --scenario) [ "$#" -ge 2 ] || fail '--scenario requires a value'; scenario="$2"; shift 2 ;;
    --mode) [ "$#" -ge 2 ] || fail '--mode requires a value'; mode="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail '--out requires a value'; out_file="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$mode" in host-safe|auto|vm-required) ;; *) fail '--mode must be host-safe, auto, or vm-required' ;; esac
case "$scenario$out_file" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
[ -n "$scenario" ] || fail '--scenario is required'
case "$scenario" in *[!A-Za-z0-9_.-]*|'') fail "unsafe scenario id: $scenario" ;; esac
if [ -n "$out_file" ]; then
  case "$out_file" in /*|../*|*'/../'*|*/..|*$'\n'*|*$'\r'*) fail '--out must be relative and non-traversing' ;; esac
  case "$out_file" in evidence/lab/*) ;; *) fail '--out must stay under evidence/lab/' ;; esac
fi

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

threshold_source() {
  case "$1" in
    workload-cpu-saturation|workload-scheduler-affinity-churn|workload-fork-ipc-pressure) printf 'fixture' ;;
    workload-interactive-latency|workload-mixed-io|workload-cgroup-weight-quota) printf 'calibrated' ;;
    workload-cpu-hotplug) printf 'deferred' ;;
    *) return 1 ;;
  esac
}

command_available() { command -v "$1" >/dev/null 2>&1; }

validate_workload_tool_name() {
  case "$1" in
    stress-ng|cyclictest|perf|taskset|chrt|hackbench-like|fio|cpu-hotplug-online-control) return 0 ;;
    *) fail 'unsafe forced missing workload tool' ;;
  esac
}

validate_forced_missing_workload_tool_for_scenario() {
  local scenario_id="$1" tool="$2"
  case "$scenario_id:$tool" in
    workload-cpu-saturation:stress-ng) return 0 ;;
    workload-interactive-latency:cyclictest|workload-interactive-latency:perf) return 0 ;;
    workload-scheduler-affinity-churn:stress-ng|workload-scheduler-affinity-churn:taskset|workload-scheduler-affinity-churn:chrt) return 0 ;;
    workload-fork-ipc-pressure:hackbench-like) return 0 ;;
    workload-mixed-io:fio) return 0 ;;
    workload-cgroup-weight-quota:stress-ng) return 0 ;;
    workload-cpu-hotplug:cpu-hotplug-online-control) return 0 ;;
    *) fail "forced missing workload tool $tool is not required by scenario $scenario_id" ;;
  esac
}

if [ -n "${ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL:-}" ]; then
  validate_workload_tool_name "$ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL"
fi

missing_prereq() {
  local forced="${ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL:-}"
  if [ -n "$forced" ]; then validate_workload_tool_name "$forced"; printf '%s' "$forced"; return 0; fi
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

class="$(workload_class "$scenario")" || fail "unknown workload scenario: $scenario"
tools="$(workload_tools "$scenario")"
source_kind="$(threshold_source "$scenario")"
if [ -n "${ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL:-}" ]; then
  validate_forced_missing_workload_tool_for_scenario "$scenario" "$ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL"
fi
missing=""
status="PASS"
outcome="PASS"
if missing="$(missing_prereq)"; then
  if [ "$mode" = vm-required ]; then outcome="REFUSE"; else outcome="SKIP"; fi
  status="$outcome"
else
  missing=""
fi

json_payload="$({ SCENARIO="$scenario" CLASS="$class" TOOLS="$tools" SOURCE_KIND="$source_kind" MODE="$mode" STATUS="$status" OUTCOME="$outcome" MISSING="$missing" python3 - <<'PY'
import json
import os
payload = {
    "schema": "zig-scheduler/workload-capability/v1",
    "scenario_id": os.environ["SCENARIO"],
    "workload_class": os.environ["CLASS"],
    "required_tools": [item for item in os.environ["TOOLS"].split(",") if item],
    "threshold_source": os.environ["SOURCE_KIND"],
    "mode": os.environ["MODE"],
    "status": os.environ["STATUS"],
    "typed_outcome": os.environ["OUTCOME"],
    "missing_prereq": os.environ["MISSING"],
    "vm_marker_required_for_live_run": True,
    "host_mutation": False,
    "release_eligible": False,
}
print(json.dumps(payload, indent=2, sort_keys=True))
PY
})"

if [ -n "$out_file" ]; then
  mkdir -p "$(dirname -- "$out_file")"
  printf '%s\n' "$json_payload" > "$out_file"
  printf 'capability=%s\nstatus=%s\nhost_mutation=false\n' "$out_file" "$status"
else
  printf '%s\n' "$json_payload"
fi
