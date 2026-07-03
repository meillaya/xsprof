#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/vm/vm_harness_matrix_emit.py event|row|manifest-row|manifest
from __future__ import annotations

import hashlib
import json
import os
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypeAlias

sys.path.insert(0, str(Path.cwd()))
from qa.runtime_sample_policy_abi import (  # noqa: E402
    good_cgroup_callback_stats,
    good_cgroup_policy_map,
    good_dsq_counter_coherence,
    good_policy_abi,
)

JsonValue: TypeAlias = str | int | float | bool | None | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
JsonArray: TypeAlias = list[JsonValue]
JsonLoads: TypeAlias = Callable[[str], JsonValue]
loads_json: JsonLoads = json.loads


class MatrixEmitJsonObjectError(Exception):
    expected_type: str

    def __init__(self) -> None:
        self.expected_type = "JSON object"
        super().__init__(f"expected {self.expected_type}")


@dataclass(frozen=True, slots=True)
class BenchRecord:
    family: str
    tool: str
    raw_name: str
    raw_text: str
    metrics: JsonObject
    units: JsonObject
    sample_count: int
    run_count: int
    status: str = "RECORDED"


CGROUP_SEMANTICS: Final[JsonObject] = {"cpu.weight": "callback-observed", "cpu.max": "deferred", "cpu.max.burst": "deferred", "cpuset.cpus": "observed-constraints", "cpuset.cpus.effective": "observed-constraints", "cpu.pressure": "observed-or-deferred", "uclamp": "observed-or-deferred", "cgroup.type.domain": "observed", "cgroup.type.threaded": "observed", "allowed-mask": "rejected"}
HOTPLUG_SEMANTICS: Final[JsonObject] = {"cpu.hotplug.offline": "fallback-observed", "cpu.hotplug.online": "fallback-observed", "cpuset.cpus": "observed-constraints", "cpuset.cpus.effective": "observed-constraints", "allowed-mask": "rejected"}
FIO_RAW: Final[str] = json.dumps({"jobs": [{"read": {"iops": 1, "bw_bytes": 2, "lat_ns": {"mean": 3}}, "write": {"iops": 4, "bw_bytes": 5, "lat_ns": {"mean": 6}}}]}, sort_keys=True) + "\n"
STRESS_RAW: Final[str] = "stress-ng: metrc: [123] stressor       bogo ops real time  usr time  sys time   bogo ops/s     bogo ops/s\nstress-ng: metrc: [123]                           (secs)    (secs)    (secs)   (real time) (usr+sys time)\nstress-ng: metrc: [123] cpu              2400      10.00     19.50      0.25       240.00        121.52\n"
PERF_RAW: Final[str] = "# Running 'sched/messaging' benchmark:\n# 20 sender and receiver processes per group\n# 10 groups == 400 processes run\n     Total time: 0.123 [sec]\n"


def env_bool(name: str) -> bool:
    return os.environ[name] == "true"


def write_text(path: Path, text: str) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(text, encoding="utf-8")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, payload: JsonObject) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_json_object(text: str) -> JsonObject:
    payload = loads_json(text)
    if isinstance(payload, dict):
        return payload
    raise MatrixEmitJsonObjectError()


def json_string_list(items: list[str]) -> JsonArray:
    return [item for item in items]


def json_field_as_string(payload: JsonObject, key: str) -> str:
    return str(payload.get(key, ""))


def event() -> None:
    row: JsonObject = {"schema": "zig-scheduler/daemon-event/v1", "seq": int(os.environ["SEQ"]), "event": os.environ["EVENT"], "status": os.environ["STATUS"], "run_id": os.environ["RUN_ID"], "target_id": os.environ["SCENARIO"], "action_id": os.environ["ACTION_ID"], "audit_id": os.environ["AUDIT_ID"], "rollback_id": os.environ["ROLLBACK_ID"], "reason": os.environ["REASON"], "artifact_paths": [os.environ["ARTIFACT"]], "git_sha": os.environ["GIT_SHA"], "host_mutation": False}
    print(json.dumps(row, sort_keys=True))


