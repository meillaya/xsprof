#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/protected_core_telemetry_check.py --self-test
# python3 qa/protected_core_telemetry_check.py --input evidence/lab/matrix/<run>/rows/<row>/runtime-sample.jsonl --scenario live-backend
# python3 qa/protected_core_telemetry_check.py --manifest evidence/lab/matrix/<run>/manifest.json
# ──────────────────
"""Protected-core runtime telemetry normalization checker."""
from __future__ import annotations

from dataclasses import dataclass
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Final, TypeAlias

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from qa.runtime_sample_common import JsonObject, JsonValue, RuntimeSampleError, json_loader, load_jsonl, reject_private_leaks, require_object
from qa.runtime_sample_core import good_sample, validate_file
from qa.runtime_sample_policy_abi import ABI_LABEL

UNAVAILABLE_VALUES: Final[frozenset[str]] = frozenset({"", "missing", "none", "null", "unavailable", "unknown"})
UNAVAILABLE_STATUSES: Final[frozenset[str]] = frozenset({"missing", "unreadable", "unknown"})
REQUIRED_FACTS: Final[tuple[str, ...]] = ("state", "ops", "root_ops", "enable_seq", "events", "scheduler_events", "nr_rejected", "task_ext_enabled", "cgroup_membership_status", "workload")
REQUIRED_FIELDS: Final[tuple[str, ...]] = ("sample_source_event", "observation_source", "sched_ext_phase", "policy_abi", "cgroup_semantic_labels", "cgroup_membership_digest", "private_command_lines_sampled")
REQUIRED_TELEMETRY: Final[tuple[str, ...]] = ("policy_counters", "sample_loss", "dsq_depth", "queue_latency", "fairness", "scheduler_counters", "sched_ext_observation")
EVENT_COUNTER_RE: Final[re.Pattern[str]] = re.compile(r"(?:^|\s)nr_rejected\s*[:=]\s*([0-9]+)(?:\s|$)")
SELF_ROOT: Final[Path] = Path("evidence/lab/protected-core-telemetry-self-test")
CGROUP_SCENARIO: Final[str] = "workload-cgroup-weight-quota"

JsonRows: TypeAlias = list[JsonObject]


@dataclass(frozen=True, slots=True)
class Args:
    input_path: Path | None
    manifest: Path | None
    scenario: str | None
    self_test: bool


