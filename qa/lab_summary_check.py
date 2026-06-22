#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly (no venv, no pip install needed):
#      uv run qa/lab_summary_check.py --summary evidence/lab/run-all/<name>/summary.json
# 3. Or with system Python (no dependencies):
#      python3 qa/lab_summary_check.py --self-test
# ──────────────────
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import subprocess
import sys
from typing import Final

_ = sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from qa.evidence_safety_check import EvidenceSafetyError, JsonObject, JsonValue, reject_contradictions
from qa.lab_summary_backend import BackendSummaryError, VM_BACKEND_SCHEMA, is_backend_live_summary, validate_backend_live_summary, validate_backend_run_summary
from qa.lab_summary_observe import ObserveSummaryError, validate_observe

SUMMARY_SCHEMA: Final[str] = "zig-scheduler/run-all-lab/v1"
STAGE_SCHEMA: Final[str] = "zig-scheduler/run-all-stage/v1"
STATUSES: Final[frozenset[str]] = frozenset({"PASS", "SKIP", "REFUSE"})
ROLLBACK_RESULTS: Final[frozenset[str]] = frozenset({"PASS", "SKIP", "REFUSE", "N/A"})
PARTIAL_REASON_CODES: Final[frozenset[str]] = frozenset({"HOST_REFUSED", "VM_MARKER_MISSING", "TARGET_NOT_ALLOWLISTED", "TARGET_SYMLINK_REJECTED", "VERIFIER_FAILED", "ROLLBACK_MISSING", "ATTACH_SKIPPED", "ATTACH_ATTEMPTED", "ROLLBACK_RESTORED", "REFUSED_STALE_SCOPE"})
RUN_ALL_PREFIX: Final[Path] = Path("evidence/lab/run-all")
@dataclass(frozen=True, slots=True)
class Args:
    summary: Path | None
    partial: Path | None
    observe: Path | None
    self_test: bool