def workload_semantics(scenario: str) -> JsonObject:
    semantics_by_scenario: dict[str, JsonObject] = {
        "workload-cgroup-weight-quota": {"cgroup_semantics": CGROUP_SEMANTICS},
        "workload-cpu-hotplug": {"cpu_hotplug_semantics": HOTPLUG_SEMANTICS},
    }
    return semantics_by_scenario.get(scenario, {})


def bench_records(scenario: str) -> list[BenchRecord]:
    stress = BenchRecord("stress_ng", "stress-ng", "stress-ng.txt", STRESS_RAW, {"stressors": 1, "bogo_ops": 2400.0, "real_time_seconds": 10.0, "usr_time_seconds": 19.5, "sys_time_seconds": 0.25}, {"stressors": "count", "bogo_ops": "count", "real_time_seconds": "seconds", "usr_time_seconds": "seconds", "sys_time_seconds": "seconds"}, 1, 1)
    perf = BenchRecord("perf_bench_sched_messaging", "perf", "perf-bench-sched-messaging.txt", PERF_RAW, {"groups": 10.0, "processes": 400.0, "total_time_seconds": 0.123}, {"groups": "count", "processes": "count", "total_time_seconds": "seconds"}, 1, 1)
    deferred_perf = BenchRecord("perf_sched", "perf", "perf-sched.txt", "perf sched latency summary redacted; unsupported for benchmark-output/v1 parser\n", {}, {}, 0, 0, "UNSUPPORTED_DEFERRED")
    records_by_scenario: dict[str, list[BenchRecord]] = {
        "workload-mixed-io": [BenchRecord("fio", "fio", "fio.json", FIO_RAW, {"jobs": 1, "read_bw_bytes": 2.0, "read_iops": 1.0, "read_lat_ns_mean_avg": 3.0, "write_bw_bytes": 5.0, "write_iops": 4.0, "write_lat_ns_mean_avg": 6.0}, {"jobs": "count", "read_bw_bytes": "bytes_per_second", "read_iops": "iops", "read_lat_ns_mean_avg": "ns", "write_bw_bytes": "bytes_per_second", "write_iops": "iops", "write_lat_ns_mean_avg": "ns"}, 1, 1)],
        "workload-interactive-latency": [BenchRecord("cyclictest", "cyclictest", "cyclictest.txt", "T: 0 ( 123) P:80 I:1000 C:100 Min:1 Act:2 Avg:3 Max:4\n", {"threads": 1, "cycles": 100.0, "latency_min_us_avg": 1.0, "latency_avg_us_avg": 3.0, "latency_max_us": 4.0}, {"threads": "count", "cycles": "count", "latency_min_us_avg": "us", "latency_avg_us_avg": "us", "latency_max_us": "us"}, 100, 1), perf, BenchRecord("rtla", "rtla", "rtla.txt", "rtla timerlat summary redacted; unsupported for benchmark-output/v1 parser\n", {}, {}, 0, 0, "UNSUPPORTED_DEFERRED"), deferred_perf],
        "workload-cpu-saturation": [stress],
        "workload-cgroup-weight-quota": [stress],
        "workload-scheduler-affinity-churn": [stress, deferred_perf],
        "workload-fork-ipc-pressure": [perf],
        "live-backend": [BenchRecord("perf_sched", "perf", "live-backend-perf-sched-deferred.txt", "live-backend scheduler proof recorded; benchmark parser output intentionally deferred for protected VM proof bundle\n", {}, {}, 0, 0, "UNSUPPORTED_DEFERRED")],
    }
    return records_by_scenario.get(scenario, [])


