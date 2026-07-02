#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly:
#      uv run qa/lab_summary_observe.py --summary evidence/lab/observe-partial/summary.json
# 3. Or with system Python (no dependencies):
#      python3 qa/lab_summary_observe.py --self-test
# ──────────────────
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypeAlias
import json
import shutil
import sys

_ = sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from qa.audit_ledger_check import AuditLedgerError, validate_ledger, write_good  # noqa: E402
from qa.runtime_sample_check import RuntimeSampleError, good_sample, validate_file  # noqa: E402

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SUMMARY_SCHEMA: Final[str] = "zig-scheduler/observe-partial-summary/v1"


@dataclass(frozen=True, slots=True)
class Args:
    summary: Path | None
    self_test: bool


class ObserveSummaryError(Exception):
    pass


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(summary=None, self_test=True)
    if len(argv) == 2 and argv[0] == "--summary":
        return Args(summary=Path(argv[1]), self_test=False)
    raise ObserveSummaryError("usage: lab_summary_observe.py --summary <summary.json> | --self-test")


def load_object(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise ObserveSummaryError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ObserveSummaryError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ObserveSummaryError(f"{path} must contain a JSON object")
    return raw


def load_jsonl(path: Path) -> list[JsonObject]:
    rows: list[JsonObject] = []
    for line in path.read_text().splitlines():
        if line.strip() == "":
            continue
        raw: JsonValue = json.loads(line)
        if not isinstance(raw, dict):
            raise ObserveSummaryError(f"{path} contains non-object JSONL row")
        rows.append(raw)
    return rows


def require_string(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise ObserveSummaryError(f"{context} missing non-empty string field: {field}")
    return value


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise ObserveSummaryError(f"{context} missing bool field: {field}")
    return value


def require_int(data: JsonObject, field: str, context: str) -> int:
    value = data.get(field)
    if not isinstance(value, int):
        raise ObserveSummaryError(f"{context} missing int field: {field}")
    return value


def safe_path(summary: JsonObject, field: str) -> Path:
    value = Path(require_string(summary, field, "observe"))
    if value.is_absolute() or ".." in value.parts or not value.exists():
        raise ObserveSummaryError(f"observe path is unsafe or missing: {field}")
    return value


def sibling_path(summary_path: Path, summary: JsonObject, field: str) -> Path:
    value = safe_path(summary, field)
    if value.parent != summary_path.parent:
        raise ObserveSummaryError(f"observe path is not colocated with summary: {field}")
    return value


def validate_links(samples: Path, ledger: Path) -> None:
    try:
        validate_file(samples)
        validate_ledger(ledger)
    except (RuntimeSampleError, AuditLedgerError) as exc:
        raise ObserveSummaryError(str(exc)) from exc


def validate_sample_series(samples: Path, expected_count: int) -> None:
    rows = load_jsonl(samples)
    if len(rows) < 3 or len(rows) != expected_count:
        raise ObserveSummaryError("observe samples must include before/during/after rows")
    during = [row for row in rows if row.get("ops") == {"status": "present", "value": "zigsched_minimal"}]
    if not during:
        raise ObserveSummaryError("observe samples never show zigsched_minimal during attach")
    if not all(row.get("private_command_lines_sampled") is False for row in rows):
        raise ObserveSummaryError("observe samples include private command-line sampling")
    if not all(row.get("workload_alive") is True for row in rows):
        raise ObserveSummaryError("observe workload was not alive for every sample")


def validate_daemon_events(path: Path) -> None:
    rows = load_jsonl(path)
    runtime_events = [row for row in rows if row.get("event") == "runtime_sample"]
    if not runtime_events:
        raise ObserveSummaryError("daemon stream emitted no runtime_sample events")
    if not any(row.get("ops") == "zigsched_minimal" for row in runtime_events):
        raise ObserveSummaryError("daemon stream never emitted zigsched_minimal")
    if any("cmdline" in json.dumps(row) or "environment" in json.dumps(row) for row in rows):
        raise ObserveSummaryError("daemon stream leaked private process fields")


def validate_observe(path: Path) -> None:
    summary = load_object(path)
    if require_string(summary, "schema", "observe") != SUMMARY_SCHEMA:
        raise ObserveSummaryError("observe summary has unsupported schema")
    mode = require_string(summary, "evidence_mode", "observe")
    if mode not in {"fixture", "vm-configured-fixture", "vm-live", "host-refusal"}:
        raise ObserveSummaryError(f"observe evidence_mode is invalid: {mode}")
    release_proof = require_bool(summary, "release_eligible_live_proof", "observe")
    if mode != "vm-live" and release_proof:
        raise ObserveSummaryError("non-VM-live observe evidence cannot be release eligible")
    if release_proof:
        raise ObserveSummaryError("observe release proof is disabled until signed VM-live transport is implemented")
    samples = sibling_path(path, summary, "runtime_samples")
    ledger = safe_path(summary, "audit_ledger")
    sibling_path(path, summary, "transcript")
    daemon_events = sibling_path(path, summary, "daemon_runtime_events")
    validate_links(samples, ledger)
    validate_sample_series(samples, require_int(summary, "sample_count", "observe"))
    validate_daemon_events(daemon_events)
    validate_snapshot(summary)


def validate_snapshot(summary: JsonObject) -> None:
    snapshot = summary.get("scheduler_snapshot")
    if not isinstance(snapshot, dict):
        raise ObserveSummaryError("observe missing scheduler_snapshot")
    final_state = require_string(summary, "final_state", "observe")
    final_ops = require_string(summary, "final_ops", "observe")
    if not require_bool(summary, "final_state_disabled_or_rolled_back", "observe"):
        raise ObserveSummaryError("observe final state is not disabled or rolled back")
    if snapshot.get("state") != {"status": "present", "value": final_state}:
        raise ObserveSummaryError("observe scheduler_snapshot state conflicts with final_state")
    if snapshot.get("root_ops") != {"status": "present", "value": final_ops}:
        raise ObserveSummaryError("observe scheduler_snapshot root_ops conflicts with final_ops")


def write_fixture(root: Path, mode: str = "vm-configured-fixture", release_proof: bool = False) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    samples = root / "runtime-samples.jsonl"
    rows = []
    for seq, ops in enumerate(("none", "zigsched_minimal", "none")):
        row = good_sample()
        row["sequence"] = seq
        row["ops"] = {"status": "present", "value": ops}
        row["state"] = {"status": "present", "value": "disabled" if ops == "none" else "enabled"}
        rows.append(row)
    samples.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))
    ledger = write_good(root / "audit")
    transcript = root / "observe-transcript.txt"
    transcript.write_text("COMMAND: observe without command-line sampling\n")
    daemon = root / "daemon-runtime-events.jsonl"
    daemon.write_text('{"event":"runtime_sample","ops":"zigsched_minimal"}\n')
    summary = root / "summary.json"
    payload: JsonObject = {
        "schema": SUMMARY_SCHEMA,
        "status": "PASS",
        "evidence_mode": mode,
        "release_eligible_live_proof": release_proof,
        "sample_count": len(rows),
        "runtime_samples": samples.as_posix(),
        "audit_ledger": ledger.as_posix(),
        "transcript": transcript.as_posix(),
        "daemon_runtime_events": daemon.as_posix(),
        "scheduler_snapshot": {"state": rows[-1]["state"], "root_ops": rows[-1]["ops"]},
        "final_state": "disabled",
        "final_ops": "none",
        "final_state_disabled_or_rolled_back": True,
    }
    summary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return summary


