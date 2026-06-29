#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# noqa: SIZE_OK — standalone contract checker keeps schema, fixture, and self-test gates together.
# python3 qa/matrix_run_contract_check.py --fixtures fixtures/matrix-run --schemas schemas/control --docs docs/control
from __future__ import annotations

import argparse
import json
import re
from collections.abc import Callable
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import TYPE_CHECKING, Final, NoReturn, Protocol, TypeAlias, assert_never

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SCHEMA: Final = "zig-scheduler/matrix-run/v1"
SCHEMA_FILE: Final = "matrix-run.v1.schema.json"
DOC_FILE: Final = "matrix-run-contract.md"
VM_MARKER: Final = "/run/zig-scheduler-vm-lab.marker"
OUTCOMES: Final = frozenset({"PASS", "SKIP", "REFUSE", "INCIDENT", "FAIL"})
EVIDENCE_MODES: Final = frozenset({"vm-live", "host-refusal-only"})
TUPLE_STATUS: Final = frozenset({"supported", "unsupported", "unknown"})
REQUIRED_FIXTURES: Final = frozenset({"pass.json", "skip-unsupported-tuple.json", "host-refusal-only.json", "incident-verifier-reject.json", "rollback-failure.json", "cleanup-residue.json"})
REQUIRED_INVALID_FIXTURES: Final = frozenset({"host-mutation-true.json", "release-eligible-true.json", "invalid-outcome.json", "stale-git.json", "dirty-git.json", "missing-vm-marker.json", "unsafe-absolute-path.json", "unsafe-traversal-path.json", "missing-rollback-proof.json", "missing-cleanup-proof.json", "missing-cleanup-proof-on-skip.json", "missing-cleanup-proof-on-refuse.json", "missing-host-refusal-proof.json", "privacy-failed.json", "malformed.json", "extra-property.json"})
PATH_FIELDS: Final = ("runtime_sample_path", "incident_path", "rollback_proof_path", "cleanup_proof_path", "host_refusal_proof_path")
ROW_FIELDS: Final = frozenset(("schema", "matrix_run_id", "scenario_id", "outcome", "evidence_mode", "kernel_tuple", "supported_tuple_status", "vm_marker", "bpf_abi_version", "policy", "workload", "action_id", "audit_id", "rollback_id", "pre_scheduler_state", "post_scheduler_state", "pre_cgroup_state", "post_cgroup_state", "runtime_sample_path", "incident_path", "rollback_proof_path", "cleanup_proof_path", "host_refusal_proof_path", "privacy_scan", "git", "release_eligible", "host_mutation"))
KERNEL_TUPLE_FIELDS: Final = frozenset(("kernel_release", "arch", "btf", "kvm", "sched_ext"))
VM_MARKER_FIELDS: Final = frozenset(("required", "present", "path", "checked_by"))
POLICY_FIELDS: Final = frozenset(("name", "object_path", "object_sha256", "source_path", "source_sha256"))
WORKLOAD_FIELDS: Final = frozenset(("name", "spec_path", "spec_sha256"))
PRIVACY_SCAN_FIELDS: Final = frozenset(("status", "private_fields_found", "report_path"))
GIT_FIELDS: Final = frozenset(("expected_sha", "actual_sha", "status", "dirty"))
ID_RE: Final = re.compile(r"^[A-Za-z0-9_.-]{1,96}$")
AUDIT_RE: Final = re.compile(r"^AUD-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9_.-]+$")
SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
SAFE_RELATIVE_PATH_PATTERN: Final = r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$)).+$"
SCHEMA_PATH_FIELDS: Final = (("runtime_sample_path",), ("incident_path",), ("rollback_proof_path",), ("cleanup_proof_path",), ("host_refusal_proof_path",), ("policy", "object_path"), ("policy", "source_path"), ("workload", "spec_path"), ("privacy_scan", "report_path"))
PRIVATE_NEEDLES: Final = ("cmdline", "command_line", "argv", "environment", "secret", "api_key", "token", "password", "authorization", "bearer")


@dataclass(frozen=True, slots=True)
class Args:
    fixtures: Path
    schemas: Path
    docs: Path
    self_test: bool


class MatrixRunContractError(Exception):
    pass


class JsonLoader(Protocol):
    def loads(self, text: str, *, parse_constant: Callable[[str], NoReturn]) -> JsonValue: ...