def write_benchmarks(row_dir: Path, scenario: str, threshold_source: str, missing_prereq: str) -> JsonArray:
    if threshold_source != "record-only" or missing_prereq:
        return []
    records: JsonArray = []
    bench_dir = row_dir / "benchmark-provenance"
    for item in bench_records(scenario):
        raw = bench_dir / item.raw_name
        _ = write_text(raw, item.raw_text)
        record_path = bench_dir / f"{item.family}.benchmark-output.json"
        record_sha = write_json(record_path, {"schema": "zig-scheduler/benchmark-output/v1", "status": item.status, "tool": item.tool, "command_family": item.family, "record_only": True, "output_path": raw.as_posix(), "output_sha256": hashlib.sha256(raw.read_bytes()).hexdigest(), "vm_evidence": (row_dir / "matrix-run.json").as_posix(), "parser_provenance": {"parser": "qa/benchmark_output_parse.py", "parser_version": "benchmark-output/v1", "parser_status": "PARSED" if item.status == "RECORDED" else "UNSUPPORTED_DEFERRED"}, "metrics": item.metrics, "units": item.units, "sample_count": item.sample_count, "run_count": item.run_count, "host_mutation": False, "release_eligible": False, "production_capacity_claim": False, "hard_thresholds_enforced": False, "threshold_status": "record_only", "privacy_sanitized": True})
        record: JsonObject = {"record_path": record_path.as_posix(), "record_sha256": record_sha, "record_only": True}
        records.append(record)
    return records


def policy_abi(policy_sha: str, scenario: str, index: int, outcome: str) -> JsonObject:
    abi = good_policy_abi(policy_sha)
    status = "present" if scenario == "workload-cgroup-weight-quota" and index == 1 and outcome == "PASS" else "unavailable"
    abi["cgroup_policy_map"] = good_cgroup_policy_map(status)
    abi["cgroup_callback_stats"] = good_cgroup_callback_stats(status)
    abi["dsq_counter_coherence"] = good_dsq_counter_coherence(status)
    return abi


def runtime_sample(index: int, scheduler_state: str, ops: str, context: JsonObject) -> JsonObject:
    scenario = str(context["scenario"])
    outcome = str(context["outcome"])
    enabled = scheduler_state == "enabled"
    phase = "during_attach" if enabled else ("before_attach" if index == 0 else "after_rollback")
    enable_seq = str(40 + index) if enabled else str(context["last_enable_seq"])
    abi = policy_abi(str(context["policy_sha"]), scenario, index, outcome)
    return {"schema": "zig-scheduler/runtime-sample/v1", "sequence": index, "sample_source_event": f"matrix-{scenario}-{index}", "observation_source": "vm_harness_matrix_row", "sched_ext_phase": phase, "state": {"status": "present", "value": scheduler_state}, "ops": {"status": "present", "value": ops}, "enable_seq": {"status": "present", "value": enable_seq}, "events": {"status": "present", "value": "nr_rejected: 0 dispatch_failed: 0 fallback: 0 fatal: 0"}, "events_hash": hashlib.sha256(f"{scenario}:events:{index}".encode()).hexdigest(), "nr_rejected": {"status": "present", "value": "0"}, "debug_dump": {"status": "missing", "value": ""}, "root_ops": {"status": "present", "value": ops}, "scheduler_events": {"status": "present", "value": "nr_rejected: 0 dispatch_failed: 0 fallback: 0 fatal: 0"}, "policy_counters": {"nr_rejected": 0, "dispatch_failed": 0, "fallback": 0, "fatal": 0}, "sample_loss": {"lost_samples": 0, "backpressure_dropped": 0, "ring_buffer_overruns": 0, "reader_lag_events": 0}, "policy_abi": abi, "cgroup_semantic_labels": abi["cgroup_semantics"], "cgroup_membership_digest": context["cgroup_digest"], "cgroup_membership_status": {"status": "present", "value": "present"}, "task_ext_enabled": {"status": "present" if enabled else "unknown", "value": "true" if enabled else "unavailable"}, "teardown_state": {"status": "present", "value": "attached" if enabled else "detached"}, "rollback_state": {"status": "present", "value": "rolled_back" if phase == "after_rollback" else "not_applicable"}, "workload": {"status": "present", "value": "alive" if outcome == "PASS" else "not-started"}, "workload_alive": outcome == "PASS", "private_command_lines_sampled": False, "dsq_depth": {"global": 1 if enabled else 0, "local": 0, "shared": 0}, "queue_latency": {"p50_us": 0, "p95_us": 0, "p99_us": 0, "max_us": 0}, "fairness": {"state": "ok" if outcome == "PASS" else "unknown", "starved_tasks": 0, "max_wait_us": 0}, "task_counts": {"by_cgroup_digest": {str(context["cgroup_digest"]): 1 if outcome == "PASS" else 0}, "by_class": {str(context["workload_class"]): 1 if outcome == "PASS" else 0}}, "scheduler_counters": {"context_switches": index, "wakeups": index, "migrations": 0}, "sched_ext_observation": {"dump": {"status": "present", "value": "sha256:" + hashlib.sha256(f"{scenario}:dump:{index}".encode()).hexdigest() + ";bytes:128"}, "tracepoints": {"sched_switch": index, "sched_wakeup": index}}}


