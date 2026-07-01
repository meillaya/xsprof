from __future__ import annotations

from typing import TypeAlias

from qa.runtime_sample_policy_abi import SEMANTICS, good_policy_abi

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
SAMPLE_SCHEMA = "zig-scheduler/runtime-sample/v1"


def good_sample() -> JsonObject:
    digest = "a" * 64
    policy_abi = good_policy_abi()
    return {
        "schema": SAMPLE_SCHEMA,
        "sequence": 0,
        "sched_ext_phase": "during_attach",
        "state": {"status": "present", "value": "enabled"},
        "ops": {"status": "present", "value": "zigsched_minimal"},
        "enable_seq": {"status": "present", "value": "42"},
        "events": {"status": "present", "value": "nr_rejected: 0"},
        "events_hash": "ab12",
        "nr_rejected": {"status": "present", "value": "0"},
        "debug_dump": {"status": "missing", "value": ""},
        "root_ops": {"status": "present", "value": "zigsched_minimal"},
        "scheduler_events": {"status": "present", "value": "nr_rejected: 0"},
        "policy_counters": {"nr_rejected": 0, "dispatch_failed": 0, "fallback": 0, "fatal": 0},
        "sample_loss": {"lost_samples": 0, "backpressure_dropped": 0, "ring_buffer_overruns": 0, "reader_lag_events": 0}, "dsq_depth": {"global": 2, "local": 1, "shared": 0},
        "queue_latency": {"p50_us": 40, "p95_us": 120, "p99_us": 250, "max_us": 300}, "fairness": {"state": "ok", "starved_tasks": 0, "max_wait_us": 0},
        "task_counts": {"by_cgroup_digest": {digest: 3}, "by_class": {"interactive": 1, "batch": 2}}, "scheduler_counters": {"context_switches": 123, "wakeups": 45, "migrations": 6},
        "sched_ext_observation": {"dump": {"status": "present", "value": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;bytes:128"}, "tracepoints": {"sched_switch": 123, "sched_wakeup": 45}}, "benchmark_histograms": [{"record_path": "fixtures/benchmark-output/cyclictest-recorded.json", "record_sha256": "c" * 64, "histogram_id": "latency_us", "record_only": True}],
        "policy_abi": policy_abi,
        "cgroup_semantic_labels": dict(SEMANTICS),
        "cgroup_membership_digest": digest,
        "cgroup_membership_status": {"status": "present", "value": "present"},
        "task_ext_enabled": {"status": "present", "value": "true"},
        "teardown_state": {"status": "present", "value": "attached"},
        "rollback_state": {"status": "present", "value": "not_applicable"},
        "workload": {"status": "present", "value": "alive"},
        "workload_alive": True,
        "private_command_lines_sampled": False,
    }

