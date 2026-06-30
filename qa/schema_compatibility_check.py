#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/schema_compatibility_check.py --protocol src/control/protocol.zig --schemas schemas/control --docs docs/control --fixtures fixtures/frontend-contract
from __future__ import annotations

import argparse
import json
import shutil
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.control_schema_drift_check import SchemaDriftError, validate_all
from qa.frontend_contract_pack_check import load_codes, load_jsonl
from qa.frontend_contract_pack_types import EVENT_SCHEMA, JsonObject

from qa.schema_compatibility_schema_rules import (
    SchemaCompatibilityError,
    load_schema,
    nested_object,
    validate_public_schemas,
)

DOC_ONLY_CODES: Final = frozenset((
    "duplicate_action_id", "duplicate_target_id", "invalid_action_id", "invalid_field", "journal_limit_exceeded",
    "malformed_rpc", "target_action_id_and_rollback_id_required", "target_id_required", "unknown_rpc_method",
))

@dataclass(frozen=True, slots=True)
class Args:
    protocol: Path
    schemas: Path
    docs: Path
    fixtures: Path
    self_test: bool



class ParsedArgs(argparse.Namespace):
    protocol: Path
    schemas: Path
    docs: Path
    fixtures: Path

    def __init__(self) -> None:
        super().__init__()
        self.protocol = Path()
        self.schemas = Path()
        self.docs = Path()
        self.fixtures = Path()


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("src/control/protocol.zig"), Path("schemas/control"), Path("docs/control"), Path("fixtures/frontend-contract"), True)
    parser = argparse.ArgumentParser(description="Validate public schema draft/version compatibility gates.")
    _ = parser.add_argument("--protocol", required=True, type=Path)
    _ = parser.add_argument("--schemas", required=True, type=Path)
    _ = parser.add_argument("--docs", required=True, type=Path)
    _ = parser.add_argument("--fixtures", required=True, type=Path)
    parsed = parser.parse_args(argv, namespace=ParsedArgs())
    return Args(parsed.protocol, parsed.schemas, parsed.docs, parsed.fixtures, False)


def fixture_reasons(fixtures: Path) -> frozenset[str]:
    reasons: set[str] = set()
    for path in sorted(fixtures.glob("*.jsonl")):
        for row in load_jsonl(path):
            found = row.get("schema")
            if found != EVENT_SCHEMA:
                raise SchemaCompatibilityError(f"{path} uses unsupported daemon-event schema version: {found}")
            reason = row.get("reason")
            if isinstance(reason, str) and reason != "":
                reasons.add(reason)
    return frozenset(reasons)


def validate_docs_and_fixtures(docs: Path, fixtures: Path) -> None:
    taxonomy_codes = frozenset(code for code in load_codes(docs) if "." not in code)
    missing_fixtures = sorted(taxonomy_codes - DOC_ONLY_CODES - fixture_reasons(fixtures))
    if missing_fixtures:
        raise SchemaCompatibilityError("taxonomy code lacks frontend fixture coverage: " + ", ".join(missing_fixtures))
    policy = (docs / "schema-compatibility.md").read_text()
    for needle in ("JSON Schema draft", "backward compatible", "forward compatible", "fully compatible", "breaking change", "v2 migration"):
        if needle.lower() not in policy.lower():
            raise SchemaCompatibilityError(f"schema compatibility doc missing policy text: {needle}")


def validate_all_contracts(args: Args) -> None:
    validate_public_schemas(args.schemas)
    validate_docs_and_fixtures(args.docs, args.fixtures)
    validate_all(args.protocol, args.schemas)


def expect_rejection(label: str, args: Args, mutate: Callable[[Path, Path, Path], None]) -> None:
    safe_label = "".join(ch if ch.isalnum() else "-" for ch in label)
    with TemporaryDirectory(prefix=f"zigsched-schema-compat-{safe_label}-") as tmp:
        root = Path(tmp)
        schemas = root / "schemas"
        docs = root / "docs"
        fixtures = root / "fixtures"
        _ = shutil.copytree(args.schemas, schemas)
        _ = shutil.copytree(args.docs, docs)
        _ = shutil.copytree(args.fixtures, fixtures)
        mutate(schemas, docs, fixtures)
        try:
            validate_all_contracts(Args(args.protocol, schemas, docs, fixtures, False))
        except (SchemaCompatibilityError, SchemaDriftError) as exc:
            print(f"PASS schema compatibility self-test rejected {label}: {exc}")
            return
    raise SchemaCompatibilityError(f"self-test failed to reject {label}")