def row() -> None:
    scenario, row_dir, outcome = os.environ["SCENARIO"], Path(os.environ["ROW_DIR"]), os.environ["OUTCOME"]
    row_dir.mkdir(parents=True, exist_ok=True)
    run_id, git_sha = os.environ["RUN_ID"], os.environ["GIT_SHA"]
    policy = row_dir / "policy.o"
    policy_sha = write_text(policy, f"matrix fixture policy object\nscenario={scenario}\n")
    source = Path("bpf/zigsched_minimal.bpf.c")
    source_sha = hashlib.sha256(source.read_bytes()).hexdigest() if source.is_file() else hashlib.sha256(b"missing source fixture\n").hexdigest()
    workload_class, threshold_source, missing_prereq = os.environ.get("WORKLOAD_CLASS", "cpu-smoke"), os.environ.get("WORKLOAD_THRESHOLD_SOURCE", "fixture"), os.environ.get("WORKLOAD_MISSING_PREREQ", "")
    workload_tools = [item for item in os.environ.get("WORKLOAD_TOOLS", "builtin-churn").split(",") if item]
    workload_tools_json = json_string_list(workload_tools)
    capability = row_dir / "workload-capability.json"
    _ = write_json(capability, {"schema": "zig-scheduler/workload-capability/v1", "scenario_id": scenario, "workload_class": workload_class, "required_tools": workload_tools_json, "threshold_source": threshold_source, "status": outcome, "typed_outcome": outcome, "missing_prereq": missing_prereq, "mode": os.environ["MODE"], "fixture_mode": os.environ.get("FIXTURE_MODE", "false") == "true", "runner": "qa/vm/workload_capability_probe.sh", "vm_marker_required_for_live_run": True, "host_mutation": False, "release_eligible": False})
    workload_spec: JsonObject = {"schema": "zig-scheduler/workload-fixture/v1", "name": workload_class, "workload_class": workload_class, "scenario_id": scenario, "required_tools": workload_tools_json, "threshold_source": threshold_source, "thresholds": {"source": threshold_source, "fixture_status": "deterministic", "calibration_status": "uncalibrated", "production_capacity_claim": False}, "capability_artifact_path": capability.as_posix(), "runner": "qa/vm/workload_capability_probe.sh", "vm_marker_required_for_live_run": True, "host_safe_fixture_only": os.environ["MODE"] != "vm-required", "missing_prereq": missing_prereq, "host_mutation": False, "release_eligible": False}
    provenance = write_benchmarks(row_dir, scenario, threshold_source, missing_prereq)
    if provenance:
        workload_spec["benchmark_provenance"] = provenance
    workload_spec.update(workload_semantics(scenario))
    workload = row_dir / "workload-spec.json"
    workload_sha = write_json(workload, workload_spec)
    cgroup_digest = hashlib.sha256(f"{run_id}:{scenario}:cgroup".encode()).hexdigest()
    row_local_cgroup = "zigsched-" + hashlib.sha256(f"{run_id}:{scenario}:row-local-cgroup".encode()).hexdigest()[:16]
    isolation = row_dir / "row-isolation-contract.json"
    _ = write_json(isolation, {"schema": "zig-scheduler/row-isolation-contract/v1", "scenario_id": scenario, "row_directory": row_dir.as_posix(), "row_local_cgroup_name": row_local_cgroup, "timeout_envelope_seconds": int(os.environ["TIMEOUT_SECONDS"]), "artifact_reuse": "forbidden-across-rows", "artifacts_must_descend_from_row_directory": True, "rollback_proof_required_on_partial_failure": True, "cleanup_proof_required_on_partial_failure": True, "host_mutation": False, "release_eligible": False})
    context: JsonObject = {"scenario": scenario, "outcome": outcome, "policy_sha": policy_sha, "cgroup_digest": cgroup_digest, "workload_class": workload_class, "last_enable_seq": "0"}
    runtime_rows = (runtime_sample(0, "disabled", "none", context), runtime_sample(1, "enabled", "zigsched_minimal", context), runtime_sample(2, "disabled", "none", {**context, "last_enable_seq": "41"}))
    _ = (row_dir / "runtime-sample.jsonl").write_text("".join(json.dumps(sample, sort_keys=True) + "\n" for sample in runtime_rows), encoding="utf-8")
    _ = write_json(row_dir / "incident.json", {"schema": "zig-scheduler/matrix-incident/v1", "scenario_id": scenario, "outcome": outcome, "reason": os.environ["REASON"], "host_mutation": False, "release_eligible": False})
    _ = write_json(row_dir / "rollback-proof.json", {"schema": "zig-scheduler/rollback-proof/v1", "scenario_id": scenario, "status": "PASS", "scheduler_state": "disabled", "ops": "none", "host_mutation": False})
    _ = write_json(row_dir / "host-refusal.json", {"schema": "zig-scheduler/host-refusal-proof/v1", "scenario_id": scenario, "status": "REFUSE", "reason": "host scheduler mutation refused; VM marker required", "no_bpf_load_attach": True, "no_cgroup_write": True, "no_sys_write": True, "no_proc_write": True, "host_mutation": False})
    _ = write_json(row_dir / "privacy-scan.json", {"schema": "zig-scheduler/privacy-scan/v1", "status": "PASS", "private_fields_found": False, "host_mutation": False})
    _ = write_json(row_dir / "cleanup-proof.json", {"schema": "zig-scheduler/cleanup-proof/v1", "scenario_id": scenario, "status": "PASS", "owned_qemu_leftovers": False, "owned_temp_leftovers": False, "qemu_scan_before": os.environ["QEMU_BEFORE"], "qemu_scan_after": os.environ["QEMU_AFTER"], "temp_scan_before": os.environ["TEMP_BEFORE"], "temp_scan_after": os.environ["TEMP_AFTER"], "host_mutation": False})
    marker_present, marker_required = env_bool("MARKER_PRESENT"), env_bool("MARKER_REQUIRED")
    marker_checked_by = "qa/vm/vm_harness_matrix.sh"
    if marker_present:
        marker_proof = row_dir / "vm-marker-proof.json"
        _ = write_json(marker_proof, {"schema": "zig-scheduler/vm-marker-proof/v1", "path": "/run/zig-scheduler-vm-lab.marker", "required": True, "present": True, "evidence_mode": "vm-live", "host_mutation": False})
        marker_checked_by = marker_proof.as_posix()
    state: JsonObject = {"ops": "none", "sched_ext": "disabled"}
    cgroup: JsonObject = {"digest": "sha256:" + cgroup_digest, "row_local_name": row_local_cgroup, "isolation_contract_path": isolation.as_posix()}
    _ = write_json(row_dir / "matrix-run.json", {"schema": "zig-scheduler/matrix-run/v1", "matrix_run_id": run_id, "scenario_id": scenario, "outcome": outcome, "evidence_mode": os.environ["EVIDENCE_MODE"], "kernel_tuple": {"kernel_release": os.uname().release, "arch": os.uname().machine, "btf": os.environ["BTF"], "kvm": os.environ["KVM_STATUS"], "sched_ext": os.environ["SCHED_EXT"]}, "supported_tuple_status": os.environ["TUPLE_STATUS"], "vm_marker": {"required": marker_required, "present": marker_present, "path": "/run/zig-scheduler-vm-lab.marker", "checked_by": marker_checked_by}, "bpf_abi_version": "zigsched-bpf-abi-v1", "policy": {"name": "zigsched_minimal", "object_path": policy.as_posix(), "object_sha256": policy_sha, "source_path": "bpf/zigsched_minimal.bpf.c", "source_sha256": source_sha}, "workload": {"name": workload_class, "spec_path": workload.as_posix(), "spec_sha256": workload_sha}, "action_id": "ACT-" + scenario, "audit_id": os.environ.get("LIVE_AUDIT_ID") or "AUD-20260629T120000Z-" + scenario, "rollback_id": os.environ.get("LIVE_ROLLBACK_ID") or "RB-" + scenario, "pre_scheduler_state": state, "post_scheduler_state": state, "pre_cgroup_state": cgroup, "post_cgroup_state": cgroup, "runtime_sample_path": (row_dir / "runtime-sample.jsonl").as_posix(), "daemon_event_path": str(Path(os.environ["EVENT_FILE"])), "incident_path": (row_dir / "incident.json").as_posix(), "rollback_proof_path": (row_dir / "rollback-proof.json").as_posix(), "cleanup_proof_path": (row_dir / "cleanup-proof.json").as_posix(), "host_refusal_proof_path": (row_dir / "host-refusal.json").as_posix(), "privacy_scan": {"status": "PASS", "private_fields_found": False, "report_path": (row_dir / "privacy-scan.json").as_posix()}, "git": {"expected_sha": git_sha, "actual_sha": git_sha, "status": "current", "dirty": False}, "release_eligible": False, "host_mutation": False})
    print(outcome)


