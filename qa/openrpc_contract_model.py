from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final, NoReturn

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.frontend_contract_pack_types import ContractPackError, JsonObject, JsonValue, parse_json_object

MethodSpec = tuple[tuple[str, ...], str, tuple[str, ...]]

METHOD_SPECS: Final[dict[str, MethodSpec]] = {
    "daemon.version": ((), "DaemonVersionResult", ("malformed_rpc", "invalid_rpc_version", "unknown_rpc_method")),
    "targets.list": ((), "TargetsListResult", ("malformed_rpc", "invalid_rpc_version", "unknown_rpc_method")),
    "actions.submit": (("action_json",), "EventsResult", ("malformed_rpc", "invalid_rpc_version", "unknown_rpc_method", "action_json_required")),
    "actions.rollback": (("action_json",), "EventsResult", ("malformed_rpc", "invalid_rpc_version", "unknown_rpc_method", "action_json_required", "rpc_action_mismatch")),
    "actions.stop": (("action_json",), "EventsResult", ("malformed_rpc", "invalid_rpc_version", "unknown_rpc_method", "action_json_required", "rpc_action_mismatch")),
    "events.replay": (("from_event_seq",), "EventsResult", ("malformed_rpc", "invalid_rpc_version", "unknown_rpc_method")),
    "events.follow": (("from_event_seq",), "EventsResult", ("malformed_rpc", "invalid_rpc_version", "unknown_rpc_method")),
}
ERROR_INCIDENTS: Final[tuple[str, ...]] = (
    "malformed_rpc",
    "invalid_rpc_version",
    "unknown_rpc_method",
    "action_json_required",
    "rpc_action_mismatch",
)
ERROR_COMPONENT_BY_INCIDENT: Final[dict[str, str]] = {
    "malformed_rpc": "MalformedRpc",
    "invalid_rpc_version": "InvalidRpcVersion",
    "unknown_rpc_method": "UnknownRpcMethod",
    "action_json_required": "ActionJsonRequired",
    "rpc_action_mismatch": "RpcActionMismatch",
}
ERROR_JSON_RPC_MAPPING: Final[dict[str, tuple[int, str]]] = {
    "MalformedRpc": (-32700, "parse_error"),
    "InvalidRpcVersion": (-32600, "invalid_request"),
    "UnknownRpcMethod": (-32601, "method_not_found"),
    "ActionJsonRequired": (-32602, "invalid_params"),
    "RpcActionMismatch": (-32602, "invalid_params"),
}
SCHEMA_STRINGS: Final[tuple[str, ...]] = (
    "zig-scheduler/daemon-event/v1",
    "zig-scheduler/operator-action/v1",
    "zig-scheduler/runtime-sample/v1",
)
DOC_FILES: Final[tuple[str, ...]] = (
    "frontend-api-pack.md",
    "schema-compatibility.md",
    "incident-taxonomy.md",
)
CODE_ROW_RE: Final = re.compile(r"^\| `([^`]+)` \|", re.MULTILINE)


@dataclass(frozen=True, slots=True)
class Args:
    contract: Path
    daemon: Path
    docs: Path
    self_test: bool


class OpenRpcContractError(Exception):
    """Raised when the daemon OpenRPC contract drifts from docs or implementation."""


class ParsedArgs(argparse.Namespace):
    contract: Path
    daemon: Path
    docs: Path

    def __init__(self) -> None:
        super().__init__()
        self.contract = Path()
        self.daemon = Path()
        self.docs = Path()


def fail(message: str) -> NoReturn:
    raise OpenRpcContractError(message)


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("docs/control/daemon-openrpc.json"), Path("src/daemon_main.zig"), Path("docs/control"), True)
    parser = argparse.ArgumentParser(description="Validate daemon OpenRPC JSON-RPC contract.")
    _ = parser.add_argument("--contract", required=True, type=Path)
    _ = parser.add_argument("--daemon", required=True, type=Path)
    _ = parser.add_argument("--docs", required=True, type=Path)
    parsed = parser.parse_args(argv, namespace=ParsedArgs())
    return Args(contract=parsed.contract, daemon=parsed.daemon, docs=parsed.docs, self_test=False)


def object_field(row: JsonObject, field: str, context: str) -> JsonObject:
    value = row.get(field)
    if not isinstance(value, dict):
        fail(f"{context}.{field} must be an object")
    return value


def list_field(row: JsonObject, field: str, context: str) -> list[JsonValue]:
    value = row.get(field)
    if not isinstance(value, list):
        fail(f"{context}.{field} must be a list")
    return value


def string_field(row: JsonObject, field: str, context: str) -> str:
    value = row.get(field)
    if not isinstance(value, str):
        fail(f"{context}.{field} must be a string")
    return value


def bool_field(row: JsonObject, field: str, context: str) -> bool:
    value = row.get(field)
    if not isinstance(value, bool):
        fail(f"{context}.{field} must be a boolean")
    return value


def int_field(row: JsonObject, field: str, context: str) -> int:
    value = row.get(field)
    if type(value) is not int:
        fail(f"{context}.{field} must be an integer")
    return value


def parse_openrpc_object(text: str, context: str) -> JsonObject:
    try:
        return parse_json_object(text, context)
    except ContractPackError as exc:
        raise OpenRpcContractError(str(exc)) from exc


def json_clone(row: JsonObject) -> JsonObject:
    return parse_openrpc_object(json.dumps(row, sort_keys=True), "self-test clone")


def load_contract(path: Path) -> JsonObject:
    try:
        return parse_openrpc_object(path.read_text(), str(path))
    except FileNotFoundError as exc:
        raise OpenRpcContractError(f"missing OpenRPC contract: {path}") from exc


def schema_ref_name(value: JsonObject, context: str) -> str:
    ref = string_field(value, "$ref", context)
    prefix = "#/components/schemas/"
    if not ref.startswith(prefix):
        fail(f"{context} must reference {prefix}")
    return ref.removeprefix(prefix)


def error_ref_name(value: JsonObject, context: str) -> str:
    ref = string_field(value, "$ref", context)
    prefix = "#/components/errors/"
    if not ref.startswith(prefix):
        fail(f"{context} must reference {prefix}")
    return ref.removeprefix(prefix)


def method_map(contract: JsonObject) -> dict[str, JsonObject]:
    methods: dict[str, JsonObject] = {}
    for index, value in enumerate(list_field(contract, "methods", "contract")):
        if not isinstance(value, dict):
            fail(f"contract.methods[{index}] must be an object")
        name = string_field(value, "name", f"contract.methods[{index}]")
        if name in methods:
            fail(f"duplicate OpenRPC method: {name}")
        methods[name] = value
    return methods


def error_components(contract: JsonObject) -> dict[str, JsonObject]:
    components = object_field(contract, "components", "contract")
    raw_errors = object_field(components, "errors", "contract.components")
    errors: dict[str, JsonObject] = {}
    for name, value in raw_errors.items():
        if not isinstance(value, dict):
            fail(f"components.errors.{name} must be an object")
        errors[name] = value
    return errors


def schema_components(contract: JsonObject) -> dict[str, JsonObject]:
    components = object_field(contract, "components", "contract")
    raw_schemas = object_field(components, "schemas", "contract.components")
    schemas: dict[str, JsonObject] = {}
    for name, value in raw_schemas.items():
        if not isinstance(value, dict):
            fail(f"components.schemas.{name} must be an object")
        schemas[name] = value
    return schemas
