#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Final

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.frontend_contract_pack_semantics import REQUIRED_SCENARIOS, validate_replay, validate_scenario_semantics
from qa.frontend_contract_pack_selftest import run_self_test
from qa.frontend_contract_pack_types import Args, ContractPackError, EVENT_SCHEMA, JsonObject, JsonValue, parse_json_object

PRIVATE_KEY_NEEDLES: Final = ("cmdline", "command_line", "argv", "environment", "env", "secret", "api_key", "private_key", "token", "authorization", "bearer", "password")
PRIVATE_TEXT_NEEDLES: Final = ("cmdline", "command_line", "argv", "environment", '"env"', "secret", "api_key", "private_key", "command_line", "authorization", "bearer", "password")
SENSITIVE_VALUE_PATTERN: Final = r"\b(?:access[\s_.\/-]+)?token\b[\s:=_.\/-]+\S+|\bcredential[\s:=_.\/-]+token\b|\b(?:password|auth|authorization|bearer|api[\s_.\/-]*key|private[\s_.\/-]*key)\b[\s:=_.\/-]+\S+"
SENSITIVE_VALUE_RE: Final = re.compile(SENSITIVE_VALUE_PATTERN, re.IGNORECASE)
PRIVATE_TEXT_SEPARATOR_RE: Final = re.compile(r"[-./]")
IDENTIFIER: Final = re.compile(r"^[A-Za-z0-9_.-]{0,96}$")
COMMAND_ARGV_HASH_PATTERN: Final = (
    r"^(?:(?:sha1[:=_-])?[0-9a-fA-F]{40}"
    r"|(?:sha224[:=_-])?[0-9a-fA-F]{56}"
    r"|(?:sha256[:=_-])?[0-9a-fA-F]{64}"
    r"|(?:sha384[:=_-])?[0-9a-fA-F]{96}"
    r"|(?:sha512[:=_-])?[0-9a-fA-F]{128})$"
)
COMMAND_ARGV_HASH_RE: Final = re.compile(COMMAND_ARGV_HASH_PATTERN)
CODE_RE: Final = re.compile(r"^\| `([^`]+)` \|", re.MULTILINE)


class ParsedArgs(argparse.Namespace):
    fixtures: Path
    schemas: Path
    docs: Path

    def __init__(self) -> None:
        super().__init__()
        self.fixtures = Path()
        self.schemas = Path()
        self.docs = Path()


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("fixtures/frontend-contract"), Path("schemas/control"), Path("docs/control"), True)
    parser = argparse.ArgumentParser(description="Validate backend client contract fixture pack.")
    _ = parser.add_argument("--fixtures", required=True, type=Path)
    _ = parser.add_argument("--schemas", required=True, type=Path)
    _ = parser.add_argument("--docs", required=True, type=Path)
    parsed = parser.parse_args(argv, namespace=ParsedArgs())
    return Args(parsed.fixtures, parsed.schemas, parsed.docs, False)


def fixture_inventory(fixtures: Path) -> tuple[list[str], list[str]]:
    expected = {f"{name}.jsonl" for name in REQUIRED_SCENARIOS}
    actual = {path.name for path in fixtures.glob("*.jsonl") if path.is_file()}
    return sorted(expected - actual), sorted(actual - expected)


def normalized_private_text(value: str) -> str:
    return PRIVATE_TEXT_SEPARATOR_RE.sub("_", value.lower())


def load_jsonl(path: Path) -> list[JsonObject]:
    rows: list[JsonObject] = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        rows.append(parse_json_object(line, f"{path}:{line_number}"))
    if not rows:
        raise ContractPackError(f"empty fixture: {path}")
    return rows


def load_codes(docs: Path) -> set[str]:
    taxonomy = docs / "incident-taxonomy.md"
    try:
        text = taxonomy.read_text()
    except FileNotFoundError as exc:
        raise ContractPackError(f"missing taxonomy doc: {taxonomy}") from exc
    codes = {match.group(1) for match in CODE_RE.finditer(text)}
    if not codes:
        raise ContractPackError("incident taxonomy has no code rows")
    return codes