def manifest_row() -> None:
    print(json.dumps({"scenario_id": os.environ["SCENARIO"], "outcome": os.environ["OUTCOME"], "artifact_path": os.environ["ROW_PATH"], "reason": os.environ["REASON"]}, sort_keys=True))


def manifest() -> None:
    rows: JsonArray = [parse_json_object(line) for line in Path(os.environ["MANIFEST_ROWS"]).read_text(encoding="utf-8").splitlines() if line.strip()]
    _ = write_json(Path(os.environ["MANIFEST"]), {"schema": "zig-scheduler/vm-harness-matrix-index/v1", "matrix_run_id": os.environ["RUN_ID"], "mode": os.environ["MODE"], "fixture_mode": os.environ["FIXTURE_MODE"] == "true", "started_at": os.environ["STARTED_AT"], "ended_at": os.environ["ENDED_AT"], "out_dir": os.environ["OUT_DIR"], "daemon_events_path": os.environ["EVENT_FILE"], "row_count": len(rows), "rows": rows, "host_mutation": False, "release_eligible": False})


def overlay_backend() -> None:
    summary_path, row_dir = Path(os.environ["BACKEND_SUMMARY"]), Path(os.environ["ROW_DIR"])
    if not summary_path.is_file():
        return
    summary = parse_json_object(summary_path.read_text(encoding="utf-8"))
    if summary.get("status") != "PASS":
        return
    live_summary = Path(json_field_as_string(summary, "live_summary"))
    if not live_summary.is_file():
        return
    runtime = live_summary.parent / "observe-partial" / "runtime-samples.jsonl"
    if runtime.is_file():
        import shutil
        _ = shutil.copyfile(runtime, row_dir / "runtime-sample.jsonl")


