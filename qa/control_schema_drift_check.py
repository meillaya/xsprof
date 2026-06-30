#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/control_schema_drift_check.py --protocol src/control/protocol.zig --schemas schemas/control
"""Fail when JSON control schemas drift from Zig protocol contracts."""

from __future__ import annotations

import json
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final

JsonValue = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject = dict[str, JsonValue]

VM_MARKER: Final = "/run/zig-scheduler-vm-lab.marker"
OPERATOR_FILE: Final = "operator-action.v1.schema.json"
DAEMON_FILE: Final = "daemon-event.v1.schema.json"
RUNTIME_FILE: Final = "runtime-sample.v1.schema.json"
LAB_FILE: Final = "lab-evidence.v1.schema.json"
ROLLBACK_FILE: Final = "rollback-result.v1.schema.json"
ACTION_FIELDS: Final = ("schema", "action", "action_id", "run_id", "target_id", "target_cgroup", "audit_id", "rollback_id", "target_action_id")
FORBIDDEN_ACTION_FIELDS: Final = ("command", "shell", "argv", "host_mutation")
RUNTIME_REQUIRED: Final = (
    "schema",
    "sequence",
    "state",
    "ops",
    "enable_seq",
    "events",
    "events_hash",
    "nr_rejected",
    "debug_dump",
    "cgroup_membership_digest",
    "workload_alive",
    "private_command_lines_sampled",
)
RUNTIME_FORBIDDEN: Final = ("command_line", "cmdline", "argv", "env", "environment", "secret", "api_key")
MUTATION_FAMILIES: Final = ("cgroup.weight", "cpu.max", "uclamp", "topology.offline_cpu")


@dataclass(frozen=True, slots=True)
class Args:
    protocol: Path
    schemas: Path
    self_test: bool


@dataclass(frozen=True, slots=True)
class ProtocolFacts:
    operator_schema: str
    daemon_schema: str
    actions: tuple[str, ...]
    events: tuple[str, ...]
    runtime_schema: str


