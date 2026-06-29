from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Final

from qa.live_lab_evidence_check import self_test as live_evidence_self_test
from qa.runtime_sample_core import JsonObject, JsonValue, RuntimeSampleError, good_sample, validate_alert_order, validate_file

SELF_TEST_ROOT: Final = Path("evidence/lab/runtime-sample-check-self-test")


def reject(path: Path, label: str) -> None:
    try:
        validate_file(path)
    except RuntimeSampleError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise RuntimeSampleError(f"expected rejection did not occur: {label}")


def write_sample(path: Path, sample: JsonObject) -> Path:
    _ = path.write_text(json.dumps(sample, sort_keys=True) + "\n")
    return path


def reject_rows(rows: list[JsonObject], label: str) -> None:
    try:
        validate_alert_order(rows, label)
    except RuntimeSampleError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise RuntimeSampleError(f"expected rejection did not occur: {label}")


def runtime_alert_rows(reason_first: bool, reason: str) -> list[JsonObject]:
    sample: JsonObject = {"event": "runtime_sample", "nr_rejected": "3" if reason == "runtime_nr_rejected_nonzero" else "0", "workload_alive": reason != "runtime_workload_dead"}
    incident: JsonObject = {"event": "incident", "reason": reason}
    return [incident, sample] if reason_first else [sample, incident]


def self_test() -> None:
    shutil.rmtree(SELF_TEST_ROOT, ignore_errors=True)
    SELF_TEST_ROOT.mkdir(parents=True)
    _ = validate_file(write_sample(SELF_TEST_ROOT / "good.jsonl", good_sample()))
    for field, label in (("private_command_lines_sampled", "missing privacy flag"), ("events_hash", "missing events hash"), ("policy_abi", "missing policy ABI")):
        sample = good_sample()
        del sample[field]
        reject(write_sample(SELF_TEST_ROOT / f"{field}-missing.jsonl", sample), label)
    overrides: tuple[tuple[str, str, JsonValue, str], ...] = (
        ("command_line", "raw-command.jsonl", "/usr/bin/demo --token secret", "raw command line"),
        ("private_command_lines_sampled", "private-flag.jsonl", True, "private command lines flag"),
        ("enable_seq", "malformed-sched-ext-fact.jsonl", {"status": "present", "value": "not-a-number"}, "malformed sched_ext fact"),
        ("debug_dump", "raw-debug-path.jsonl", {"status": "present", "value": "/sys/kernel/debug/sched_ext/dump"}, "raw debug dump path"),
        ("cgroup_membership_digest", "invalid-cgroup-digest.jsonl", "not-a-sha256", "invalid cgroup digest"),
        ("cgroup_membership_digest", "zero-cgroup-digest.jsonl", "0" * 64, "zero cgroup digest"),
    )
    for field, name, value, label in overrides:
        sample = good_sample()
        sample[field] = value
        reject(write_sample(SELF_TEST_ROOT / name, sample), label)
    reject_rows(runtime_alert_rows(True, "runtime_nr_rejected_nonzero"), "nr_rejected incident ordering")
    reject_rows(runtime_alert_rows(True, "runtime_workload_dead"), "workload dead incident ordering")
    validate_alert_order(runtime_alert_rows(False, "runtime_nr_rejected_nonzero"), "nr_rejected-good-order")
    validate_alert_order(runtime_alert_rows(False, "runtime_workload_dead"), "workload-dead-good-order")
    shutil.rmtree(SELF_TEST_ROOT)
    live_evidence_self_test()
    print("PASS runtime sample self-test: privacy-safe samples accepted and unsafe samples rejected")