class LabSummaryError(Exception):
    """Raised when run-all lab evidence is malformed or unsafe."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(summary=None, partial=None, observe=None, self_test=True)
    if len(argv) == 2 and argv[0] == "--summary":
        return Args(summary=Path(argv[1]), partial=None, observe=None, self_test=False)
    if len(argv) == 2 and argv[0] == "--partial":
        return Args(summary=None, partial=Path(argv[1]), observe=None, self_test=False)
    if len(argv) == 2 and argv[0] == "--observe":
        return Args(summary=None, partial=None, observe=Path(argv[1]), self_test=False)
    raise LabSummaryError("usage: lab_summary_check.py --summary <summary.json> | --partial <partial-refusal.json> | --observe <summary.json> | --self-test")


def load_object(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise LabSummaryError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise LabSummaryError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise LabSummaryError(f"{path} must contain a JSON object")
    return raw


def require_string(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise LabSummaryError(f"{context} missing non-empty string field: {field}")
    return value


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise LabSummaryError(f"{context} missing bool field: {field}")
    return value


def require_list(data: JsonObject, field: str, context: str) -> list[JsonValue]:
    value = data.get(field)
    if not isinstance(value, list):
        raise LabSummaryError(f"{context} missing list field: {field}")
    return value


def require_object(data: JsonObject, field: str, context: str) -> JsonObject:
    value = data.get(field)
    if not isinstance(value, dict):
        raise LabSummaryError(f"{context} missing object field: {field}")
    return value


def assert_timestamp(value: str, context: str, field: str) -> None:
    if "T" not in value or not value.endswith("Z"):
        raise LabSummaryError(f"{context} field {field} must be UTC ISO-8601 text ending in Z")


def assert_kernel_tuple(data: JsonObject, context: str) -> None:
    kernel = require_object(data, "kernel_tuple", context)
    for field in ("release", "arch", "config_sha256"):
        require_string(kernel, field, f"{context}.kernel_tuple")


def assert_artifact_paths(data: JsonObject, context: str) -> list[Path]:
    values = require_list(data, "artifact_paths", context)
    paths: list[Path] = []
    for index, value in enumerate(values):
        if not isinstance(value, str) or value == "":
            raise LabSummaryError(f"{context}.artifact_paths[{index}] must be non-empty relative path text")
        path = Path(value)
        if path.is_absolute() or ".." in path.parts:
            raise LabSummaryError(f"{context}.artifact_paths[{index}] escapes repository: {value}")
        if path != RUN_ALL_PREFIX and RUN_ALL_PREFIX not in path.parents:
            raise LabSummaryError(f"{context}.artifact_paths[{index}] must stay under {RUN_ALL_PREFIX}: {value}")
        if not path.exists():
            raise LabSummaryError(f"{context}.artifact_paths[{index}] does not exist: {value}")
        paths.append(path)
    if len(paths) == 0:
        raise LabSummaryError(f"{context} must include at least one artifact path")
    return paths


def assert_common(data: JsonObject, context: str) -> list[Path]:
    if require_bool(data, "host_mutation", context):
        raise LabSummaryError(f"{context} host_mutation must be false")
    require_string(data, "git_sha", context)
    assert_kernel_tuple(data, context)
    require_string(data, "vm_kind", context)
    rollback_result = require_string(data, "rollback_result", context)
    if rollback_result not in ROLLBACK_RESULTS:
        raise LabSummaryError(f"{context} rollback_result has invalid status: {rollback_result}")
    for field in ("started_at", "ended_at"):
        assert_timestamp(require_string(data, field, context), context, field)
    return assert_artifact_paths(data, context)


def validate_stage(stage: JsonObject, index: int) -> list[Path]:
    context = f"stage[{index}]"
    if require_string(stage, "schema", context) != STAGE_SCHEMA:
        raise LabSummaryError(f"{context} has unsupported schema")
    status = require_string(stage, "status", context)
    if status not in STATUSES:
        raise LabSummaryError(f"{context} has invalid status: {status}")
    for field in ("stage", "reason", "command"):
        require_string(stage, field, context)
    return assert_common(stage, context)


def git_tracked(path: Path) -> bool:
    result = subprocess.run(["git", "ls-files", "--error-unmatch", path.as_posix()], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return result.returncode == 0


def validate_summary(path: Path) -> None:
    summary = load_object(path)
    schema = require_string(summary, "schema", "summary")
    if schema == VM_BACKEND_SCHEMA:
        validate_backend_run_summary(path, summary)
        return
    if schema != SUMMARY_SCHEMA:
        raise LabSummaryError("summary has unsupported schema")
    if is_backend_live_summary(path, summary):
        validate_backend_live_summary(path, summary)
        return
    status = require_string(summary, "status", "summary")
    if status not in STATUSES:
        raise LabSummaryError(f"summary has invalid status: {status}")
    require_string(summary, "mode", "summary")
    require_string(summary, "release_status", "summary")
    reject_contradictions(summary, "summary")
    summary_paths = assert_common(summary, "summary")
    release_use = require_bool(summary, "release_use", "summary")
    stages = require_list(summary, "stages", "summary")
    if len(stages) == 0 and status != "REFUSE":
        raise LabSummaryError("summary must include stage records unless it is a refusal")
    stage_paths: list[Path] = []
    for index, item in enumerate(stages):
        if not isinstance(item, dict):
            raise LabSummaryError(f"stage[{index}] must be an object")
        stage_paths.extend(validate_stage(item, index))
    if release_use:
        for artifact_path in [*summary_paths, *stage_paths]:
            if not git_tracked(artifact_path):
                raise LabSummaryError(f"release_use evidence path is not tracked: {artifact_path}")


def validate_partial(path: Path) -> None:
    refusal = load_object(path)
    if require_string(refusal, "schema", "partial") != "zig-scheduler/partial-attach-refusal/v1":
        raise LabSummaryError("partial refusal has unsupported schema")
    if require_string(refusal, "status", "partial") != "refused-host":
        raise LabSummaryError("partial refusal status must be refused-host")
    if require_bool(refusal, "host_mutation", "partial"):
        raise LabSummaryError("partial refusal host_mutation must be false")
    code = require_string(refusal, "reason_code", "partial")
    if code not in PARTIAL_REASON_CODES:
        raise LabSummaryError(f"partial refusal reason_code is unknown: {code}")
    for field in ("reason", "target_cgroup", "audit_id", "rollback_id"):
        require_string(refusal, field, "partial")



def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        from qa.lab_summary_selftest import self_test
        self_test()
        return 0
    if args.summary is None:
        if args.partial is None and args.observe is None:
            raise LabSummaryError("internal argument parser error")
        if args.partial is not None:
            validate_partial(args.partial)
            print(f"PASS partial attach refusal schema: {args.partial}")
        else:
            if args.observe is None:
                raise LabSummaryError("internal argument parser error")
            try: validate_observe(args.observe)
            except ObserveSummaryError as exc: raise LabSummaryError(str(exc)) from exc
            print(f"PASS observe partial summary: {args.observe}")
        return 0
    validate_summary(args.summary)
    print(f"PASS lab summary schema: {args.summary}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (BackendSummaryError, EvidenceSafetyError, LabSummaryError) as exc:
        print(f"FAIL lab summary schema: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