class ProtectedCoreTelemetryError(Exception):
    """Raised when protected-core telemetry omits normalized facts."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(input_path=None, manifest=None, scenario=None, self_test=True)
    if len(argv) in {2, 4} and argv[0] == "--input":
        scenario = None
        if len(argv) == 4:
            if argv[2] != "--scenario":
                raise ProtectedCoreTelemetryError("usage: protected_core_telemetry_check.py --input <jsonl> [--scenario <id>] | --manifest <manifest> | --self-test")
            scenario = argv[3]
        return Args(input_path=Path(argv[1]), manifest=None, scenario=scenario, self_test=False)
    if len(argv) == 2 and argv[0] == "--manifest":
        return Args(input_path=None, manifest=Path(argv[1]), scenario=None, self_test=False)
    raise ProtectedCoreTelemetryError("usage: protected_core_telemetry_check.py --input <jsonl> [--scenario <id>] | --manifest <manifest> | --self-test")


def load_json(path: Path) -> JsonObject:
    try:
        raw = json_loader.loads(path.read_text())
    except FileNotFoundError as exc:
        raise ProtectedCoreTelemetryError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ProtectedCoreTelemetryError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ProtectedCoreTelemetryError(f"{path} must contain a JSON object")
    return raw


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProtectedCoreTelemetryError(message)


def is_unavailable_fact(value: JsonValue | None) -> bool:
    if not isinstance(value, dict):
        return False
    status = value.get("status")
    fact_value = value.get("value")
    return isinstance(status, str) and status in UNAVAILABLE_STATUSES and isinstance(fact_value, str) and fact_value.casefold() in UNAVAILABLE_VALUES


def fact_status(row: JsonObject, field: str, context: str) -> str:
    fact = row.get(field)
    if not isinstance(fact, dict):
        raise ProtectedCoreTelemetryError(f"{context}.{field} must be an explicit fact")
    status = fact.get("status")
    value = fact.get("value")
    if not isinstance(status, str) or not isinstance(value, str):
        raise ProtectedCoreTelemetryError(f"{context}.{field} must include status/value")
    return status


def fact_value(row: JsonObject, field: str) -> str:
    fact = row[field]
    return str(fact["value"]) if isinstance(fact, dict) else ""


def events_nr_rejected(row: JsonObject) -> int | None:
    events = row.get("events")
    if not isinstance(events, dict) or events.get("status") != "present":
        return None
    value = events.get("value")
    if not isinstance(value, str) or value.casefold() in UNAVAILABLE_VALUES:
        return None
    match = EVENT_COUNTER_RE.search(value)
    return int(match.group(1)) if match else None


def require_metric_or_unavailable(row: JsonObject, field: str, context: str) -> JsonObject:
    value = row.get(field)
    if not isinstance(value, dict):
        raise ProtectedCoreTelemetryError(f"{context}.{field} must be present as metrics or explicit unavailable fact")
    if is_unavailable_fact(value):
        return value
    reject_private_leaks(value, f"{context}.{field}")
    return value


def validate_row(row: JsonObject, index: int, scenario: str | None) -> None:
    context = f"sample[{index}]"
    for field in REQUIRED_FIELDS:
        require(field in row, f"{context} missing protected telemetry field: {field}")
    for field in REQUIRED_FACTS:
        _ = fact_status(row, field, context)
    for field in REQUIRED_TELEMETRY:
        _ = require_metric_or_unavailable(row, field, context)
    events_counter = events_nr_rejected(row)
    nr_status = fact_status(row, "nr_rejected", context)
    nr_value = fact_value(row, "nr_rejected")
    if events_counter is None:
        require(nr_status in UNAVAILABLE_STATUSES and nr_value.casefold() in UNAVAILABLE_VALUES, f"{context}.nr_rejected must be unavailable when events are unavailable")
        require(is_unavailable_fact(row.get("policy_counters")), f"{context}.policy_counters must be unavailable when events are unavailable")
    else:
        require(nr_status == "present" and nr_value.isdecimal(), f"{context}.nr_rejected must be numeric when events are present")
        require(int(nr_value) == events_counter, f"{context}.nr_rejected must match events nr_rejected")
    if scenario == CGROUP_SCENARIO:
        policy_abi = require_object(row, "policy_abi", context)
        require(policy_abi.get("abi_version") == 3 and policy_abi.get("abi_label") == ABI_LABEL, f"{context}.policy_abi missing ABI-v3 metadata for cgroup-policy row")


def validate_rows(rows: JsonRows, scenario: str | None, label: str) -> None:
    if not rows:
        raise ProtectedCoreTelemetryError(f"{label} has no runtime samples")
    for index, row in enumerate(rows):
        validate_row(row, index, scenario)


def validate_input(path: Path, scenario: str | None) -> None:
    validate_file(path)
    validate_rows(load_jsonl(path), scenario, path.as_posix())


def safe_path(value: JsonValue | None, context: str) -> Path:
    if not isinstance(value, str) or value == "":
        raise ProtectedCoreTelemetryError(f"{context} must be a non-empty path")
    path = Path(value)
    require(not path.is_absolute() and ".." not in path.parts, f"{context} must be repo-relative and non-traversing")
    return path


def validate_manifest(path: Path) -> None:
    manifest = load_json(path)
    rows = manifest.get("rows")
    if not isinstance(rows, list):
        raise ProtectedCoreTelemetryError(f"{path}.rows must be a list")
    for index, ref in enumerate(rows):
        if not isinstance(ref, dict):
            raise ProtectedCoreTelemetryError(f"{path}.rows[{index}] must be an object")
        if ref.get("outcome") != "PASS":
            continue
        scenario = ref.get("scenario_id")
        if not isinstance(scenario, str) or scenario == "":
            raise ProtectedCoreTelemetryError(f"{path}.rows[{index}].scenario_id must be text")
        row = load_json(safe_path(ref.get("artifact_path"), f"{path}.rows[{index}].artifact_path"))
        if row.get("evidence_mode") != "vm-live":
            continue
        validate_input(safe_path(row.get("runtime_sample_path"), f"{path}.rows[{index}].runtime_sample_path"), scenario)


def expect_reject(path: Path, label: str, scenario: str | None = None) -> None:
    try:
        validate_input(path, scenario)
    except (ProtectedCoreTelemetryError, RuntimeSampleError) as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise ProtectedCoreTelemetryError(f"expected rejection did not occur: {label}")


def write_sample(path: Path, sample: JsonObject) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(json.dumps(sample, sort_keys=True) + "\n")
    return path


def self_test() -> None:
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    good = write_sample(SELF_ROOT / "good.jsonl", good_sample())
    validate_input(good, "live-backend")
    unavailable_events = good_sample()
    unavailable_events["events"] = {"status": "unknown", "value": "unavailable"}
    unavailable_events["nr_rejected"] = {"status": "present", "value": "0"}
    expect_reject(write_sample(SELF_ROOT / "unavailable-events-numeric-nr.jsonl", unavailable_events), "unavailable events numeric nr_rejected")
    fake_policy_counters = good_sample()
    fake_policy_counters["events"] = {"status": "unknown", "value": "unavailable"}
    fake_policy_counters["nr_rejected"] = {"status": "unknown", "value": "unavailable"}
    expect_reject(write_sample(SELF_ROOT / "unavailable-events-numeric-policy-counters.jsonl", fake_policy_counters), "unavailable events numeric policy counters")
    unavailable_metrics = good_sample()
    for field in ("sample_loss", "scheduler_counters", "fairness"):
        unavailable_metrics[field] = {"status": "unknown", "value": "unavailable"}
    validate_input(write_sample(SELF_ROOT / "explicit-unavailable-metrics.jsonl", unavailable_metrics), "live-backend")
    print("PASS accept explicit unavailable sample_loss scheduler_counters fairness")
    for field, label in (("fairness", "missing fairness"), ("sample_loss", "missing sample loss"), ("scheduler_counters", "missing scheduler counters")):
        sample = good_sample()
        del sample[field]
        expect_reject(write_sample(SELF_ROOT / f"{field}-missing.jsonl", sample), label)
    stale = good_sample()
    stale["enable_seq"] = {"status": "present", "value": "41"}
    _ = write_sample(SELF_ROOT / "stale.jsonl", stale)
    stale_next = good_sample()
    stale_next["sequence"] = 1
    stale_next["enable_seq"] = {"status": "present", "value": "40"}
    with (SELF_ROOT / "stale.jsonl").open("a") as handle:
        _ = handle.write(json.dumps(stale_next, sort_keys=True) + "\n")
    expect_reject(SELF_ROOT / "stale.jsonl", "stale enable_seq")
    missing_abi = good_sample()
    policy_abi = require_object(missing_abi, "policy_abi", "self-test")
    del policy_abi["abi_label"]
    expect_reject(write_sample(SELF_ROOT / "missing-cgroup-abi.jsonl", missing_abi), "missing cgroup ABI-v3 metadata", CGROUP_SCENARIO)
    private = good_sample()
    private["argv"] = ["demo"]
    expect_reject(write_sample(SELF_ROOT / "private-field.jsonl", private), "private field")
    claim = good_sample()
    policy_claim = require_object(claim, "policy_abi", "self-test claim")
    policy_claim["release_eligible"] = True
    expect_reject(write_sample(SELF_ROOT / "release-claim.jsonl", claim), "release claim")
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    print("PASS protected-core telemetry self-test")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.input_path is not None:
        validate_input(args.input_path, args.scenario)
        print(f"PASS protected-core telemetry: {args.input_path}")
        return 0
    if args.manifest is not None:
        validate_manifest(args.manifest)
        print(f"PASS protected-core telemetry manifest: {args.manifest}")
        return 0
    raise ProtectedCoreTelemetryError("internal argument parser error")


if __name__ == "__main__":
    try:
        raise SystemExit(run(sys.argv[1:]))
    except (ProtectedCoreTelemetryError, RuntimeSampleError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL protected-core telemetry: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