def update_schema(path: Path, mutate: Callable[[JsonObject], None]) -> None:
    data = load_schema(path)
    mutate(data)
    _ = path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def remove_draft(data: JsonObject) -> None:
    _ = data.pop("$schema", None)


def set_unsupported_draft(data: JsonObject) -> None:
    data["$schema"] = "http://json-schema.org/draft-07/schema#"


def remove_id(data: JsonObject) -> None:
    _ = data.pop("$id", None)


def add_required_seq(data: JsonObject) -> None:
    required = data.get("required")
    if not isinstance(required, list):
        raise SchemaCompatibilityError("self-test required list missing")
    required.append("seq")


def add_conditional_required(data: JsonObject) -> None:
    all_of = data.get("allOf")
    if not isinstance(all_of, list):
        raise SchemaCompatibilityError("self-test allOf list missing")
    all_of.append({
        "if": {"properties": {"action": {"const": "preflight"}}, "required": ["action"]},
        "then": {"required": ["audit_id"]},
    })


def remove_incident_drill(data: JsonObject) -> None:
    action = nested_object(data, ("properties", "action"), "self-test")
    enum = action.get("enum")
    if not isinstance(enum, list):
        raise SchemaCompatibilityError("self-test action enum missing")
    enum.remove("incident_drill")


def mutate_missing_draft(schemas: Path, _docs: Path, _fixtures: Path) -> None:
    update_schema(schemas / "daemon-event.v1.schema.json", remove_draft)


def mutate_missing_non_public_draft(schemas: Path, _docs: Path, _fixtures: Path) -> None:
    update_schema(schemas / "lab-evidence.v1.schema.json", remove_draft)


def mutate_unsupported_draft(schemas: Path, _docs: Path, _fixtures: Path) -> None:
    update_schema(schemas / "operator-action.v1.schema.json", set_unsupported_draft)


def mutate_missing_id(schemas: Path, _docs: Path, _fixtures: Path) -> None:
    update_schema(schemas / "runtime-sample.v1.schema.json", remove_id)


def mutate_new_required(schemas: Path, _docs: Path, _fixtures: Path) -> None:
    update_schema(schemas / "daemon-event.v1.schema.json", add_required_seq)


def mutate_new_conditional_required(schemas: Path, _docs: Path, _fixtures: Path) -> None:
    update_schema(schemas / "operator-action.v1.schema.json", add_conditional_required)


def mutate_doc_only_incident(_schemas: Path, docs: Path, _fixtures: Path) -> None:
    taxonomy = docs / "incident-taxonomy.md"
    _ = taxonomy.write_text(taxonomy.read_text() + "\n| `new_incident_code` | incident | unsafe_to_assume | no_auto_retry | Self-test. |\n")


def mutate_v2_fixture(_schemas: Path, _docs: Path, fixtures: Path) -> None:
    fixture = fixtures / "incident.jsonl"
    _ = fixture.write_text(fixture.read_text().replace(EVENT_SCHEMA, "zig-scheduler/daemon-event/v2", 1))


def mutate_zig_schema_enum_drift(schemas: Path, _docs: Path, _fixtures: Path) -> None:
    update_schema(schemas / "operator-action.v1.schema.json", remove_incident_drill)


def run_self_test(args: Args) -> None:
    validate_all_contracts(args)
    expect_rejection("missing draft", args, mutate_missing_draft)
    expect_rejection("missing draft on non-public-rule control schema", args, mutate_missing_non_public_draft)
    expect_rejection("unsupported draft", args, mutate_unsupported_draft)
    expect_rejection("missing id", args, mutate_missing_id)
    expect_rejection("new required v1 field", args, mutate_new_required)
    expect_rejection("new conditional required v1 field", args, mutate_new_conditional_required)
    expect_rejection("incident code without fixture", args, mutate_doc_only_incident)
    expect_rejection("v2 fixture row", args, mutate_v2_fixture)
    expect_rejection("Zig/schema enum drift", args, mutate_zig_schema_enum_drift)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.self_test:
            run_self_test(args)
        else:
            validate_all_contracts(args)
    except (OSError, json.JSONDecodeError, SchemaCompatibilityError, SchemaDriftError) as exc:
        print(f"FAIL schema compatibility check: {exc}", file=sys.stderr)
        return 1
    print(f"PASS schema compatibility check: protocol={args.protocol} schemas={args.schemas} docs={args.docs} fixtures={args.fixtures}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
