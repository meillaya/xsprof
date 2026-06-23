#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final, NoReturn, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

EVENT_SCHEMA: Final = "zig-scheduler/daemon-event/v1"
REQUIRED_SCENARIOS: Final = (
    "queued", "booting", "verifier", "attached", "observing", "rollback-ready", "rollback-active", "cleaned",
    "incident", "lost-stream", "timeout", "verifier-reject", "rollback-failure", "cleanup-residue",
    "stale-target", "duplicate-target", "stale-rollback", "malformed-action", "stream-backpressure", "stale-git",
    "privacy-rejection", "replay-event-cursor", "replay-runtime-sample-cursor",
)
PRIVATE_KEY_NEEDLES: Final = ("cmdline", "command_line", "argv", "environment", "env", "secret", "api_key")
PRIVATE_TEXT_NEEDLES: Final = ("cmdline", "command_line", "argv", "environment", '"env"', "secret", "api_key", "--token", "password=")
IDENTIFIER: Final = re.compile(r"^[A-Za-z0-9_.-]{0,96}$")
CODE_RE: Final = re.compile(r"^\| `([^`]+)` \|", re.MULTILINE)


@dataclass(frozen=True, slots=True)
class Args:
    fixtures: Path
    schemas: Path
    docs: Path
    self_test: bool


class ContractPackError(Exception):
    pass


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("fixtures/frontend-contract"), Path("schemas/control"), Path("docs/control"), True)
    parser = argparse.ArgumentParser(description="Validate backend client contract fixture pack.")
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--schemas", required=True, type=Path)
    parser.add_argument("--docs", required=True, type=Path)
    parsed = parser.parse_args(argv)
    return Args(parsed.fixtures, parsed.schemas, parsed.docs, False)


def load_jsonl(path: Path) -> list[JsonObject]:
    rows: list[JsonObject] = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        raw = json.loads(line)
        if not isinstance(raw, dict):
            raise ContractPackError(f"{path}:{line_number} is not an object")
        rows.append(raw)
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
    raw = json.loads(path.read_text())
    if not isinstance(raw, dict):
        raise ContractPackError(f"{path} is not an object")
    return raw


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