class ParsedArgs(argparse.Namespace):
    fixtures: Path
    schemas: Path
    docs: Path

    def __init__(self) -> None:
        super().__init__()
        self.fixtures = Path()
        self.schemas = Path()
        self.docs = Path()


if TYPE_CHECKING:
    json_loader: JsonLoader
else:
    json_loader = json


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("fixtures/matrix-run"), Path("schemas/control"), Path("docs/control"), True)
    parser = argparse.ArgumentParser(description="Validate standalone matrix-run/v1 evidence manifests.")
    _ = parser.add_argument("--fixtures", required=True, type=Path)
    _ = parser.add_argument("--schemas", required=True, type=Path)
    _ = parser.add_argument("--docs", required=True, type=Path)
    parsed = parser.parse_args(argv, namespace=ParsedArgs())
    return Args(parsed.fixtures, parsed.schemas, parsed.docs, False)


def reject_constant(value: str) -> NoReturn:
    raise MatrixRunContractError(f"invalid JSON constant: {value}")


def load_json(path: Path) -> JsonObject:
    try:
        raw = json_loader.loads(path.read_text(), parse_constant=reject_constant)
    except FileNotFoundError as exc:
        raise MatrixRunContractError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise MatrixRunContractError(f"invalid JSON in {path} at byte {exc.pos}: {exc.msg}") from exc
    return obj(raw, str(path))


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise MatrixRunContractError(f"{context} must be an object")
    return value


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise MatrixRunContractError(f"{context} must be non-empty text")
    return value


def bool_field(value: JsonValue | None, context: str) -> bool:
    if not isinstance(value, bool):
        raise MatrixRunContractError(f"{context} must be a boolean")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MatrixRunContractError(message)


def require_only_fields(row: JsonObject, allowed: frozenset[str], context: str) -> None:
    extra = sorted(set(row) - allowed)
    require(not extra, f"{context} has unexpected field(s): {', '.join(extra)}")


def reject_private(value: JsonValue, context: str) -> None:
    match value:
        case dict():
            for key, child in value.items():
                lowered = key.lower()
                require(not any(needle in lowered for needle in PRIVATE_NEEDLES), f"privacy-unsafe key in {context}.{key}")
                reject_private(child, f"{context}.{key}")
        case list():
            for index, child in enumerate(value):
                reject_private(child, f"{context}[{index}]")
        case str():
            lowered = value.lower()
            require(not any(needle in lowered for needle in PRIVATE_NEEDLES), f"privacy-unsafe text in {context}")
        case None | bool() | int() | float():
            return
        case unreachable:
            assert_never(unreachable)


def require_safe_path(value: JsonValue | None, context: str) -> str:
    raw = text(value, context)
    path = Path(raw)
    require(not path.is_absolute() and ".." not in path.parts, f"{context} must be relative and non-traversing: {raw}")
    return raw


def require_identifier(row: JsonObject, field: str, pattern: re.Pattern[str], context: str) -> None:
    raw = text(row.get(field), f"{context}.{field}")
    require(pattern.fullmatch(raw) is not None, f"{context}.{field} is not a stable identifier")


def require_sha(row: JsonObject, field: str, context: str) -> None:
    raw = text(row.get(field), f"{context}.{field}")
    require(SHA256_RE.fullmatch(raw) is not None, f"{context}.{field} must be sha256 hex")


def validate_schema_file(schemas: Path) -> None:
    schema = load_json(schemas / SCHEMA_FILE)
    require(schema.get("$id") == SCHEMA, f"{SCHEMA_FILE} has wrong $id")
    row_schema = obj(obj(schema.get("properties"), f"{SCHEMA_FILE}.properties").get("schema"), f"{SCHEMA_FILE}.properties.schema")
    require(row_schema.get("const") == SCHEMA, f"{SCHEMA_FILE} row schema const mismatch")
    required = schema.get("required")
    if not isinstance(required, list):
        raise MatrixRunContractError(f"{SCHEMA_FILE}.required must be a list")
    required_names = {item for item in required if isinstance(item, str)}
    missing = sorted(field for field in required_fields() if field not in required_names)
    require(not missing, f"{SCHEMA_FILE} missing required fields: {', '.join(missing)}")
    properties = obj(schema.get("properties"), f"{SCHEMA_FILE}.properties")
    for path_field in SCHEMA_PATH_FIELDS:
        schema_node = properties
        field_context = ".".join(path_field)
        for segment in path_field:
            schema_node = obj(schema_node.get(segment), f"{SCHEMA_FILE}.properties.{field_context}") if segment == path_field[-1] else obj(obj(schema_node.get(segment), f"{SCHEMA_FILE}.properties.{segment}").get("properties"), f"{SCHEMA_FILE}.properties.{segment}.properties")
        require(schema_node.get("pattern") == SAFE_RELATIVE_PATH_PATTERN, f"{SCHEMA_FILE}.{field_context} missing safe relative path pattern")