class SchemaDriftError(Exception):
    """Raised when schema files no longer match the Zig protocol surface."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("src/control/protocol.zig"), Path("schemas/control"), True)
    if len(argv) == 4 and argv[0] == "--protocol" and argv[2] == "--schemas":
        return Args(Path(argv[1]), Path(argv[3]), False)
    raise SchemaDriftError("usage: control_schema_drift_check.py --protocol <protocol.zig> --schemas <dir> | --self-test")


def extract_const(source: str, name: str) -> str:
    found = re.search(rf'pub const {re.escape(name)} = "([^"]+)";', source)
    if found is None:
        raise SchemaDriftError(f"missing Zig const: {name}")
    return found.group(1)


def extract_enum(source: str, name: str) -> tuple[str, ...]:
    found = re.search(rf"pub const {re.escape(name)} = enum \{{(?P<body>.*?)\}};", source, re.S)
    if found is None:
        raise SchemaDriftError(f"missing Zig enum: {name}")
    fields = tuple(line.strip().rstrip(",") for line in found.group("body").splitlines() if line.strip())
    if not fields:
        raise SchemaDriftError(f"empty Zig enum: {name}")
    return fields


def protocol_facts(protocol: Path) -> ProtocolFacts:
    source = protocol.read_text()
    stream_source = Path("src/control/stream.zig").read_text()
    runtime = re.search(r'const sample_schema = "([^"]+)";', stream_source)
    if runtime is None:
        raise SchemaDriftError("missing runtime sample schema const")
    return ProtocolFacts(extract_const(source, "schema"), extract_const(source, "event_schema"), extract_enum(source, "ActionKind"), extract_enum(source, "EventKind"), runtime.group(1))


def load_schema(schemas: Path, filename: str) -> JsonObject:
    path = schemas / filename
    try:
        raw = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise SchemaDriftError(f"missing schema file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SchemaDriftError(f"invalid JSON schema {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise SchemaDriftError(f"schema is not an object: {path}")
    return raw


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise SchemaDriftError(f"{context} must be an object")
    return value


def string_set(value: JsonValue | None, context: str) -> set[str]:
    if not isinstance(value, list):
        raise SchemaDriftError(f"{context} must be a string list")
    output: set[str] = set()
    for item in value:
        if not isinstance(item, str):
            raise SchemaDriftError(f"{context} contains a non-string value")
        output.add(item)
    return output


def properties(schema: JsonObject, names: tuple[str, ...], context: str) -> JsonObject:
    props = obj(schema.get("properties"), f"{context}.properties")
    missing = sorted(set(names) - set(props))
    if missing:
        raise SchemaDriftError(f"{context} properties missing: {', '.join(missing)}")
    return props


def require_required(schema: JsonObject, names: tuple[str, ...], context: str) -> None:
    missing = sorted(set(names) - string_set(schema.get("required"), f"{context}.required"))
    if missing:
        raise SchemaDriftError(f"{context} required missing: {', '.join(missing)}")


def require_forbidden(schema: JsonObject, names: tuple[str, ...], context: str) -> None:
    missing = sorted(set(names) - string_set(schema.get("forbiddenProperties"), f"{context}.forbiddenProperties"))
    if missing:
        raise SchemaDriftError(f"{context} forbidden missing: {', '.join(missing)}")


def require_action_conditional(schema: JsonObject, action: str, required: tuple[str, ...], context: str) -> None:
    clauses = schema.get("allOf")
    if not isinstance(clauses, list):
        raise SchemaDriftError(f"{context}.allOf missing action-specific required clauses")
    for clause in clauses:
        if not isinstance(clause, dict):
            continue
        raw_if = clause.get("if")
        raw_then = clause.get("then")
        if not isinstance(raw_if, dict) or not isinstance(raw_then, dict):
            continue
        raw_props = raw_if.get("properties")
        if not isinstance(raw_props, dict):
            continue
        raw_action = raw_props.get("action")
        if isinstance(raw_action, dict) and raw_action.get("const") == action:
            missing = sorted(set(required) - string_set(raw_then.get("required"), f"{context}.allOf[{action}].then.required"))
            if missing:
                raise SchemaDriftError(f"{context} {action} required missing: {', '.join(missing)}")
            return
    raise SchemaDriftError(f"{context} missing conditional required clause for {action}")


def require_const(props: JsonObject, name: str, expected: JsonValue, context: str) -> None:
    if obj(props.get(name), f"{context}.{name}").get("const") != expected:
        raise SchemaDriftError(f"{context}.{name} const drifted")


def require_enum(props: JsonObject, name: str, expected: tuple[str, ...], context: str) -> None:
    actual = string_set(obj(props.get(name), f"{context}.{name}").get("enum"), f"{context}.{name}.enum")
    if actual != set(expected):
        raise SchemaDriftError(f"{context}.{name} enum drifted")


def validate_all(protocol: Path, schemas: Path) -> None:
    facts = protocol_facts(protocol)
    op = load_schema(schemas, OPERATOR_FILE)
    op_props = properties(op, ACTION_FIELDS, OPERATOR_FILE)
    require_required(op, ("action",), OPERATOR_FILE)
    require_const(op_props, "schema", facts.operator_schema, OPERATOR_FILE)
    require_enum(op_props, "action", facts.actions, OPERATOR_FILE)
    require_forbidden(op, FORBIDDEN_ACTION_FIELDS, OPERATOR_FILE)
    require_action_conditional(op, "run_lab_microvm_live", ("action_id", "target_id", "audit_id", "rollback_id"), OPERATOR_FILE)
    require_action_conditional(op, "partial_attach", ("audit_id", "rollback_id"), OPERATOR_FILE)

    daemon = load_schema(schemas, DAEMON_FILE)
    daemon_props = properties(daemon, ("schema", "event", "status", "host_mutation"), DAEMON_FILE)
    require_required(daemon, ("schema", "event", "status", "host_mutation"), DAEMON_FILE)
    require_const(daemon_props, "schema", facts.daemon_schema, DAEMON_FILE)
    require_enum(daemon_props, "event", facts.events, DAEMON_FILE)
    require_const(daemon_props, "host_mutation", False, DAEMON_FILE)

    runtime = load_schema(schemas, RUNTIME_FILE)
    runtime_props = properties(runtime, RUNTIME_REQUIRED, RUNTIME_FILE)
    require_required(runtime, RUNTIME_REQUIRED, RUNTIME_FILE)
    require_const(runtime_props, "schema", facts.runtime_schema, RUNTIME_FILE)
    require_const(runtime_props, "private_command_lines_sampled", False, RUNTIME_FILE)
    require_forbidden(runtime, RUNTIME_FORBIDDEN, RUNTIME_FILE)

    lab = load_schema(schemas, LAB_FILE)
    lab_props = properties(lab, ("schema", "vm_marker_path", "host_mutation", "release_eligible", "mutation_evidence"), LAB_FILE)
    require_required(lab, ("schema", "vm_marker_present", "target_allowlisted", "audit_id", "rollback_id", "host_mutation", "mutation_evidence"), LAB_FILE)
    require_const(lab_props, "schema", "zig-scheduler/lab-evidence/v1", LAB_FILE)
    require_const(lab_props, "vm_marker_path", VM_MARKER, LAB_FILE)
    require_const(lab_props, "host_mutation", False, LAB_FILE)
    require_const(lab_props, "release_eligible", False, LAB_FILE)
    require_required(obj(lab_props.get("mutation_evidence"), f"{LAB_FILE}.mutation_evidence"), MUTATION_FAMILIES, f"{LAB_FILE}.mutation_evidence")

    rollback = load_schema(schemas, ROLLBACK_FILE)
    rollback_props = properties(rollback, ("schema", "rollback_id", "result", "idempotent", "host_mutation"), ROLLBACK_FILE)
    require_required(rollback, ("schema", "rollback_id", "result", "idempotent", "host_mutation"), ROLLBACK_FILE)
    require_const(rollback_props, "result", "PASS", ROLLBACK_FILE)
    require_const(rollback_props, "idempotent", True, ROLLBACK_FILE)
    require_const(rollback_props, "host_mutation", False, ROLLBACK_FILE)


def run_self_test(args: Args) -> None:
    with TemporaryDirectory(prefix="zigsched-schema-drift-") as tmp:
        tmp_schemas = Path(tmp) / "schemas"
        shutil.copytree(args.schemas, tmp_schemas)
        validate_all(args.protocol, tmp_schemas)
        action_path = tmp_schemas / OPERATOR_FILE
        action = json.loads(action_path.read_text())
        action["properties"]["action"]["enum"].remove("incident_drill")
        action_path.write_text(json.dumps(action, indent=2, sort_keys=True))
        try:
            validate_all(args.protocol, tmp_schemas)
        except SchemaDriftError as exc:
            print(f"PASS self-test rejected drift: {exc}")
            return
    raise SchemaDriftError("self-test failed to reject a removed action enum")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test(args)
    else:
        validate_all(args.protocol, args.schemas)
        print(f"PASS control schema drift check: protocol={args.protocol} schemas={args.schemas}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, SchemaDriftError) as exc:
        print(f"FAIL control schema drift check: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
