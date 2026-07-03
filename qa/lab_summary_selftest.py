from __future__ import annotations

from pathlib import Path
import json
import shutil

from qa.evidence_safety_check import JsonObject
from qa.lab_summary_check import LabSummaryError, validate_partial, validate_summary

MALFORMED_FIXTURE = Path("fixtures/lab/run-all-summary-missing-host-mutation.json")
SUMMARY_SCHEMA = "zig-scheduler/run-all-lab/v1"
STAGE_SCHEMA = "zig-scheduler/run-all-stage/v1"


def self_test() -> None:
    root = Path("evidence/lab/run-all/self-test-lab-summary-check")
    shutil.rmtree(root, ignore_errors=True)
    (root / "stage").mkdir(parents=True)
    (root / "stage" / "transcript.txt").write_text("self-test\n")
    stage: JsonObject = {
        "artifact_paths": [str(root / "stage"), str(root / "stage" / "transcript.txt")],
        "command": "self-test",
        "ended_at": "2026-06-11T00:00:01Z",
        "git_sha": "self-test-sha",
        "host_mutation": False,
        "kernel_tuple": {"arch": "x86_64", "config_sha256": "self-test", "release": "6.12.0-lab"},
        "mode": "host-safe",
        "reason": "self-test stage",
        "rollback_result": "N/A",
        "schema": STAGE_SCHEMA,
        "stage": "self_test",
        "started_at": "2026-06-11T00:00:00Z",
        "status": "PASS",
        "vm_kind": "host-safe-surrogate",
    }
    summary: JsonObject = {
        "artifact_paths": [str(root / "stage")],
        "cleanup": {"qemu_leftovers": False, "tmux_leftovers": False},
        "ended_at": "2026-06-11T00:00:01Z",
        "git_sha": "self-test-sha",
        "host_mutation": False,
        "kernel_tuple": {"arch": "x86_64", "config_sha256": "self-test", "release": "6.12.0-lab"},
        "mode": "host-safe",
        "release_status": "skipped_no_vm",
        "release_use": False,
        "rollback_result": "N/A",
        "schema": SUMMARY_SCHEMA,
        "stages": [stage],
        "started_at": "2026-06-11T00:00:00Z",
        "status": "PASS",
        "vm_kind": "host-safe-surrogate",
    }
    good = root / "summary.json"
    good.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    validate_summary(good)
    reject(MALFORMED_FIXTURE, "fixture missing host_mutation")
    partial = root / "partial-refusal.json"
    partial.write_text(json.dumps({"schema": "zig-scheduler/partial-attach-refusal/v1", "status": "refused-host", "reason_code": "HOST_REFUSED", "reason": "marker missing", "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope", "audit_id": "AUD-20990101T000000Z-deadbee-abc123", "rollback_id": "RB-demo", "host_mutation": False}, sort_keys=True) + "\n")
    validate_partial(partial)
    bad_partial = root / "bad-partial-refusal.json"
    bad_partial.write_text(json.dumps({"schema": "zig-scheduler/partial-attach-refusal/v1", "status": "refused-host", "reason_code": "UNKNOWN", "reason": "marker missing", "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope", "audit_id": "AUD-20990101T000000Z-deadbee-abc123", "rollback_id": "RB-demo", "host_mutation": False}, sort_keys=True) + "\n")
    reject_partial(bad_partial, "unknown partial reason_code")
    bad_release = root / "release-use-untracked.json"
    summary["release_use"] = True
    bad_release.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    reject(bad_release, "release_use untracked generated path")
    shutil.rmtree(root, ignore_errors=True)
    print("PASS lab summary self-test: accepted valid summary and rejected malformed/release-use fixtures")


def reject(path: Path, label: str) -> None:
    try:
        validate_summary(path)
    except LabSummaryError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise LabSummaryError(f"expected rejection did not occur: {label}")


def reject_partial(path: Path, label: str) -> None:
    try:
        validate_partial(path)
    except LabSummaryError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise LabSummaryError(f"expected rejection did not occur: {label}")