def required_fields() -> tuple[str, ...]:
    return tuple(sorted(ROW_FIELDS))


def validate_docs(docs: Path) -> None:
    try:
        text_value = (docs / DOC_FILE).read_text().lower()
    except FileNotFoundError as exc:
        raise MatrixRunContractError(f"missing doc: {docs / DOC_FILE}") from exc
    for needle in (SCHEMA, "standalone", "not a daemon-event", "host_mutation", "release_eligible", "relative", "rollback_proof_path", "cleanup_proof_path", "host_refusal_proof_path"):
        require(needle.lower() in text_value, f"{DOC_FILE} missing required text: {needle}")


def validate_row(row: JsonObject, context: str) -> None:
    require_only_fields(row, ROW_FIELDS, context)
    require(set(required_fields()).issubset(row), f"{context} missing required fields")
    require(row.get("schema") == SCHEMA, f"{context} bad schema")
    require(text(row.get("outcome"), f"{context}.outcome") in OUTCOMES, f"{context}.outcome invalid")
    mode = text(row.get("evidence_mode"), f"{context}.evidence_mode")
    require(mode in EVIDENCE_MODES, f"{context}.evidence_mode invalid")
    require(text(row.get("supported_tuple_status"), f"{context}.supported_tuple_status") in TUPLE_STATUS, f"{context}.supported_tuple_status invalid")
    require(row.get("host_mutation") is False, f"{context}.host_mutation must be false")
    require(row.get("release_eligible") is False, f"{context}.release_eligible must be false")
    for field in ("matrix_run_id", "scenario_id", "action_id", "rollback_id"):
        require_identifier(row, field, ID_RE, context)
    require_identifier(row, "audit_id", AUDIT_RE, context)
    for field in PATH_FIELDS:
        _ = require_safe_path(row.get(field), f"{context}.{field}")
    for field in ("pre_scheduler_state", "post_scheduler_state", "pre_cgroup_state", "post_cgroup_state"):
        _ = obj(row.get(field), f"{context}.{field}")
    kernel_tuple = obj(row.get("kernel_tuple"), f"{context}.kernel_tuple")
    require_only_fields(kernel_tuple, KERNEL_TUPLE_FIELDS, f"{context}.kernel_tuple")
    validate_vm_marker(obj(row.get("vm_marker"), f"{context}.vm_marker"), mode, context)
    validate_policy(obj(row.get("policy"), f"{context}.policy"), context)
    validate_workload(obj(row.get("workload"), f"{context}.workload"), context)
    validate_privacy(obj(row.get("privacy_scan"), f"{context}.privacy_scan"), context)
    validate_git(obj(row.get("git"), f"{context}.git"), context)
    reject_private(row, context)


def validate_vm_marker(marker: JsonObject, mode: str, context: str) -> None:
    require_only_fields(marker, VM_MARKER_FIELDS, f"{context}.vm_marker")
    required = bool_field(marker.get("required"), f"{context}.vm_marker.required")
    present = bool_field(marker.get("present"), f"{context}.vm_marker.present")
    require(text(marker.get("path"), f"{context}.vm_marker.path") == VM_MARKER, f"{context}.vm_marker.path mismatch")
    _ = text(marker.get("checked_by"), f"{context}.vm_marker.checked_by")
    if mode == "vm-live":
        require(required and present, f"{context} VM-live row requires present VM marker")
    else:
        require(not required and not present, f"{context} host-refusal-only row must not claim VM marker")