def reject(path: Path, label: str) -> None:
    try:
        validate_observe(path)
    except ObserveSummaryError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise ObserveSummaryError(f"expected rejection did not occur: {label}")


def self_test() -> None:
    root = Path("evidence/lab/observe-summary-check-self-test")
    shutil.rmtree(root, ignore_errors=True)
    good = write_fixture(root / "good")
    validate_observe(good)
    release_bad = write_fixture(root / "release-bad", release_proof=True)
    reject(release_bad, "fixture release proof")
    relabeled = write_fixture(root / "relabeled", mode="vm-live", release_proof=True)
    reject(relabeled, "vm-live relabel without proof")
    forged = write_fixture(root / "forged", mode="vm-live", release_proof=True)
    payload = load_object(forged)
    payload["vm_live_proof"] = {
        "vm_kind": "vm-live",
        "driver": "qemu",
        "copied_from_guest": True,
        "vm_marker_present": True,
        "vm_marker": "/run/zig-scheduler-vm-lab.marker",
        "release_proof_attestation_signed": True,
    }
    forged.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    reject(forged, "forged vm-live proof")
    vm_live = write_fixture(root / "vm-live", mode="vm-live", release_proof=False)
    validate_observe(vm_live)
    attach_only = write_fixture(root / "attach-only")
    samples = root / "attach-only/runtime-samples.jsonl"
    rows = [json.loads(line) for line in samples.read_text().splitlines()]
    rows = [row | {"ops": {"status": "present", "value": "none"}} for row in rows]
    samples.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))
    reject(attach_only, "missing zigsched_minimal sample")
    shutil.rmtree(root)
    print("PASS observe summary self-test: live-proof contradictions and attach-only evidence rejected")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.summary is None:
        raise ObserveSummaryError("internal argument parser error")
    validate_observe(args.summary)
    print(f"PASS observe summary: {args.summary}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run(sys.argv[1:]))
    except (ObserveSummaryError, json.JSONDecodeError) as exc:
        print(f"FAIL observe summary: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
