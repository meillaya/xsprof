from __future__ import annotations

from pathlib import Path

from qa.frontend_contract_pack_types import JsonObject
from qa.openrpc_contract_daemon import load_taxonomy_codes, validate_daemon_source, validate_socket_test
from qa.openrpc_contract_model import (
    DOC_FILES,
    ERROR_COMPONENT_BY_INCIDENT,
    ERROR_INCIDENTS,
    ERROR_JSON_RPC_MAPPING,
    METHOD_SPECS,
    SCHEMA_STRINGS,
    bool_field,
    error_components,
    error_ref_name,
    fail,
    int_field,
    list_field,
    method_map,
    object_field,
    schema_components,
    schema_ref_name,
    string_field,
)


def validate_required_contract_header(contract: JsonObject) -> None:
    if string_field(contract, "openrpc", "contract") != "1.4.0":
        fail("contract.openrpc must be 1.4.0")
    if string_field(contract, "$schema", "contract") != "https://meta.open-rpc.org/":
        fail("contract.$schema must point at the OpenRPC meta-schema")
    if bool_field(contract, "x-backend-only", "contract") is not True:
        fail("contract must declare x-backend-only=true")
    if bool_field(contract, "x-host-mutation", "contract") is not False:
        fail("contract must declare x-host-mutation=false")
    info = object_field(contract, "info", "contract")
    description = string_field(info, "description", "contract.info").lower()
    forbidden = ("http", "sse", "browser", "frontend", "ui", "production")
    if "no frontend" not in description or "http" not in description:
        fail("contract.info.description must explicitly reject non-backend transports/claims")
    if not all(word in description for word in forbidden):
        fail("contract.info.description missing backend-only guardrail words")


def validate_method(method: JsonObject, expected_name: str) -> None:
    expected_params, expected_result, expected_incidents = METHOD_SPECS[expected_name]
    if bool_field(method, "x-host-mutation", expected_name) is not False:
        fail(f"{expected_name} missing x-host-mutation=false")
    validate_method_params(method, expected_name, expected_params)
    result = object_field(method, "result", expected_name)
    schema = object_field(result, "schema", f"{expected_name}.result")
    actual_result = schema_ref_name(schema, f"{expected_name}.result.schema")
    if actual_result != expected_result:
        fail(f"{expected_name} result mismatch: expected {expected_result}, got {actual_result}")
    validate_method_incidents(method, expected_name, expected_incidents)
    validate_method_error_refs(method, expected_name, expected_incidents)


def validate_method_params(method: JsonObject, expected_name: str, expected_params: tuple[str, ...]) -> None:
    raw_params = list_field(method, "params", expected_name)
    actual_params: list[str] = []
    for index, value in enumerate(raw_params):
        if not isinstance(value, dict):
            fail(f"{expected_name}.params[{index}] must be an object")
        actual_params.append(string_field(value, "name", f"{expected_name}.params[{index}]"))
        validate_param_shape(value, expected_name, index)
    if tuple(actual_params) != expected_params:
        fail(f"{expected_name} params mismatch: expected {expected_params}, got {tuple(actual_params)}")


def validate_param_shape(param: JsonObject, method_name: str, index: int) -> None:
    name = string_field(param, "name", f"{method_name}.params[{index}]")
    context = f"{method_name}.params[{index}]"
    if name == "action_json":
        if bool_field(param, "required", context) is not True:
            fail(f"{method_name} action_json must be required")
        schema = object_field(param, "schema", context)
        if schema.get("type") != "string":
            fail(f"{method_name} action_json schema must be string")
        return
    if name == "from_event_seq":
        if method_name not in {"events.replay", "events.follow"}:
            fail(f"{method_name} from_event_seq is only valid on event cursor methods")
        if bool_field(param, "required", context) is not False:
            fail(f"{method_name} from_event_seq must stay optional")
        schema = object_field(param, "schema", context)
        if schema.get("type") != "integer":
            fail(f"{method_name} from_event_seq schema must be integer")
        if schema.get("minimum") != 1:
            fail(f"{method_name} from_event_seq minimum must be 1")
        if schema.get("default") != 1:
            fail(f"{method_name} from_event_seq default must be 1")


def validate_method_incidents(method: JsonObject, expected_name: str, expected_incidents: tuple[str, ...]) -> None:
    raw_incidents = list_field(method, "x-error-incident-codes", expected_name)
    incidents: list[str] = []
    for index, value in enumerate(raw_incidents):
        if not isinstance(value, str):
            fail(f"{expected_name}.x-error-incident-codes[{index}] must be a non-empty string")
        if value == "":
            fail(f"{expected_name}.x-error-incident-codes[{index}] must be a non-empty string")
        incidents.append(value)
    if tuple(incidents) != expected_incidents:
        fail(f"{expected_name} incident mapping mismatch: expected {expected_incidents}, got {tuple(incidents)}")