def validate_policy(policy: JsonObject, context: str) -> None:
    require_only_fields(policy, POLICY_FIELDS, f"{context}.policy")
    for field in ("name", "object_path", "source_path"):
        _ = text(policy.get(field), f"{context}.policy.{field}")
    _ = require_safe_path(policy.get("object_path"), f"{context}.policy.object_path")
    _ = require_safe_path(policy.get("source_path"), f"{context}.policy.source_path")
    require_sha(policy, "object_sha256", f"{context}.policy")
    require_sha(policy, "source_sha256", f"{context}.policy")


def validate_workload(workload: JsonObject, context: str) -> None:
    require_only_fields(workload, WORKLOAD_FIELDS, f"{context}.workload")
    _ = text(workload.get("name"), f"{context}.workload.name")
    _ = require_safe_path(workload.get("spec_path"), f"{context}.workload.spec_path")
    require_sha(workload, "spec_sha256", f"{context}.workload")


def validate_privacy(scan: JsonObject, context: str) -> None:
    require_only_fields(scan, PRIVACY_SCAN_FIELDS, f"{context}.privacy_scan")
    require(scan.get("status") == "PASS", f"{context}.privacy_scan.status must be PASS")
    require(scan.get("private_fields_found") is False, f"{context}.privacy_scan.private_fields_found must be false")
    _ = require_safe_path(scan.get("report_path"), f"{context}.privacy_scan.report_path")


def validate_git(git: JsonObject, context: str) -> None:
    require_only_fields(git, GIT_FIELDS, f"{context}.git")
    expected = text(git.get("expected_sha"), f"{context}.git.expected_sha")
    actual = text(git.get("actual_sha"), f"{context}.git.actual_sha")
    require(git.get("status") == "current", f"{context}.git.status must be current")
    require(git.get("dirty") is False, f"{context}.git.dirty must be false")
    require(expected == actual, f"{context}.git expected_sha must match actual_sha")


def fixture_names(path: Path) -> set[str]:
    return {child.name for child in path.glob("*.json") if child.is_file()}


def validate_fixture_pack(fixtures: Path) -> tuple[int, int]:
    valid_names = fixture_names(fixtures)
    missing = sorted(REQUIRED_FIXTURES - valid_names)
    extra = sorted(valid_names - REQUIRED_FIXTURES)
    require(not missing, "missing matrix-run fixture(s): " + ", ".join(missing))
    require(not extra, "unlisted matrix-run fixture(s): " + ", ".join(extra))
    for name in sorted(REQUIRED_FIXTURES):
        validate_row(load_json(fixtures / name), str(fixtures / name))
    invalid_dir = fixtures / "invalid"
    invalid_names = fixture_names(invalid_dir)
    missing_invalid = sorted(REQUIRED_INVALID_FIXTURES - invalid_names)
    extra_invalid = sorted(invalid_names - REQUIRED_INVALID_FIXTURES)
    require(not missing_invalid, "missing invalid fixture(s): " + ", ".join(missing_invalid))
    require(not extra_invalid, "unlisted invalid fixture(s): " + ", ".join(extra_invalid))
    for name in sorted(REQUIRED_INVALID_FIXTURES):
        try:
            validate_row(load_json(invalid_dir / name), str(invalid_dir / name))
        except MatrixRunContractError:
            continue
        raise MatrixRunContractError(f"invalid fixture was accepted: {invalid_dir / name}")
    return len(valid_names), len(invalid_names)


def validate(args: Args) -> tuple[int, int]:
    validate_schema_file(args.schemas)
    validate_docs(args.docs)
    return validate_fixture_pack(args.fixtures)


def write_json(path: Path, value: JsonObject) -> None:
    _ = path.write_text(json.dumps(value, sort_keys=True))


def without_field(row: JsonObject, field: str) -> JsonObject:
    copy = dict(row)
    del copy[field]
    return copy


