#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/protected_core_telemetry_check.py --self-test
"""Self-test fixtures for protected-core runtime telemetry checks."""
from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import json
import shutil
import sys
from pathlib import Path
from typing import Final

sys.path.insert(0, str(Path(__file__).resolve().parent / "vm"))

from qa.runtime_sample_common import JsonObject, require_object
from qa.runtime_sample_core import good_sample
from qa.vm.microvm_report_summary import build_sample_rows
from qa.vm.microvm_report_types import ReportRows

SELF_ROOT: Final[Path] = Path("evidence/lab/protected-core-telemetry-self-test")
CGROUP_SCENARIO: Final[str] = "workload-cgroup-weight-quota"


@dataclass(frozen=True, slots=True)
class TelemetrySelfTest:
    """Validator functions and error classes used by telemetry self-tests."""

    validate_input: Callable[[Path, str | None], None]
    validate_vm_captured_input: Callable[[Path, str | None], None]
    expected_errors: tuple[type[BaseException], ...]

    def expect_reject(self, path: Path, label: str, scenario: str | None = None) -> None:
        try:
            self.validate_input(path, scenario)
        except self.expected_errors as exc:
            print(f"PASS reject {label}: {exc}")
            return
        raise AssertionError(f"expected rejection did not occur: {label}")

    def expect_reject_vm_captured(self, path: Path, label: str, scenario: str | None = None) -> None:
        try:
            self.validate_vm_captured_input(path, scenario)
        except self.expected_errors as exc:
            print(f"PASS reject {label}: {exc}")
            return
        raise AssertionError(f"expected VM-captured telemetry rejection did not occur: {label}")


def write_sample(path: Path, sample: JsonObject) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(json.dumps(sample, sort_keys=True) + "\n")
    return path


def producer_event(source: str, events: str) -> JsonObject:
    return {
        "event": source,
        "ops": "zigsched_minimal" if source == "register" else "none",
        "state": "enabled" if source == "register" else "disabled",
        "events": events,
        "enable_seq": "7",
        "cgroup_membership_digest": "a" * 64,
        "cgroup_membership_status": "present",
        "workload_alive": True,
    }


def producer_rows(before_events: str, register_events: str, unregister_events: str) -> list[JsonObject]:
    rows = ReportRows(
        boot={},
        tuple_row={},
        workload={},
        workload_executions=(),
        mutation_rows=(),
        before=producer_event("before", before_events),
        register=producer_event("register", register_events),
        unregister=producer_event("unregister", unregister_events),
        stale_refusal={},
        duplicate_refusal={},
    )
    return build_sample_rows(rows, "b" * 64)


def assert_unavailable_policy_counters(row: JsonObject, label: str) -> None:
    counters = require_object(row, "policy_counters", label)
    if counters.get("status") != "unknown" or counters.get("value") != "unavailable":
        raise AssertionError(f"{label} emitted fake policy counters: {counters}")


def run_self_test(checks: TelemetrySelfTest) -> None:
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    good = write_sample(SELF_ROOT / "good.jsonl", good_sample())
    checks.validate_input(good, "live-backend")
    harness_sample = good_sample()
    harness_sample["observation_source"] = "vm_harness_matrix_row"
    harness_sample["sample_source_event"] = "matrix-harness-generated-fallback"
    harness = write_sample(SELF_ROOT / "harness-generated.jsonl", harness_sample)
    checks.expect_reject_vm_captured(harness, "harness-generated protected-core PASS telemetry")
    vm_sample = good_sample()
    vm_sample["observation_source"] = "vm_serial_sched_ext"
    vm_sample["sample_source_event"] = "before"
    checks.validate_vm_captured_input(write_sample(SELF_ROOT / "vm-captured.jsonl", vm_sample), "live-backend")
    unavailable_events = good_sample()
    unavailable_events["events"] = {"status": "unknown", "value": "unavailable"}
    unavailable_events["nr_rejected"] = {"status": "present", "value": "0"}
    checks.expect_reject(write_sample(SELF_ROOT / "unavailable-events-numeric-nr.jsonl", unavailable_events), "unavailable events numeric nr_rejected")
    fake_policy_counters = good_sample()
    fake_policy_counters["events"] = {"status": "unknown", "value": "unavailable"}
    fake_policy_counters["nr_rejected"] = {"status": "unknown", "value": "unavailable"}
    checks.expect_reject(write_sample(SELF_ROOT / "unavailable-events-numeric-policy-counters.jsonl", fake_policy_counters), "unavailable events numeric policy counters")
    unavailable_metrics = good_sample()
    for field in ("sample_loss", "scheduler_counters", "fairness"):
        unavailable_metrics[field] = {"status": "unknown", "value": "unavailable"}
    checks.validate_input(write_sample(SELF_ROOT / "explicit-unavailable-metrics.jsonl", unavailable_metrics), "live-backend")
    print("PASS accept explicit unavailable sample_loss scheduler_counters fairness")
    producer_unavailable = producer_rows("", "unavailable", "fallback=0")
    for row, label in zip(producer_unavailable, ("empty events", "unavailable events", "event text without nr_rejected"), strict=True):
        assert_unavailable_policy_counters(row, label)
    checks.validate_input(write_sample(SELF_ROOT / "producer-unavailable-counters.jsonl", producer_unavailable[0]), "live-backend")
    producer_present = producer_rows("", "nr_rejected=3 dispatch_failed=4 fallback=5 fatal=6", "")
    counters = require_object(producer_present[1], "policy_counters", "producer present events")
    if counters != {"nr_rejected": 3, "dispatch_failed": 4, "fallback": 5, "fatal": 6}:
        raise AssertionError(f"producer present events lost numeric counters: {counters}")
    checks.validate_input(write_sample(SELF_ROOT / "producer-present-counters.jsonl", producer_present[1]), "live-backend")
    print("PASS producer policy counters follow event counter availability")
    for field, label in (("fairness", "missing fairness"), ("sample_loss", "missing sample loss"), ("scheduler_counters", "missing scheduler counters")):
        sample = good_sample()
        del sample[field]
        checks.expect_reject(write_sample(SELF_ROOT / f"{field}-missing.jsonl", sample), label)
    stale = good_sample()
    stale["enable_seq"] = {"status": "present", "value": "41"}
    _ = write_sample(SELF_ROOT / "stale.jsonl", stale)
    stale_next = good_sample()
    stale_next["sequence"] = 1
    stale_next["enable_seq"] = {"status": "present", "value": "40"}
    with (SELF_ROOT / "stale.jsonl").open("a") as handle:
        _ = handle.write(json.dumps(stale_next, sort_keys=True) + "\n")
    checks.expect_reject(SELF_ROOT / "stale.jsonl", "stale enable_seq")
    missing_abi = good_sample()
    policy_abi = require_object(missing_abi, "policy_abi", "self-test")
    del policy_abi["abi_label"]
    checks.expect_reject(write_sample(SELF_ROOT / "missing-cgroup-abi.jsonl", missing_abi), "missing cgroup ABI-v3 metadata", CGROUP_SCENARIO)
    private = good_sample()
    private["argv"] = ["demo"]
    checks.expect_reject(write_sample(SELF_ROOT / "private-field.jsonl", private), "private field")
    claim = good_sample()
    policy_claim = require_object(claim, "policy_abi", "self-test claim")
    policy_claim["release_eligible"] = True
    checks.expect_reject(write_sample(SELF_ROOT / "release-claim.jsonl", claim), "release claim")
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    print("PASS protected-core telemetry self-test")
