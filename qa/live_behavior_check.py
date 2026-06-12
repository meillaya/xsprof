#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///

# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly:
#      uv run qa/live_behavior_check.py --bundle evidence/lab/run-all/<vm-live>/summary.json
# 3. Or with system Python (no dependencies):
#      python3 qa/live_behavior_check.py --self-test
# ──────────────────
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import re
import shutil
import sys
from typing import Final, TypeAlias

_ = sys.path.insert(0, str(Path(__file__).resolve().parent))
_ = sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from qa.audit_ledger_check import AuditLedgerError, validate_ledger, write_good
from qa.lab_summary_observe import ObserveSummaryError, validate_observe
from qa.partial_attach_check import PartialAttachError, validate_evidence
from qa.runtime_sample_check import RuntimeSampleError, good_sample, validate_file

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SUMMARY_SCHEMA: Final[str] = "zig-scheduler/run-all-lab/v1"
VM_MARKER: Final[str] = "/run/zig-scheduler-vm-lab.marker"
TARGET_PREFIX: Final[str] = "/sys/fs/cgroup/zig-scheduler-lab.slice/"
COUNTER_RE: Final[re.Pattern[str]] = re.compile(r"(nr_rejected|dispatch_failed|fallbacks?|fatal)[:=]\s*([0-9]+)")
COUNTER_NAMES: Final[tuple[str, ...]] = ("nr_rejected", "dispatch_failed", "fallback", "fatal")
SHA256_RE: Final[re.Pattern[str]] = re.compile(r"^[0-9a-f]{64}$")
SELF_ROOT: Final[Path] = Path("evidence/lab/run-all/live-behavior-check-self-test")


@dataclass(frozen=True, slots=True)
class Args:
    bundle: Path | None
    self_test: bool