def invalid_self_test_rows(good: JsonObject) -> dict[str, JsonObject | str]:
    host_mutation = dict(good)
    host_mutation["host_mutation"] = True
    release_eligible = dict(good)
    release_eligible["release_eligible"] = True
    invalid_outcome = dict(good)
    invalid_outcome["outcome"] = "SUCCESS"
    stale_git = dict(good)
    stale_git["git"] = {"expected_sha": "302cead", "actual_sha": "deadbee", "status": "stale", "dirty": False}
    dirty_git = dict(good)
    dirty_git["git"] = {"expected_sha": "302cead", "actual_sha": "302cead", "status": "current", "dirty": True}
    missing_marker = dict(good)
    missing_marker["vm_marker"] = {"required": True, "present": False, "path": VM_MARKER, "checked_by": "self-test"}
    absolute_path = dict(good)
    absolute_path["runtime_sample_path"] = "/tmp/runtime-sample.jsonl"
    traversal_path = dict(good)
    traversal_path["incident_path"] = "evidence/../incident.json"
    privacy_failed = dict(good)
    privacy_failed["privacy_scan"] = {"status": "PASS", "private_fields_found": True, "report_path": "evidence/lab/privacy.json"}
    skip_without_cleanup = dict(good)
    skip_without_cleanup["outcome"] = "SKIP"
    skip_without_cleanup["supported_tuple_status"] = "unsupported"
    refuse_without_cleanup = dict(good)
    refuse_without_cleanup["outcome"] = "REFUSE"
    refuse_without_cleanup["evidence_mode"] = "host-refusal-only"
    refuse_without_cleanup["vm_marker"] = {"required": False, "present": False, "path": VM_MARKER, "checked_by": "self-test"}
    extra_property = dict(good)
    extra_property["unexpected_field_not_in_schema"] = "must be rejected"
    return {
        "host-mutation-true.json": host_mutation,
        "release-eligible-true.json": release_eligible,
        "invalid-outcome.json": invalid_outcome,
        "stale-git.json": stale_git,
        "dirty-git.json": dirty_git,
        "missing-vm-marker.json": missing_marker,
        "unsafe-absolute-path.json": absolute_path,
        "unsafe-traversal-path.json": traversal_path,
        "missing-rollback-proof.json": without_field(good, "rollback_proof_path"),
        "missing-cleanup-proof.json": without_field(good, "cleanup_proof_path"),
        "missing-cleanup-proof-on-skip.json": without_field(skip_without_cleanup, "cleanup_proof_path"),
        "missing-cleanup-proof-on-refuse.json": without_field(refuse_without_cleanup, "cleanup_proof_path"),
        "missing-host-refusal-proof.json": without_field(good, "host_refusal_proof_path"),
        "privacy-failed.json": privacy_failed,
        "malformed.json": '{ "schema": "zig-scheduler/matrix-run/v1",',
        "extra-property.json": extra_property,
    }


def write_self_test_pack(fixtures: Path, invalid: Path, good: JsonObject) -> None:
    for name in REQUIRED_FIXTURES:
        write_json(fixtures / name, good)
    for name, row in invalid_self_test_rows(good).items():
        if isinstance(row, str):
            _ = (invalid / name).write_text(row)
        else:
            write_json(invalid / name, row)


def assert_invalid_fixture_gate(args: Args, name: str, good: JsonObject) -> None:
    write_json(args.fixtures / "invalid" / name, good)
    try:
        _ = validate(args)
    except MatrixRunContractError as exc:
        print(f"PASS self-test detects missing rejection coverage for {name}: {exc}")
        return
    raise MatrixRunContractError(f"self-test failed to reject accepted invalid fixture: {name}")


def run_self_test() -> None:
    good = load_json(Path("fixtures/matrix-run/pass.json"))
    for name in sorted(REQUIRED_INVALID_FIXTURES):
        with TemporaryDirectory(prefix="zigsched-matrix-run-") as tmp:
            root = Path(tmp)
            fixtures = root / "fixtures"
            invalid = fixtures / "invalid"
            schemas = root / "schemas"
            docs = root / "docs"
            invalid.mkdir(parents=True)
            schemas.mkdir()
            docs.mkdir()
            _ = (schemas / SCHEMA_FILE).write_text((Path("schemas/control") / SCHEMA_FILE).read_text())
            _ = (docs / DOC_FILE).write_text((Path("docs/control") / DOC_FILE).read_text())
            write_self_test_pack(fixtures, invalid, good)
            args = Args(fixtures, schemas, docs, False)
            _ = validate(args)
            assert_invalid_fixture_gate(args, name, good)


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        print("PASS matrix-run contract self-test")
    else:
        valid_count, invalid_count = validate(args)
        print(f"PASS matrix-run contract: fixtures={args.fixtures} valid={valid_count} invalid={invalid_count} docs={args.docs}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, MatrixRunContractError) as exc:
        print(f"FAIL matrix-run contract: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
