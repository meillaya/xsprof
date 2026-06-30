from __future__ import annotations

import json
import shutil
import tempfile
from pathlib import Path

from qa.frontend_contract_pack_types import JsonObject
from qa.openrpc_contract_model import OpenRpcContractError, fail, json_clone, list_field, load_contract, method_map, object_field, schema_components
from qa.openrpc_contract_validate import validate_contract


def valid_contract_fixture() -> JsonObject:
    return load_contract(Path("docs/control/daemon-openrpc.json"))


def expect_rejected(name: str, contract: JsonObject, message: str) -> None:
    try:
        validate_contract(contract, None, None)
    except OpenRpcContractError as exc:
        if message not in str(exc):
            fail(f"negative self-test {name} rejected for wrong reason: {exc}")
        return
    fail(f"negative self-test {name} unexpectedly passed")


def expect_daemon_rejected(name: str, contract: JsonObject, daemon: Path, message: str) -> None:
    try:
        validate_contract(contract, None, daemon)
    except OpenRpcContractError as exc:
        if message not in str(exc):
            fail(f"negative daemon self-test {name} rejected for wrong reason: {exc}")
        return
    fail(f"negative daemon self-test {name} unexpectedly passed")


def write_temp_daemon_tree(tmp: Path) -> Path:
    src_dir = tmp / "src"
    tools_dir = tmp / "tools"
    _ = src_dir.mkdir()
    _ = tools_dir.mkdir()
    daemon = src_dir / "daemon_main.zig"
    _ = shutil.copyfile(Path("src/daemon_main.zig"), daemon)
    _ = shutil.copyfile(Path("tools/daemon_socket_rpc_test.py"), tools_dir / "daemon_socket_rpc_test.py")
    return daemon


def replace_required(text: str, old: str, new: str, name: str) -> str:
    mutated = text.replace(old, new, 1)
    if mutated == text:
        fail(f"negative daemon self-test {name} could not apply mutation")
    return mutated


