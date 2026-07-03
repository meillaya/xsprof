#!/usr/bin/env python3
"""Shared model, constants, and typed errors for matrix-run/v1 validation."""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SCHEMA: Final = "zig-scheduler/matrix-run/v1"
MATRIX_BPF_ABI_VERSION: Final = "zigsched-bpf-abi-v1"
SCHEMA_FILE: Final = "matrix-run.v1.schema.json"
DOC_FILE: Final = "matrix-run-contract.md"
VM_MARKER: Final = "/run/zig-scheduler-vm-lab.marker"
OUTCOMES: Final = frozenset({"PASS", "SKIP", "REFUSE", "INCIDENT", "FAIL"})
EVIDENCE_MODES: Final = frozenset({"vm-live", "host-refusal-only", "fixture"})
TUPLE_STATUS: Final = frozenset({"supported", "unsupported", "unknown"})
REQUIRED_FIXTURES: Final = frozenset({"pass.json", "live-backend.json", "skip-unsupported-tuple.json", "host-refusal-only.json", "incident-verifier-reject.json", "rollback-failure.json", "cleanup-residue.json", "workload-cpu-saturation.json", "workload-interactive-latency.json", "workload-scheduler-affinity-churn.json", "workload-fork-ipc-pressure.json", "workload-mixed-io.json", "workload-cgroup-weight-quota.json", "workload-cpu-hotplug.json", "sched-ext-state-normal-rollback.json", "sched-ext-state-scheduler-exit.json", "sched-ext-state-watchdog-disable.json", "sched-ext-state-forced-disable.json"})
REQUIRED_INVALID_FIXTURES: Final = frozenset({"host-mutation-true.json", "release-eligible-true.json", "invalid-outcome.json", "stale-git.json", "dirty-git.json", "missing-vm-marker.json", "unsafe-absolute-path.json", "unsafe-traversal-path.json", "missing-rollback-proof.json", "missing-cleanup-proof.json", "missing-cleanup-proof-on-skip.json", "missing-cleanup-proof-on-refuse.json", "missing-host-refusal-proof.json", "privacy-failed.json", "unsupported-bpf-abi-version.json", "malformed.json", "extra-property.json", "missing-sched-ext-state.json", "stale-enable-seq.json", "private-debug-dump.json"})
PATH_FIELDS: Final = ("runtime_sample_path", "daemon_event_path", "incident_path", "rollback_proof_path", "cleanup_proof_path", "host_refusal_proof_path")
ROW_FIELDS: Final = frozenset(("schema", "matrix_run_id", "scenario_id", "outcome", "evidence_mode", "kernel_tuple", "supported_tuple_status", "vm_marker", "bpf_abi_version", "policy", "workload", "action_id", "audit_id", "rollback_id", "pre_scheduler_state", "post_scheduler_state", "pre_cgroup_state", "post_cgroup_state", "runtime_sample_path", "daemon_event_path", "incident_path", "rollback_proof_path", "cleanup_proof_path", "host_refusal_proof_path", "privacy_scan", "git", "release_eligible", "host_mutation"))
KERNEL_TUPLE_FIELDS: Final = frozenset(("kernel_release", "arch", "btf", "kvm", "sched_ext"))
VM_MARKER_FIELDS: Final = frozenset(("required", "present", "path", "checked_by"))
POLICY_FIELDS: Final = frozenset(("name", "object_path", "object_sha256", "source_path", "source_sha256"))
WORKLOAD_FIELDS: Final = frozenset(("name", "spec_path", "spec_sha256"))
PRIVACY_SCAN_FIELDS: Final = frozenset(("status", "private_fields_found", "report_path"))
GIT_FIELDS: Final = frozenset(("expected_sha", "actual_sha", "status", "dirty"))
MANIFEST_ROW_FIELDS: Final = frozenset(("scenario_id", "outcome", "artifact_path", "reason"))
MANIFEST_FIELDS: Final = frozenset(("schema", "matrix_run_id", "mode", "fixture_mode", "started_at", "ended_at", "out_dir", "daemon_events_path", "row_count", "rows", "host_mutation", "release_eligible"))
MATRIX_BASE: Final = Path("evidence/lab/matrix")
MANIFEST_FILE: Final = "manifest.json"
RUN_ID_MAX: Final = 64
RUN_ID_RE: Final = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
ID_RE: Final = re.compile(r"^[A-Za-z0-9_.-]{1,96}$")
AUDIT_RE: Final = re.compile(r"^AUD-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9_.-]+$")
SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
SAFE_RELATIVE_PATH_PATTERN: Final = r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$)).+$"
SCHEMA_PATH_FIELDS: Final = (("runtime_sample_path",), ("daemon_event_path",), ("incident_path",), ("rollback_proof_path",), ("cleanup_proof_path",), ("host_refusal_proof_path",), ("policy", "object_path"), ("policy", "source_path"), ("workload", "spec_path"), ("privacy_scan", "report_path"))
PRIVATE_NEEDLES: Final = ("cmdline", "command_line", "argv", "environment", "secret", "api_key", "token", "password", "authorization", "bearer")
WORKLOAD_PRIVATE_NEEDLES: Final = PRIVATE_NEEDLES + ("command", "env", "cwd", "pid", "ppid")
PRIVATE_PATH_RE: Final = re.compile(r"(^|[\s=:])/(?:home|root|etc|proc|sys|var|tmp)/")
SCHED_STATES: Final = frozenset({"disabled", "enabled", "enabling", "disabling", "unknown", "unavailable"})
SCHED_DISABLE_REASONS: Final = frozenset({"normal_unregister", "scheduler_exit", "watchdog_stall", "watchdog_error", "sysrq_forced_disable", "not_applicable", "unavailable"})
SCHED_STATE_FIELDS: Final = frozenset({"sched_ext", "ops", "enable_seq", "root_ops", "task_ext_enabled", "disable_reason", "teardown_state", "rollback_state"})
CLAIM_TEXT_RE: Final = re.compile(r"\b(?:production|release|performance)[\s_-]+(?:ready|eligible|approved|claim|slo|sla|guarantee|baseline|capacity)\b", re.IGNORECASE)
WORKLOAD_SPEC_SCHEMA: Final = "zig-scheduler/workload-fixture/v1"
WORKLOAD_CAPABILITY_SCHEMA: Final = "zig-scheduler/workload-capability/v1"
PRIVACY_SCAN_SCHEMA: Final = "zig-scheduler/privacy-scan/v1"
PRIVACY_REPORT_FIELDS: Final = frozenset(("schema", "status", "private_fields_found", "host_mutation"))
INCIDENT_FIELDS: Final = frozenset(("schema", "scenario_id", "outcome", "reason", "host_mutation", "release_eligible"))
ROLLBACK_PROOF_FIELDS: Final = frozenset(("schema", "scenario_id", "status", "scheduler_state", "ops", "host_mutation"))
CLEANUP_PROOF_FIELDS: Final = frozenset(("schema", "scenario_id", "status", "owned_qemu_leftovers", "owned_temp_leftovers", "qemu_scan_before", "qemu_scan_after", "temp_scan_before", "temp_scan_after", "host_mutation"))
HOST_REFUSAL_FIELDS: Final = frozenset(("schema", "scenario_id", "status", "reason", "no_bpf_load_attach", "no_cgroup_write", "no_sys_write", "no_proc_write", "host_mutation"))
VM_MARKER_PROOF_FIELDS: Final = frozenset(("schema", "path", "required", "present", "evidence_mode", "host_mutation"))
WORKLOAD_SPEC_FIELDS: Final = frozenset(("schema", "name", "workload_class", "scenario_id", "required_tools", "threshold_source", "thresholds", "benchmark_provenance", "capability_artifact_path", "runner", "vm_marker_required_for_live_run", "host_safe_fixture_only", "missing_prereq", "cgroup_semantics", "cpu_hotplug_semantics", "host_mutation", "release_eligible"))
WORKLOAD_THRESHOLD_FIELDS: Final = frozenset(("source", "fixture_status", "calibration_status", "production_capacity_claim"))
WORKLOAD_CAPABILITY_FIELDS: Final = frozenset(("schema", "scenario_id", "workload_class", "required_tools", "threshold_source", "mode", "status", "typed_outcome", "missing_prereq", "vm_marker_required_for_live_run", "fixture_mode", "runner", "host_mutation", "release_eligible"))
WORKLOAD_TOOL_NAMES: Final = frozenset(("stress-ng", "cyclictest", "perf", "taskset", "chrt", "hackbench-like", "fio", "cpu-hotplug-online-control", "builtin-churn"))
WORKLOAD_THRESHOLD_SOURCES: Final = frozenset(("fixture", "calibrated", "deferred", "record-only", "uncalibrated"))
WORKLOAD_CAPABILITY_MODES: Final = frozenset(("host-safe", "auto", "vm-required"))

