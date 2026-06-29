#!/usr/bin/env bash
set -euo pipefail

doc="docs/runbooks/vm-lab.md"
runner="qa/vm/vm_harness_matrix.sh"
probe="qa/vm/workload_capability_probe.sh"
scenarios=(
  workload-cpu-saturation
  workload-interactive-latency
  workload-scheduler-affinity-churn
  workload-fork-ipc-pressure
  workload-mixed-io
  workload-cgroup-weight-quota
  workload-cpu-hotplug
)
for path in "$doc" "$runner" "$probe"; do
  [ -s "$path" ] || { printf 'FAIL workload catalog: missing %s\n' "$path" >&2; exit 1; }
done
for scenario in "${scenarios[@]}"; do
  grep -q "$scenario" "$doc" || { printf 'FAIL workload catalog: doc missing %s\n' "$scenario" >&2; exit 1; }
  grep -q "$scenario" "$runner" || { printf 'FAIL workload catalog: matrix runner missing %s\n' "$scenario" >&2; exit 1; }
  grep -q "$scenario" "$probe" || { printf 'FAIL workload catalog: probe missing %s\n' "$scenario" >&2; exit 1; }
done
for needle in stress-ng perf cyclictest fio hackbench-like cpu-hotplug-online-control fixture calibrated deferred SKIP REFUSE privacy; do
  grep -qi "$needle" "$doc" || { printf 'FAIL workload catalog: doc missing %s\n' "$needle" >&2; exit 1; }
done
python3 - <<'PY'
import hashlib
import json
import re
from pathlib import Path

expected = {
    "workload-cpu-saturation": ("cpu-saturation", ("stress-ng",), "fixture"),
    "workload-interactive-latency": ("interactive-latency", ("cyclictest", "perf"), "calibrated"),
    "workload-scheduler-affinity-churn": ("scheduler-affinity-churn", ("stress-ng", "taskset", "chrt"), "fixture"),
    "workload-fork-ipc-pressure": ("bounded-fork-ipc-pressure", ("hackbench-like",), "fixture"),
    "workload-mixed-io": ("mixed-io", ("fio",), "calibrated"),
    "workload-cgroup-weight-quota": ("cgroup-weight-quota-pressure", ("stress-ng",), "calibrated"),
    "workload-cpu-hotplug": ("cpu-hotplug-offline", ("cpu-hotplug-online-control",), "deferred"),
}
allowed_spec_fields = {
    "schema",
    "scenario_id",
    "workload_class",
    "required_tools",
    "threshold_source",
    "thresholds",
    "vm_marker_required_for_live_run",
    "host_mutation",
    "release_eligible",
}
allowed_threshold_fields = {"source", "fixture_status", "calibration_status", "production_capacity_claim"}
private_needles = ("cmdline", "command_line", "argv", "environment", "env", "secret", "api_key", "token", "password", "authorization", "bearer")
private_path = re.compile(r"(^|[\s=:])/(?:home|root|etc|proc|sys|var|tmp)/")

def fail(message: str) -> None:
    raise SystemExit(f"FAIL workload catalog: {message}")

def load_object(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON in {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path} must be a JSON object")
    return value

def reject_private(value, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if any(needle in lowered for needle in private_needles):
                fail(f"privacy-unsafe key in {context}.{key}")
            reject_private(child, f"{context}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_private(child, f"{context}[{index}]")
    elif isinstance(value, str):
        lowered = value.lower()
        if any(needle in lowered for needle in private_needles) or private_path.search(value):
            fail(f"privacy-unsafe text in {context}")

for scenario, (workload_class, tools, threshold_source) in expected.items():
    spec_path = Path("fixtures/matrix-run/workload-specs") / f"{scenario}.json"
    row_path = Path("fixtures/matrix-run") / f"{scenario}.json"
    spec = load_object(spec_path)
    reject_private(spec, str(spec_path))
    extra = sorted(set(spec) - allowed_spec_fields)
    if extra:
        fail(f"{spec_path} has unexpected fields: {', '.join(extra)}")
    missing = sorted(allowed_spec_fields - set(spec))
    if missing:
        fail(f"{spec_path} missing fields: {', '.join(missing)}")
    if spec.get("schema") != "zig-scheduler/workload-fixture/v1":
        fail(f"{spec_path} has wrong schema")
    if spec.get("scenario_id") != scenario:
        fail(f"{spec_path} scenario_id mismatch")
    if spec.get("workload_class") != workload_class:
        fail(f"{spec_path} workload_class mismatch")
    if spec.get("required_tools") != list(tools):
        fail(f"{spec_path} required_tools mismatch")
    if spec.get("threshold_source") != threshold_source:
        fail(f"{spec_path} threshold_source mismatch")
    if spec.get("vm_marker_required_for_live_run") is not True:
        fail(f"{spec_path} must require VM marker for live runs")
    if spec.get("host_mutation") is not False or spec.get("release_eligible") is not False:
        fail(f"{spec_path} must be host_mutation=false and release_eligible=false")
    thresholds = spec.get("thresholds")
    if not isinstance(thresholds, dict):
        fail(f"{spec_path} thresholds must be an object")
    if set(thresholds) != allowed_threshold_fields:
        fail(f"{spec_path} thresholds fields mismatch")
    if thresholds.get("source") != threshold_source or thresholds.get("production_capacity_claim") is not False:
        fail(f"{spec_path} thresholds are unsafe")
    row = load_object(row_path)
    workload = row.get("workload")
    if not isinstance(workload, dict):
        fail(f"{row_path} workload must be an object")
    if workload.get("name") != workload_class or workload.get("spec_path") != spec_path.as_posix():
        fail(f"{row_path} workload metadata mismatch")
    digest = hashlib.sha256(spec_path.read_bytes()).hexdigest()
    if workload.get("spec_sha256") != digest:
        fail(f"{row_path} workload spec_sha256 mismatch")
PY
printf 'PASS workload catalog: scenarios=%s host_mutation=false\n' "${#scenarios[@]}"