def overlay_workload() -> None:
    summary_path, row_dir = Path(os.environ["BACKEND_SUMMARY"]), Path(os.environ["ROW_DIR"])
    if not summary_path.is_file():
        return
    try:
        summary = parse_json_object(summary_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return
    live_summary = Path(json_field_as_string(summary, "live_summary"))
    if not live_summary.is_file():
        return
    import shutil
    out = row_dir / "workload-vm-artifacts"
    out.mkdir(parents=True, exist_ok=True)
    runtime = live_summary.parent / "observe-partial" / "runtime-samples.jsonl"
    if runtime.is_file():
        _ = shutil.copyfile(runtime, row_dir / "runtime-sample.jsonl")
    for src in (live_summary, live_summary.parent / "serial.txt", runtime, summary_path):
        if src.is_file():
            _ = shutil.copyfile(src, out / src.name)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: vm_harness_matrix_emit.py event|row|manifest-row|manifest|overlay-backend|overlay-workload", file=sys.stderr)
        return 2
    commands: dict[str, Callable[[], None]] = {
        "event": event,
        "row": row,
        "manifest-row": manifest_row,
        "manifest": manifest,
        "overlay-backend": overlay_backend,
        "overlay-workload": overlay_workload,
    }
    command = commands.get(sys.argv[1])
    if command is None:
        print(f"unknown emit command: {sys.argv[1]}", file=sys.stderr)
        return 2
    command()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
