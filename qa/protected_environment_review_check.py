#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/protected_environment_review_check.py --self-test
# python3 qa/protected_environment_review_check.py --proof fixtures/protected-environment-review/valid/github-review-run-28539973410.json --schema schemas/control/protected-environment-review.v1.schema.json
# python3 qa/protected_environment_review_check.py --fixtures fixtures/protected-environment-review --schema schemas/control/protected-environment-review.v1.schema.json
"""Validate normalized protected-environment review proof artifacts."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys
from typing import Final, Literal, NoReturn, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
Mode: TypeAlias = Literal["proof", "fixtures", "invalid-fixtures", "self-test"]

SCHEMA_ID: Final = "zig-scheduler/protected-environment-review/v1"
DEFAULT_SCHEMA: Final = Path("schemas/control/protected-environment-review.v1.schema.json")
DEFAULT_FIXTURES: Final = Path("fixtures/protected-environment-review")
REQUIRED_COMMENT: Final = "manual protected VM proof only; not release approval"
ENVIRONMENT_NAME: Final = "vm-proof-manual"
RUN_ID_RE: Final = re.compile(r"^[0-9]+$")
RUN_URL_RE: Final = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/actions/runs/([0-9]+)$")
API_URL_RE: Final = re.compile(r"^https://api\.github\.com/repos/([^/]+)/([^/]+)/actions/runs/([0-9]+)/approvals$")
HEAD_SHA_RE: Final = re.compile(r"^[0-9a-f]{40}$")
RFC3339_UTC_RE: Final = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
PRIVACY_KEY_RE: Final = re.compile(r"(?:authorization|bearer|token|secret|password|api[_-]?key|cookie|session|private[_-]?key|cmdline|argv)", re.IGNORECASE)
PRIVATE_VALUE_RE: Final = re.compile(r"(?:Authorization:|Bearer\s+[A-Za-z0-9._~+/=-]+|ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)", re.IGNORECASE)
ROOT_FIELDS: Final = frozenset((
    "schema",
    "run_id",
    "run_url",
    "head_sha",
    "environment_name",
    "environment_id",
    "reviewer_status",
    "reviewer_identity",
    "reviewer_id",
    "comment",
    "review_history_api_url",
    "collected_at",
    "host_mutation",
    "release_eligible",
    "production_capacity_claim",
))
SCHEMA_FIELDS: Final = frozenset(("$id", "$schema", "type", "additionalProperties", "required", "properties"))


@dataclass(frozen=True, slots=True)
class Args:
    mode: Mode
    proof: Path | None
    fixtures: Path
    schema: Path


class ProtectedReviewError(Exception):
    """Raised when protected-environment review proof is malformed or unsafe."""


def reject_constant(value: str) -> NoReturn:
    raise ProtectedReviewError(f"invalid JSON constant: {value}")


def load_json_object(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text(), parse_constant=reject_constant)
    except FileNotFoundError as exc:
        raise ProtectedReviewError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ProtectedReviewError(f"invalid JSON in {path} at byte {exc.pos}: {exc.msg}") from exc
    if not isinstance(raw, dict):
        raise ProtectedReviewError(f"{path} must contain a JSON object")
    return raw


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args("self-test", None, DEFAULT_FIXTURES, DEFAULT_SCHEMA)
    parser = argparse.ArgumentParser(description="Validate protected-environment review proof artifacts.")
    _ = parser.add_argument("--proof", type=Path)
    _ = parser.add_argument("--fixtures", type=Path)
    _ = parser.add_argument("--invalid-fixtures", type=Path)
    _ = parser.add_argument("--schema", default=DEFAULT_SCHEMA, type=Path)
    parsed = parser.parse_args(argv)
    selected = sum(value is not None for value in (parsed.proof, parsed.fixtures, parsed.invalid_fixtures))
    if selected != 1:
        raise ProtectedReviewError("exactly one of --proof, --fixtures, --invalid-fixtures, or --self-test is required")
    if parsed.proof is not None:
        return Args("proof", parsed.proof, DEFAULT_FIXTURES, parsed.schema)
    if parsed.invalid_fixtures is not None:
        return Args("invalid-fixtures", None, parsed.invalid_fixtures, parsed.schema)
    return Args("fixtures", None, parsed.fixtures, parsed.schema)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProtectedReviewError(message)


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise ProtectedReviewError(f"{context} must be non-empty text")
    return value


def int_field(value: JsonValue | None, context: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ProtectedReviewError(f"{context} must be a positive integer")
    return value


def scan_privacy(value: JsonValue, context: str) -> None:
    match value:
        case None | bool() | int() | float():
            return
        case str() as raw:
            require(PRIVATE_VALUE_RE.search(raw) is None, f"{context} contains privacy-unsafe value")
        case list() as rows:
            for index, item in enumerate(rows):
                scan_privacy(item, f"{context}[{index}]")
        case dict() as row:
            for key, item in row.items():
                require(PRIVACY_KEY_RE.search(key) is None, f"{context}.{key} is a privacy-unsafe key")
                scan_privacy(item, f"{context}.{key}")


def only_fields(row: JsonObject, allowed: frozenset[str], context: str) -> None:
    extra = sorted(set(row) - allowed)
    require(not extra, f"{context} has unexpected fields: {', '.join(extra)}")


def validate_schema_file(path: Path) -> None:
    schema = load_json_object(path)
    only_fields(schema, SCHEMA_FIELDS, "schema")
    require(schema.get("$id") == SCHEMA_ID, "protected review schema $id mismatch")
    required = schema.get("required")
    require(isinstance(required, list), "schema.required must be a list")
    require(set(text(item, "schema.required[]") for item in required) == ROOT_FIELDS, "schema.required must match protected review root fields")
    require(schema.get("additionalProperties") is False, "schema must reject additional properties")


def validate_proof(path: Path, schema_path: Path) -> None:
    validate_schema_file(schema_path)
    data = load_json_object(path)
    scan_privacy(data, str(path))
    only_fields(data, ROOT_FIELDS, str(path))
    require(data.get("schema") == SCHEMA_ID, "unsupported protected review schema")
    run_id = text(data.get("run_id"), "run_id")
    require(RUN_ID_RE.fullmatch(run_id) is not None, "run_id must be decimal GitHub Actions run id text")
    run_url = text(data.get("run_url"), "run_url")
    run_match = RUN_URL_RE.fullmatch(run_url)
    require(run_match is not None, "run_url must be a GitHub Actions run URL")
    assert run_match is not None
    require(run_match.group(3) == run_id, "run_url run id must match run_id")
    require(HEAD_SHA_RE.fullmatch(text(data.get("head_sha"), "head_sha")) is not None, "head_sha must be 40 lowercase hex characters")
    require(data.get("environment_name") == ENVIRONMENT_NAME, "environment_name must be vm-proof-manual")
    _ = int_field(data.get("environment_id"), "environment_id")
    require(data.get("reviewer_status") == "approved", "reviewer_status must be approved")
    _ = text(data.get("reviewer_identity"), "reviewer_identity")
    _ = int_field(data.get("reviewer_id"), "reviewer_id")
    require(data.get("comment") == REQUIRED_COMMENT, "comment must exactly match protected VM proof acknowledgement")
    api_url = text(data.get("review_history_api_url"), "review_history_api_url")
    api_match = API_URL_RE.fullmatch(api_url)
    require(api_match is not None, "review_history_api_url must be GitHub approvals API URL")
    assert api_match is not None
    require(api_match.group(1) == run_match.group(1) and api_match.group(2) == run_match.group(2), "review_history_api_url repository must match run_url")
    require(api_match.group(3) == run_id, "review_history_api_url run id must match run_id")
    require(RFC3339_UTC_RE.fullmatch(text(data.get("collected_at"), "collected_at")) is not None, "collected_at must be UTC RFC3339 seconds")
    require(data.get("host_mutation") is False, "host_mutation must be false")
    require(data.get("release_eligible") is False, "release_eligible must be false")
    require(data.get("production_capacity_claim") is False, "production_capacity_claim must be false")


def validate_invalid_fixtures(root: Path, schema: Path) -> None:
    invalid_paths = sorted(root.glob("*.json"))
    require(bool(invalid_paths), f"missing invalid protected review fixtures under {root}")
    for invalid in invalid_paths:
        try:
            validate_proof(invalid, schema)
        except ProtectedReviewError as exc:
            print(f"PASS reject invalid protected review fixture {invalid.name}: {exc}")
            continue
        raise ProtectedReviewError(f"expected invalid protected review fixture rejection: {invalid}")


def validate_fixtures(root: Path, schema: Path) -> None:
    valid_paths = sorted((root / "valid").glob("*.json"))
    require(bool(valid_paths), f"missing valid protected review fixtures under {root / 'valid'}")
    for valid in valid_paths:
        validate_proof(valid, schema)
        print(f"PASS protected review fixture: {valid}")
    validate_invalid_fixtures(root / "invalid", schema)


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        match args.mode:
            case "self-test":
                validate_fixtures(args.fixtures, args.schema)
                print("PASS protected review self-test")
            case "proof":
                if args.proof is None:
                    raise ProtectedReviewError("--proof path missing")
                validate_proof(args.proof, args.schema)
                print(f"PASS protected review proof: {args.proof}")
            case "fixtures":
                validate_fixtures(args.fixtures, args.schema)
            case "invalid-fixtures":
                validate_invalid_fixtures(args.fixtures, args.schema)
        return 0
    except ProtectedReviewError as exc:
        print(f"FAIL protected review proof: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