class LiveBehaviorError(Exception):
    """Raised when VM-live scheduler behavior proof is absent or unsafe."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(bundle=None, self_test=True)
    if len(argv) == 2 and argv[0] == "--bundle":
        return Args(bundle=Path(argv[1]), self_test=False)
    raise LiveBehaviorError("usage: live_behavior_check.py --bundle <run-all-summary.json> | --self-test")


def load_object(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise LiveBehaviorError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise LiveBehaviorError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise LiveBehaviorError(f"{path} must contain a JSON object")
    return raw


def load_jsonl(path: Path) -> list[JsonObject]:
    rows: list[JsonObject] = []
    for index, line in enumerate(path.read_text().splitlines(), start=1):
        if line.strip() == "":
            continue
        raw: JsonValue = json.loads(line)
        if not isinstance(raw, dict):
            raise LiveBehaviorError(f"{path}:{index} must contain a JSON object")
        rows.append(raw)
    if not rows:
        raise LiveBehaviorError(f"JSONL is empty: {path}")
    return rows


def require_text(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise LiveBehaviorError(f"{context} missing non-empty text field: {field}")
    return value


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise LiveBehaviorError(f"{context} missing bool field: {field}")
    return value


def require_list(data: JsonObject, field: str, context: str) -> list[JsonValue]:
    value = data.get(field)
    if not isinstance(value, list) or len(value) == 0:
        raise LiveBehaviorError(f"{context} missing non-empty list field: {field}")
    return value


def validate_bundle(path: Path) -> None:
    summary = load_object(path)
    if require_text(summary, "schema", "bundle") != SUMMARY_SCHEMA:
        raise LiveBehaviorError("bundle has unsupported schema")
    if require_text(summary, "status", "bundle") != "PASS":
        raise LiveBehaviorError("bundle status must be PASS")
    if require_bool(summary, "host_mutation", "bundle"):
        raise LiveBehaviorError("bundle host_mutation must be false")
    validate_vm_live_gate(summary)
    artifacts = artifact_paths(summary)
    partial = require_artifact(artifacts, "partial-attach-evidence.json")
    observe = require_artifact(artifacts, "observe-partial/summary.json")
    samples = require_artifact(artifacts, "runtime-samples.jsonl")
    daemon_events = require_artifact(artifacts, "daemon-runtime-events.jsonl")
    ledger = require_artifact(artifacts, "audit-ledger.jsonl")
    validate_evidence(partial)
    validate_observe(observe)
    validate_file(samples)
    validate_ledger(ledger)
    validate_partial_behavior(load_object(partial))
    validate_observe_behavior(load_object(observe))
    validate_samples(load_jsonl(samples))
    validate_daemon_events(load_jsonl(daemon_events))


def validate_vm_live_gate(summary: JsonObject) -> None:
    if require_text(summary, "evidence_mode", "bundle") != "vm-live":
        raise LiveBehaviorError("bundle is not VM-live evidence")
    if require_text(summary, "vm_kind", "bundle") != "qemu-vm":
        raise LiveBehaviorError("bundle must be from qemu-vm")
    if not require_bool(summary, "vm_marker_present", "bundle"):
        raise LiveBehaviorError("bundle missing VM marker")
    if require_text(summary, "vm_marker_path", "bundle") != VM_MARKER:
        raise LiveBehaviorError("bundle VM marker path is invalid")
    if require_text(summary, "rollback_result", "bundle") != "PASS":
        raise LiveBehaviorError("bundle rollback_result must be PASS")


def artifact_paths(summary: JsonObject) -> list[Path]:
    paths: list[Path] = []
    for index, value in enumerate(require_list(summary, "artifact_paths", "bundle")):
        if not isinstance(value, str) or value == "":
            raise LiveBehaviorError(f"bundle.artifact_paths[{index}] must be path text")
        path = Path(value)
        if path.is_absolute() or ".." in path.parts or not path.exists():
            raise LiveBehaviorError(f"bundle artifact path is unsafe or missing: {value}")
        paths.append(path)
    return paths


def require_artifact(paths: list[Path], suffix: str) -> Path:
    for path in paths:
        if path.as_posix().endswith(suffix):
            return path
    raise LiveBehaviorError(f"bundle missing artifact: {suffix}")


def validate_partial_behavior(partial: JsonObject) -> None:
    if require_text(partial, "ops_during_attach", "partial") != "zigsched_minimal":
        raise LiveBehaviorError("partial attach did not run zigsched_minimal")
    if require_text(partial, "switch_mode", "partial") != "SCX_OPS_SWITCH_PARTIAL":
        raise LiveBehaviorError("partial attach was not partial-switch")
    if not require_text(partial, "target_cgroup", "partial").startswith(TARGET_PREFIX):
        raise LiveBehaviorError("partial attach target is not allowlisted")
    object_sha = require_text(partial, "object_sha256", "partial")
    if not SHA256_RE.match(object_sha) or object_sha == "0" * 64:
        raise LiveBehaviorError("partial attach object hash is malformed")


def validate_observe_behavior(observe: JsonObject) -> None:
    if require_text(observe, "evidence_mode", "observe") != "vm-live":
        raise LiveBehaviorError("observe summary is not VM-live")
    if not require_bool(observe, "workload_alive_all_samples", "observe"):
        raise LiveBehaviorError("workload was not alive across samples")
    if not require_bool(observe, "final_state_disabled_or_rolled_back", "observe"):
        raise LiveBehaviorError("rollback did not restore scheduler state")


def validate_samples(rows: list[JsonObject]) -> None:
    if len(rows) < 3:
        raise LiveBehaviorError("behavior proof requires before/during/after samples")
    if sample_ops(rows[0]) == "zigsched_minimal":
        raise LiveBehaviorError("first sample must be before attach")
    if not any(sample_ops(row) == "zigsched_minimal" for row in rows[1:-1]):
        raise LiveBehaviorError("middle samples never show zigsched_minimal during attach")
    if sample_ops(rows[-1]) == "zigsched_minimal":
        raise LiveBehaviorError("last sample must be after rollback")
    if sample_state(rows[-1]) not in {"disabled", "previous"}:
        raise LiveBehaviorError("last sample does not prove rollback-restored state")
    if not all(row.get("workload_alive") is True for row in rows):
        raise LiveBehaviorError("workload is not alive in every sample")
    if not all(isinstance(row.get("cgroup_membership_digest"), str) and row["cgroup_membership_digest"] != "" for row in rows):
        raise LiveBehaviorError("samples lack cgroup membership digest")
    validate_counter_growth(rows)


def validate_counter_growth(rows: list[JsonObject]) -> None:
    first = parse_counters(rows[0])
    last = parse_counters(rows[-1])
    for name in COUNTER_NAMES:
        if name not in first or name not in last:
            raise LiveBehaviorError(f"samples must expose counter: {name}")
        if last[name] > first[name]:
            raise LiveBehaviorError(f"fatal/reject/fallback counter grew: {name}")


def sample_ops(row: JsonObject) -> str:
    ops = row.get("ops")
    if not isinstance(ops, dict):
        return ""
    value = ops.get("value")
    return value if isinstance(value, str) else ""


def sample_state(row: JsonObject) -> str:
    state = row.get("state")
    if not isinstance(state, dict):
        return ""
    value = state.get("value")
    return value if isinstance(value, str) else ""


def parse_counters(row: JsonObject) -> dict[str, int]:
    events = row.get("events")
    if not isinstance(events, dict):
        return {}
    raw = events.get("value")
    if not isinstance(raw, str):
        return {}
    return {match.group(1): int(match.group(2)) for match in COUNTER_RE.finditer(raw)}


def validate_daemon_events(rows: list[JsonObject]) -> None:
    for row in rows:
        if row.get("host_mutation") is not False:
            raise LiveBehaviorError("daemon events must explicitly report host_mutation=false")
    runtime = [row for row in rows if row.get("event") == "runtime_sample"]
    if not runtime:
        raise LiveBehaviorError("daemon emitted no runtime_sample events")
    if not any(row.get("ops") == "zigsched_minimal" for row in runtime):
        raise LiveBehaviorError("daemon events never show zigsched_minimal")


def self_test() -> None:
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    good = write_bundle(SELF_ROOT / "good")
    validate_bundle(good)
    reject(write_bundle(SELF_ROOT / "attach-only", include_observe=False), "attach-only proof")
    reject(write_bundle(SELF_ROOT / "counter-growth", counter_growth=True), "counter growth")
    reject(write_bundle(SELF_ROOT / "host-mutation", host_mutation=True), "host mutation")
    reject(write_bundle(SELF_ROOT / "all-during", all_during=True), "missing before/after phases")
    reject(write_bundle(SELF_ROOT / "missing-counters", missing_counters=True), "missing counter families")
    reject(write_bundle(SELF_ROOT / "bad-object-sha", bad_object_sha=True), "bad object sha")
    reject(write_bundle(SELF_ROOT / "missing-daemon-host-mutation", missing_daemon_host_mutation=True), "missing daemon host mutation")
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    print("PASS live behavior self-test: full VM-live bundle accepted; attach-only and malformed bundles rejected")


def write_bundle(
    root: Path,
    *,
    include_observe: bool = True,
    counter_growth: bool = False,
    host_mutation: bool = False,
    all_during: bool = False,
    missing_counters: bool = False,
    bad_object_sha: bool = False,
    missing_daemon_host_mutation: bool = False,
) -> Path:
    partial_dir = root / "partial-attach"
    observe_dir = root / "observe-partial"
    rollback_dir = root / "rollback-drill"
    partial_dir.mkdir(parents=True)
    observe_dir.mkdir(parents=True)
    transcript = partial_dir / "partial-attach-transcript.txt"
    transcript.write_text("bpftool struct_ops register\nops=zigsched_minimal\nrollback_status=PASS\n")
    partial = partial_dir / "partial-attach-evidence.json"
    partial_data = partial_evidence(transcript)
    if bad_object_sha:
        partial_data["object_sha256"] = "not-a-sha"
    partial.write_text(json.dumps(partial_data, indent=2, sort_keys=True) + "\n")
    ledger = write_good(rollback_dir, "AUD-20990101T000000Z-deadbee-abc123", "RB-live")
    artifacts = [partial.as_posix(), ledger.as_posix()]
    if include_observe:
        samples = observe_dir / "runtime-samples.jsonl"
        samples.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in sample_rows(counter_growth, all_during, missing_counters)))
        daemon = observe_dir / "daemon-runtime-events.jsonl"
        daemon_event: JsonObject = {"schema": "zig-scheduler/daemon-event/v1", "event": "runtime_sample", "ops": "zigsched_minimal", "host_mutation": False}
        if missing_daemon_host_mutation:
            del daemon_event["host_mutation"]
        daemon.write_text(json.dumps(daemon_event, sort_keys=True) + "\n")
        transcript_path = observe_dir / "observe-transcript.txt"
        transcript_path.write_text("observe runtime samples\n")
        observe = observe_dir / "summary.json"
        observe.write_text(json.dumps(observe_summary(samples, daemon, ledger, transcript_path), indent=2, sort_keys=True) + "\n")
        artifacts.extend([observe.as_posix(), samples.as_posix(), daemon.as_posix(), transcript_path.as_posix()])
    summary = root / "summary.json"
    summary.write_text(json.dumps(bundle_summary(artifacts, host_mutation), indent=2, sort_keys=True) + "\n")
    return summary


def partial_evidence(transcript: Path) -> JsonObject:
    return {"attach_command": "bpftool struct_ops register", "host_mutation": False, "object": "zig-out/bpf/zigsched_minimal.bpf.o", "object_sha256": "a" * 64, "ops_during_attach": "zigsched_minimal", "post_state": "disabled", "release_eligible_live_proof": False, "rollback_id": "RB-live", "rollback_status": "PASS", "schema": "zig-scheduler/partial-attach-evidence/v1", "switch_mode": "SCX_OPS_SWITCH_PARTIAL", "target_cgroup": f"{TARGET_PREFIX}demo.scope", "transcript_path": transcript.as_posix()}


def sample_rows(counter_growth: bool, all_during: bool, missing_counters: bool) -> list[JsonObject]:
    rows: list[JsonObject] = []
    ops_values = ("zigsched_minimal", "zigsched_minimal", "zigsched_minimal") if all_during else ("none", "zigsched_minimal", "none")
    for sequence, ops in enumerate(ops_values):
        row = good_sample()
        counters = f"nr_rejected: {1 if counter_growth and sequence == 2 else 0}"
        if not missing_counters:
            counters = f"{counters} dispatch_failed: 0 fallback: 0 fatal: 0"
        row.update({"sequence": sequence, "ops": {"status": "present", "value": ops}, "state": {"status": "present", "value": "enabled" if sequence < 2 or all_during else "disabled"}, "events": {"status": "present", "value": counters}, "cgroup_membership_digest": f"digest-{sequence}"})
        rows.append(row)
    return rows


def observe_summary(samples: Path, daemon: Path, ledger: Path, transcript: Path) -> JsonObject:
    return {"audit_ledger": ledger.as_posix(), "daemon_runtime_events": daemon.as_posix(), "evidence_mode": "vm-live", "final_ops": "none", "final_state": "disabled", "final_state_disabled_or_rolled_back": True, "private_command_lines_sampled": False, "release_eligible_live_proof": False, "runtime_samples": samples.as_posix(), "sample_count": 3, "scheduler_snapshot": {"root_ops": {"status": "present", "value": "none"}, "state": {"status": "present", "value": "disabled"}}, "schema": "zig-scheduler/observe-partial-summary/v1", "status": "PASS", "transcript": transcript.as_posix(), "workload_alive_all_samples": True}


def bundle_summary(artifacts: list[str], host_mutation: bool) -> JsonObject:
    return {"artifact_paths": artifacts, "evidence_mode": "vm-live", "host_mutation": host_mutation, "release_eligible_live_proof": False, "rollback_result": "PASS", "schema": SUMMARY_SCHEMA, "status": "PASS", "vm_kind": "qemu-vm", "vm_marker_path": VM_MARKER, "vm_marker_present": True}


def reject(path: Path, label: str) -> None:
    try:
        validate_bundle(path)
    except (AuditLedgerError, LiveBehaviorError, ObserveSummaryError, PartialAttachError, RuntimeSampleError, json.JSONDecodeError) as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise LiveBehaviorError(f"expected rejection did not occur: {label}")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.bundle is None:
        raise LiveBehaviorError("internal argument parser error")
    validate_bundle(args.bundle)
    print(f"PASS live behavior bundle: {args.bundle}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run(sys.argv[1:]))
    except (AuditLedgerError, LiveBehaviorError, ObserveSummaryError, PartialAttachError, RuntimeSampleError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL live behavior bundle: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