def run_self_test() -> None:
    base = valid_contract_fixture()
    validate_contract(base, None, None)

    unknown = json_clone(base)
    list_field(unknown, "methods", "self-test").append({"name": "daemon.undocumented", "params": [], "result": {"schema": {"$ref": "#/components/schemas/EventsResult"}}, "x-host-mutation": False, "x-error-incident-codes": [], "errors": []})
    expect_rejected("undocumented method", unknown, "method set mismatch")

    mismatch = json_clone(base)
    methods = method_map(mismatch)
    list_field(methods["actions.submit"], "params", "actions.submit")[0] = {"name": "action", "required": True, "schema": {"type": "string"}}
    expect_rejected("param mismatch", mismatch, "params mismatch")

    optional_action_json = json_clone(base)
    methods = method_map(optional_action_json)
    action_param = list_field(methods["actions.submit"], "params", "actions.submit")[0]
    if not isinstance(action_param, dict):
        fail("self-test action_json param must be an object")
    action_param["required"] = False
    expect_rejected("optional action_json", optional_action_json, "action_json must be required")

    cursor_schema_type = json_clone(base)
    for method_name in ("events.replay", "events.follow"):
        methods = method_map(cursor_schema_type)
        cursor_param = list_field(methods[method_name], "params", method_name)[0]
        if not isinstance(cursor_param, dict):
            fail(f"self-test {method_name} from_event_seq param must be an object")
        object_field(cursor_param, "schema", f"{method_name}.params[0]")["type"] = "string"
        expect_rejected(
            f"{method_name} string cursor type",
            cursor_schema_type,
            f"{method_name} from_event_seq schema must be integer",
        )
        cursor_schema_type = json_clone(base)

    cursor_default_type = json_clone(base)
    for method_name in ("events.replay", "events.follow"):
        methods = method_map(cursor_default_type)
        cursor_param = list_field(methods[method_name], "params", method_name)[0]
        if not isinstance(cursor_param, dict):
            fail(f"self-test {method_name} from_event_seq param must be an object")
        object_field(cursor_param, "schema", f"{method_name}.params[0]")["default"] = "1"
        expect_rejected(
            f"{method_name} string cursor default",
            cursor_default_type,
            f"{method_name} from_event_seq default must be 1",
        )
        cursor_default_type = json_clone(base)

    missing_method_errors = json_clone(base)
    for method in method_map(missing_method_errors).values():
        method["errors"] = []
    expect_rejected("missing per-method errors", missing_method_errors, "error references mismatch")

    wrong_error_code = json_clone(base)
    errors = object_field(object_field(wrong_error_code, "components", "contract"), "errors", "components")
    object_field(errors, "UnknownRpcMethod", "errors")["code"] = -32603
    expect_rejected("wrong JSON-RPC error code", wrong_error_code, "JSON-RPC mapping mismatch")

    wrong_error_message = json_clone(base)
    errors = object_field(object_field(wrong_error_message, "components", "contract"), "errors", "components")
    object_field(errors, "RpcActionMismatch", "errors")["message"] = "wrong_message"
    expect_rejected("wrong JSON-RPC error message", wrong_error_message, "JSON-RPC mapping mismatch")

    non_string_incident = json_clone(base)
    methods = method_map(non_string_incident)
    list_field(methods["daemon.version"], "x-error-incident-codes", "daemon.version").append(42)
    expect_rejected("non-string incident extension", non_string_incident, "must be a non-empty string")

    result_mismatch = json_clone(base)
    methods = method_map(result_mismatch)
    object_field(object_field(methods["targets.list"], "result", "targets.list"), "schema", "targets.list.result")["$ref"] = "#/components/schemas/EventsResult"
    expect_rejected("result mismatch", result_mismatch, "result mismatch")

    missing_host = json_clone(base)
    schemas = schema_components(missing_host)
    object_field(object_field(schemas["EventsResult"], "properties", "EventsResult"), "host_mutation", "EventsResult.properties")["const"] = True
    expect_rejected("host_mutation true", missing_host, "host_mutation must be const false")

    missing_error = json_clone(base)
    errors = object_field(object_field(missing_error, "components", "contract"), "errors", "components")
    del errors["RpcActionMismatch"]
    expect_rejected("missing incident mapping", missing_error, "missing incident")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp) / "bad-openrpc.json"
        _ = tmp_path.write_text(json.dumps(missing_host))
        try:
            validate_contract(load_contract(tmp_path), None, None)
        except OpenRpcContractError as exc:
            if "host_mutation must be const false" not in str(exc):
                fail(f"temporary mutated contract rejected for wrong reason: {exc}")
            print("PASS reject temporary mutated contract: host_mutation must be const false")
        else:
            fail("temporary mutated contract unexpectedly passed")

    with tempfile.TemporaryDirectory() as tmp:
        daemon = write_temp_daemon_tree(Path(tmp))
        source = daemon.read_text()
        _ = daemon.write_text(replace_required(
            source,
            'try writeRpcError(allocator, response, request.id, -32600, "invalid_request", "invalid_rpc_version");',
            'try writeRpcError(allocator, response, request.id, -32603, "wrong_message", "invalid_rpc_version");',
            "daemon invalid_rpc_version mapping drift",
        ))
        expect_daemon_rejected("daemon invalid_rpc_version mapping drift", base, daemon, "daemon source JSON-RPC mapping mismatch for invalid_rpc_version")

    with tempfile.TemporaryDirectory() as tmp:
        daemon = write_temp_daemon_tree(Path(tmp))
        source = daemon.read_text()
        _ = daemon.write_text(replace_required(
            source,
            'try writer.writer.print(",\\"error\\":{{\\"code\\":{d},\\"message\\":", .{code});',
            'try writer.writer.print(",\\"error\\":{{\\"code\\":{d},\\"message\\":", .{-32603});',
            "daemon writeRpcError hardcoded code",
        ))
        expect_daemon_rejected("daemon writeRpcError hardcoded code", base, daemon, "writeRpcError must serialize the passed code argument")
    print("PASS OpenRPC contract self-test")