def validate_method_error_refs(method: JsonObject, expected_name: str, expected_incidents: tuple[str, ...]) -> None:
    expected_refs = tuple(ERROR_COMPONENT_BY_INCIDENT[incident] for incident in expected_incidents)
    raw_errors = list_field(method, "errors", expected_name)
    actual_refs: list[str] = []
    for index, value in enumerate(raw_errors):
        if not isinstance(value, dict):
            fail(f"{expected_name}.errors[{index}] must be an object")
        actual_refs.append(error_ref_name(value, f"{expected_name}.errors[{index}]"))
    if set(actual_refs) != set(expected_refs) or len(actual_refs) != len(expected_refs):
        fail(f"{expected_name} error references mismatch: expected {expected_refs}, got {tuple(actual_refs)}")


def validate_result_schemas(schemas: dict[str, JsonObject]) -> None:
    for name in ("DaemonVersionResult", "TargetsListResult", "EventsResult", "RpcErrorData"):
        if name not in schemas:
            fail(f"missing schema component: {name}")
        required = list_field(schemas[name], "required", f"schemas.{name}")
        if "host_mutation" not in required:
            fail(f"schemas.{name} must require host_mutation")
        properties = object_field(schemas[name], "properties", f"schemas.{name}")
        host = object_field(properties, "host_mutation", f"schemas.{name}.properties")
        if host.get("const") is not False:
            fail(f"schemas.{name}.host_mutation must be const false")
    version_props = object_field(schemas["DaemonVersionResult"], "properties", "DaemonVersionResult")
    schema_fields = (
        ("event_schema", SCHEMA_STRINGS[0]),
        ("action_schema", SCHEMA_STRINGS[1]),
        ("runtime_sample_schema", SCHEMA_STRINGS[2]),
    )
    for field, value in schema_fields:
        if object_field(version_props, field, "DaemonVersionResult.properties").get("const") != value:
            fail(f"DaemonVersionResult.{field} schema string drifted")


def validate_errors(errors: dict[str, JsonObject], taxonomy_codes: set[str]) -> None:
    mapped: set[str] = set()
    for name, error in errors.items():
        expected_mapping = ERROR_JSON_RPC_MAPPING.get(name)
        if expected_mapping is None:
            fail(f"unexpected JSON-RPC error component: {name}")
        expected_code, expected_message = expected_mapping
        actual_code = int_field(error, "code", f"errors.{name}")
        actual_message = string_field(error, "message", f"errors.{name}")
        if actual_code != expected_code or actual_message != expected_message:
            fail(f"errors.{name} JSON-RPC mapping mismatch: expected ({expected_code}, {expected_message}), got ({actual_code}, {actual_message})")
        data = object_field(error, "data", f"errors.{name}")
        incident = string_field(data, "incident_code", f"errors.{name}.data")
        reason = string_field(data, "reason", f"errors.{name}.data")
        if incident != reason:
            fail(f"errors.{name} incident_code and reason must match")
        if incident not in taxonomy_codes:
            fail(f"errors.{name} incident code missing from taxonomy: {incident}")
        if data.get("state") != "refused_host" or data.get("status") != "REFUSE" or data.get("host_mutation") is not False:
            fail(f"errors.{name} data must preserve refused_host/REFUSE/host_mutation=false")
        mapped.add(incident)
    missing = sorted(set(ERROR_INCIDENTS) - mapped)
    if missing:
        fail(f"contract error components missing incident(s): {', '.join(missing)}")


def validate_docs(contract: JsonObject, docs: Path) -> None:
    doc_text = "\n".join((docs / name).read_text() for name in DOC_FILES)
    for method in METHOD_SPECS:
        if method not in doc_text:
            fail(f"docs missing JSON-RPC method: {method}")
    for schema in SCHEMA_STRINGS:
        if schema not in doc_text:
            fail(f"docs missing schema string: {schema}")
    if "one-shot follow equivalent to replay" not in doc_text and "follow equivalent to replay" not in doc_text:
        fail("docs must freeze events.follow as replay-equivalent for v1")
    if "host_mutation=false" not in doc_text:
        fail("docs must preserve host_mutation=false invariant")
    if string_field(contract, "x-build-wiring-todo10", "contract") == "":
        fail("contract must record Todo 10 build wiring")


def validate_contract(contract: JsonObject, docs: Path | None, daemon: Path | None) -> None:
    validate_required_contract_header(contract)
    methods = method_map(contract)
    expected = set(METHOD_SPECS)
    actual = set(methods)
    if actual != expected:
        fail(f"method set mismatch: missing={sorted(expected - actual)} extra={sorted(actual - expected)}")
    for method_name, method in methods.items():
        validate_method(method, method_name)
    validate_result_schemas(schema_components(contract))
    taxonomy_codes = set(ERROR_INCIDENTS) if docs is None else load_taxonomy_codes(docs)
    validate_errors(error_components(contract), taxonomy_codes)
    if docs is not None:
        validate_docs(contract, docs)
    if daemon is not None:
        validate_daemon_source(daemon)
        validate_socket_test(daemon.parent.parent / "tools" / "daemon_socket_rpc_test.py")