def require_doc(docs: Path, name: str, needles: tuple[str, ...]) -> None:
    path = docs / name
    try:
        text = path.read_text()
    except FileNotFoundError as exc:
        raise ContractPackError(f"missing doc: {path}") from exc
    lower = text.lower()
    for needle in needles:
        if needle.lower() not in lower:
            raise ContractPackError(f"{path} missing required text: {needle}")


def load_event_schema(schemas: Path) -> JsonObject:
    path = schemas / "daemon-event.v1.schema.json"
    return parse_json_object(path.read_text(), str(path))


def schema_properties(event_schema: JsonObject) -> tuple[set[str], set[str], set[str]]:
    raw_required = event_schema.get("required")
    raw_properties = event_schema.get("properties")
    if not isinstance(raw_required, list) or not isinstance(raw_properties, dict):
        raise ContractPackError("daemon-event schema missing required/properties")
    required = {item for item in raw_required if isinstance(item, str)}
    properties = set(raw_properties.keys())
    event_property = raw_properties.get("event")
    event_enum: set[str] = set()
    if isinstance(event_property, dict):
        raw_enum = event_property.get("enum")
        if isinstance(raw_enum, list):
            event_enum = {item for item in raw_enum if isinstance(item, str)}
    if not event_enum:
        raise ContractPackError("daemon-event schema missing event enum")
    return required, properties, event_enum


def validate_schema_surface(row: JsonObject, required: set[str], properties: set[str], event_enum: set[str], context: str) -> None:
    missing = sorted(field for field in required if field not in row)
    if missing:
        raise ContractPackError(f"{context} missing schema-required field(s): {', '.join(missing)}")
    extra = sorted(field for field in row if field not in properties)
    if extra:
        raise ContractPackError(f"{context} field(s) absent from daemon-event schema: {', '.join(extra)}")
    event = row.get("event")
    if not isinstance(event, str) or event not in event_enum:
        raise ContractPackError(f"{context} event absent from daemon-event schema enum: {event}")


def reject_non_hash_command_argv_hash(value: JsonValue, context: str) -> None:
    if not isinstance(value, str) or COMMAND_ARGV_HASH_RE.fullmatch(value) is None:
        raise ContractPackError(f"{context} must be a hash-shaped redacted value")