CGROUP_WORKLOAD_SEMANTICS: Final[JsonObject] = {
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
CPU_HOTPLUG_SEMANTICS: Final[JsonObject] = {
    "cpu.hotplug.offline": "fallback-observed",
    "cpu.hotplug.online": "fallback-observed",
    "cpuset.cpus": "observed-constraints",
    "cpuset.cpus.effective": "observed-constraints",
    "allowed-mask": "rejected",
}


@dataclass(frozen=True, slots=True)
class Args:
    fixtures: Path | None
    schemas: Path
    docs: Path
    manifest: Path | None
    self_test: bool


@dataclass(frozen=True, slots=True)
class WorkloadScenarioMetadata:
    scenario_id: str
    workload_class: str
    required_tools: tuple[str, ...]
    threshold_sources: frozenset[str]


class MatrixRunContractError(Exception):
    pass

WORKLOAD_SCENARIO_METADATA: Final = {
    "workload-cpu-saturation": WorkloadScenarioMetadata("workload-cpu-saturation", "cpu-saturation", ("stress-ng",), frozenset({"record-only"})),
    "workload-interactive-latency": WorkloadScenarioMetadata("workload-interactive-latency", "interactive-latency", ("cyclictest", "perf"), frozenset({"record-only"})),
    "workload-scheduler-affinity-churn": WorkloadScenarioMetadata("workload-scheduler-affinity-churn", "scheduler-affinity-churn", ("stress-ng", "taskset", "chrt"), frozenset({"record-only"})),
    "workload-fork-ipc-pressure": WorkloadScenarioMetadata("workload-fork-ipc-pressure", "bounded-fork-ipc-pressure", ("hackbench-like",), frozenset({"record-only"})),
    "workload-mixed-io": WorkloadScenarioMetadata("workload-mixed-io", "mixed-io", ("fio",), frozenset({"record-only"})),
    "workload-cgroup-weight-quota": WorkloadScenarioMetadata("workload-cgroup-weight-quota", "cgroup-weight-quota-pressure", ("stress-ng",), frozenset({"record-only"})),
    "workload-cpu-hotplug": WorkloadScenarioMetadata("workload-cpu-hotplug", "cpu-hotplug-offline", ("cpu-hotplug-online-control",), frozenset({"record-only"})),
}