def reject_private(value: JsonValue, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "command_argv_hash":
                continue
            lower_key = key.lower()
            if any(needle in lower_key for needle in PRIVATE_KEY_NEEDLES):
                raise ContractPackError(f"privacy-unsafe key in {context}.{key}")
            reject_private(child, f"{context}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_private(child, f"{context}[{index}]")
    elif isinstance(value, str):
        lower_value = value.lower()
        if any(needle in lower_value for needle in PRIVATE_TEXT_NEEDLES):
            raise ContractPackError(f"privacy-unsafe text in {context}")


def require_safe_path(row: JsonObject, field: str, context: str) -> None:
    raw = row.get(field)
    if raw in (None, ""):
        return
    if not isinstance(raw, str):
        raise ContractPackError(f"{context}.{field} must be a string")
    path = Path(raw)
    if path.is_absolute() or ".." in path.parts:
        raise ContractPackError(f"{context}.{field} escapes repo: {raw}")


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


def validate_replay(rows_by_name: dict[str, list[JsonObject]]) -> None:
    event_rows = rows_by_name["replay-event-cursor"]
    if event_rows[0].get("seq") != 2 or any(row.get("replay_cursor") != "event_seq" for row in event_rows):
        raise ContractPackError("event replay fixture does not prove event-seq cursor semantics")
    runtime_rows = rows_by_name["replay-runtime-sample-cursor"]
    sample_rows = [row for row in runtime_rows if row.get("event") == "runtime_sample"]
    if len(sample_rows) != 1 or sample_rows[0].get("sample_sequence") != 2 or sample_rows[0].get("replay_cursor") != "runtime_sample_sequence":
        raise ContractPackError("runtime replay fixture does not prove sample-seq cursor semantics")


def validate(args: Args) -> None:
    for schema_name in ("daemon-event.v1.schema.json", "operator-action.v1.schema.json", "runtime-sample.v1.schema.json"):
        if not (args.schemas / schema_name).is_file():
            raise ContractPackError(f"missing schema: {schema_name}")
    required, properties, event_enum = schema_properties(load_event_schema(args.schemas))
    require_doc(args.docs, "frontend-api-pack.md", ("backend contract", "no frontend implementation", "Unix-domain socket", "JSON-RPC", "Replay semantics"))
    require_doc(args.docs, "schema-compatibility.md", ("daemon-event/v1", "operator-action/v1", "runtime-sample/v1", "breaking change"))
    codes = load_codes(args.docs)
    missing = [name for name in REQUIRED_SCENARIOS if not (args.fixtures / f"{name}.jsonl").is_file()]
    if missing:
        raise ContractPackError("missing fixture(s): " + ", ".join(missing))
    rows_by_name: dict[str, list[JsonObject]] = {}
    for name in REQUIRED_SCENARIOS:
        rows = load_jsonl(args.fixtures / f"{name}.jsonl")
        validate_rows(args.fixtures / f"{name}.jsonl", rows, codes, required, properties, event_enum)
        rows_by_name[name] = rows
    validate_replay(rows_by_name)


def run_self_test(args: Args) -> None:
    validate(args)
    with TemporaryDirectory(prefix="zigsched-contract-pack-") as tmp:
        tmp_path = Path(tmp)
        bad_fixtures = tmp_path / "fixtures"
        bad_docs = tmp_path / "docs"
        bad_fixtures.mkdir()
        bad_docs.mkdir()
        for fixture in args.fixtures.glob("*.jsonl"):
            (bad_fixtures / fixture.name).write_text(fixture.read_text())
        for doc in args.docs.glob("*.md"):
            (bad_docs / doc.name).write_text(doc.read_text())
        bad = json.loads((bad_fixtures / "incident.jsonl").read_text().splitlines()[0])
        bad["reason"] = "undocumented_reason"
        bad_fixtures.joinpath("incident.jsonl").write_text(json.dumps(bad) + "\n")
        try:
            validate(Args(bad_fixtures, args.schemas, bad_docs, False))
        except ContractPackError as exc:
            print(f"PASS self-test rejected undocumented reason: {exc}")
        else:
            raise ContractPackError("self-test failed to reject undocumented reason")
        good = json.loads((bad_fixtures / "incident.jsonl").read_text().splitlines()[0])
        good["reason"] = "lost_stream"
        good["diagnostic"] = "PASSWORD=secret"
        bad_fixtures.joinpath("incident.jsonl").write_text(json.dumps(good) + "\n")
        try:
            validate(Args(bad_fixtures, args.schemas, bad_docs, False))
        except ContractPackError as exc:
            print(f"PASS self-test rejected uppercase private text: {exc}")
        else:
            raise ContractPackError("self-test failed to reject uppercase private text")
        good.pop("diagnostic", None)
        good["env"] = "PATH=/usr/bin"
        bad_fixtures.joinpath("incident.jsonl").write_text(json.dumps(good) + "\n")
        try:
            validate(Args(bad_fixtures, args.schemas, bad_docs, False))
        except ContractPackError as exc:
            print(f"PASS self-test rejected env key: {exc}")
        else:
            raise ContractPackError("self-test failed to reject env key")
        good.pop("env", None)
        good["unexpected_contract_field"] = "bad"
        bad_fixtures.joinpath("incident.jsonl").write_text(json.dumps(good) + "\n")
        try:
            validate(Args(bad_fixtures, args.schemas, bad_docs, False))
        except ContractPackError as exc:
            print(f"PASS self-test rejected schema extra field: {exc}")
            return
    raise ContractPackError("self-test failed to reject schema extra field")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.self_test:
            run_self_test(args)
        else:
            validate(args)
    except (OSError, json.JSONDecodeError, ContractPackError) as exc:
        print(f"FAIL frontend contract pack: {exc}", file=sys.stderr)
        return 1
    print(f"PASS frontend contract pack: fixtures={args.fixtures} docs={args.docs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
