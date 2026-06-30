from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from qa.openrpc_contract_model import (
    CODE_ROW_RE,
    ERROR_COMPONENT_BY_INCIDENT,
    ERROR_INCIDENTS,
    ERROR_JSON_RPC_MAPPING,
    METHOD_SPECS,
    SCHEMA_STRINGS,
    fail,
)


@dataclass(frozen=True, slots=True)
class DaemonErrorMapping:
    incident: str
    code: int
    message: str


WRITE_RPC_ERROR_RE: Final = re.compile(
    r'writeRpcError\s*\(\s*allocator\s*,\s*response\s*,\s*(?:null|request\.id)\s*,\s*(-?\d+)\s*,\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*,\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*\)',
    re.MULTILINE,
)
SOCKET_METHODS: Final = (
    "daemon.version",
    "actions.submit",
    "actions.rollback",
    "actions.stop",
    "events.replay",
    "events.follow",
    "targets.list",
)


def load_taxonomy_codes(docs: Path) -> set[str]:
    text = (docs / "incident-taxonomy.md").read_text()
    codes = {match.group(1) for match in CODE_ROW_RE.finditer(text)}
    if not codes:
        fail("incident taxonomy has no code rows")
    return codes


def extract_function_body(text: str, name: str) -> str:
    marker = f"fn {name}("
    start = text.find(marker)
    if start == -1:
        fail(f"daemon source missing function: {name}")
    brace = text.find("{", start)
    if brace == -1:
        fail(f"daemon source missing function body: {name}")
    depth = 0
    in_string = False
    escaped = False
    for index in range(brace, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:index]
    fail(f"daemon source has unterminated function body: {name}")


def validate_write_rpc_error_serializer(text: str) -> None:
    body = extract_function_body(text, "writeRpcError")
    if '.{code}' not in body:
        fail("writeRpcError must serialize the passed code argument")
    if 'writeJsonString(&writer.writer, message)' not in body:
        fail("writeRpcError must serialize the passed message argument")
    if 'writeJsonString(&writer.writer, incident_code)' not in body:
        fail("writeRpcError must serialize the passed incident_code argument")


def extract_daemon_error_mappings(text: str) -> dict[str, DaemonErrorMapping]:
    mappings: dict[str, DaemonErrorMapping] = {}
    for match in WRITE_RPC_ERROR_RE.finditer(text):
        code = int(match.group(1))
        message = match.group(2)
        incident = match.group(3)
        if incident not in ERROR_INCIDENTS:
            fail(f"daemon source has unexpected JSON-RPC incident mapping: {incident}")
        mapping = DaemonErrorMapping(incident=incident, code=code, message=message)
        previous = mappings.get(incident)
        if previous is not None and previous != mapping:
            fail(f"daemon source has conflicting JSON-RPC mapping for incident: {incident}")
        mappings[incident] = mapping
    return mappings


def validate_daemon_error_mappings(text: str) -> None:
    mappings = extract_daemon_error_mappings(text)
    missing = sorted(set(ERROR_INCIDENTS) - set(mappings))
    if missing:
        fail("daemon source missing JSON-RPC error mapping(s): " + ", ".join(missing))
    for incident in ERROR_INCIDENTS:
        component = ERROR_COMPONENT_BY_INCIDENT[incident]
        expected_code, expected_message = ERROR_JSON_RPC_MAPPING[component]
        actual = mappings[incident]
        if actual.code != expected_code or actual.message != expected_message:
            fail(
                f"daemon source JSON-RPC mapping mismatch for {incident}: "
                + f"expected ({expected_code}, {expected_message}), got ({actual.code}, {actual.message})"
            )


def validate_daemon_source(daemon: Path) -> None:
    text = daemon.read_text()
    for method in METHOD_SPECS:
        if f'"{method}"' not in text:
            fail(f"daemon source missing method: {method}")
    for schema in SCHEMA_STRINGS:
        if schema not in text:
            fail(f"daemon source missing schema string: {schema}")
    validate_write_rpc_error_serializer(text)
    validate_daemon_error_mappings(text)
    if "host_mutation" not in text or "false" not in text:
        fail("daemon source missing host_mutation=false JSON-RPC result/error invariant")
    replay_follow = 'request.method, "events.replay") or std.mem.eql(u8, request.method, "events.follow"'
    if replay_follow not in text:
        fail("daemon source must keep events.follow replay-equivalent with events.replay")


def validate_socket_test(path: Path) -> None:
    text = path.read_text()
    for method in SOCKET_METHODS:
        if method not in text:
            fail(f"socket RPC test missing method coverage: {method}")
    for incident in ERROR_INCIDENTS:
        if incident not in text:
            fail(f"socket RPC test missing incident coverage: {incident}")
    for code, message in ERROR_JSON_RPC_MAPPING.values():
        if str(code) not in text or message not in text:
            fail(f"socket RPC test missing error code/message assertion: ({code}, {message})")
    if "host_mutation" not in text or "False" not in text:
        fail("socket RPC test must assert host_mutation=false")