def reject_private(value: JsonValue, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lower_key = key.lower()
            if key != "command_argv_hash" and any(needle in lower_key for needle in PRIVATE_KEY_NEEDLES):
                raise ContractPackError(f"privacy-unsafe key in {context}.{key}")
            child_context = f"{context}.{key}"
            reject_private(child, child_context)
            if key == "command_argv_hash":
                reject_non_hash_command_argv_hash(child, child_context)
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            reject_private(child, f"{context}[{index}]")
        return
    if isinstance(value, str):
        lower_value = normalized_private_text(value)
        if SENSITIVE_VALUE_RE.search(value) is not None or any(needle in lower_value for needle in PRIVATE_TEXT_NEEDLES):
            raise ContractPackError(f"privacy-unsafe text in {context}")


def reject_unsafe_path_text(raw: str, context: str) -> None:
    path = Path(raw)
    if path.is_absolute() or ".." in path.parts:
        raise ContractPackError(f"{context} escapes repo: {raw}")


def reject_artifact_path_collection(value: JsonValue, context: str) -> None:
    if isinstance(value, str):
        reject_unsafe_path_text(value, context)
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            reject_artifact_path_collection(child, f"{context}[{index}]")
        return
    if isinstance(value, dict):
        for key, child in value.items():
            reject_artifact_path_collection(child, f"{context}.{key}")
        return
    if value is not None:
        raise ContractPackError(f"{context} must contain path text")


def reject_unsafe_artifact_paths(value: JsonValue, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_context = f"{context}.{key}"
            if key == "artifact_paths":
                reject_artifact_path_collection(child, child_context)
            else:
                reject_unsafe_artifact_paths(child, child_context)
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            reject_unsafe_artifact_paths(child, f"{context}[{index}]")


def require_safe_path(row: JsonObject, field: str, context: str) -> None:
    raw = row.get(field)
    if raw in (None, ""):
        return
    if not isinstance(raw, str):
        raise ContractPackError(f"{context}.{field} must be a string")
    reject_unsafe_path_text(raw, f"{context}.{field}")


def validate_identifier(row: JsonObject, field: str, context: str) -> None:
    raw = row.get(field)
    if raw in (None, ""):
        return
    if not isinstance(raw, str) or IDENTIFIER.fullmatch(raw) is None:
        raise ContractPackError(f"{context}.{field} is not a stable identifier")


def validate_rows(path: Path, rows: list[JsonObject], codes: set[str], required: set[str], properties: set[str], event_enum: set[str]) -> None:
    expected_seq = 1
    if path.name == "replay-event-cursor.jsonl":
        first_seq = rows[0].get("seq")
        if not isinstance(first_seq, int):
            raise ContractPackError("replay-event-cursor first seq must be an integer")
        expected_seq = first_seq
        if expected_seq < 2:
            raise ContractPackError("replay-event-cursor must prove a non-zero event cursor")
    for row in rows:
        context = f"{path}:{row.get('seq', '?')}"
        reject_private(row, context)
        reject_unsafe_artifact_paths(row, context)
        validate_schema_surface(row, required, properties, event_enum, context)
        if row.get("schema") != EVENT_SCHEMA:
            raise ContractPackError(f"{context} bad schema")
        if row.get("seq") != expected_seq:
            raise ContractPackError(f"{context} nonmonotonic seq: expected {expected_seq}")
        expected_seq += 1
        if row.get("host_mutation") is not False:
            raise ContractPackError(f"{context} host_mutation must be false")
        if not isinstance(row.get("event"), str) or not isinstance(row.get("status"), str):
            raise ContractPackError(f"{context} missing event/status")
        for field in ("action_id", "target_id", "target_action_id", "rollback_id"):
            validate_identifier(row, field, context)
        for field in ("artifact", "live_bundle_path"):
            require_safe_path(row, field, context)
        reason = row.get("reason")
        if reason is not None and reason != "":
            needs_taxonomy = row.get("event") in {"incident", "refusal"} or row.get("status") in {"INCIDENT", "REFUSE", "refused", "unsafe_to_assume", "FAIL"}
            if needs_taxonomy and (not isinstance(reason, str) or reason not in codes):
                raise ContractPackError(f"{context} undocumented incident/refusal reason: {reason}")


def validate(args: Args) -> None:
    for schema_name in ("daemon-event.v1.schema.json", "operator-action.v1.schema.json", "runtime-sample.v1.schema.json"):
        if not (args.schemas / schema_name).is_file():
            raise ContractPackError(f"missing schema: {schema_name}")
    required, properties, event_enum = schema_properties(load_event_schema(args.schemas))
    require_doc(args.docs, "frontend-api-pack.md", ("backend contract", "no frontend implementation", "Unix-domain socket", "JSON-RPC", "Replay semantics"))
    require_doc(args.docs, "schema-compatibility.md", ("daemon-event/v1", "operator-action/v1", "runtime-sample/v1", "breaking change"))
    codes = load_codes(args.docs)
    missing, extra = fixture_inventory(args.fixtures)
    if missing:
        raise ContractPackError("missing fixture(s): " + ", ".join(missing))
    if extra:
        raise ContractPackError("unlisted fixture(s): " + ", ".join(extra))
    rows_by_name: dict[str, list[JsonObject]] = {}
    for name in REQUIRED_SCENARIOS:
        rows = load_jsonl(args.fixtures / f"{name}.jsonl")
        validate_rows(args.fixtures / f"{name}.jsonl", rows, codes, required, properties, event_enum)
        validate_scenario_semantics(name, rows)
        rows_by_name[name] = rows
    validate_replay(rows_by_name)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.self_test:
            run_self_test(args, validate)
        else:
            validate(args)
    except (OSError, ContractPackError) as exc:
        print(f"FAIL frontend contract pack: {exc}", file=sys.stderr)
        return 1
    print(f"PASS frontend contract pack: fixtures={args.fixtures} docs={args.docs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
