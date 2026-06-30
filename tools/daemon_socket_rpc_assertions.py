from __future__ import annotations

from dataclasses import dataclass
from typing import NoReturn, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


@dataclass(frozen=True, slots=True)
class ExpectedRpcError:
    code: int
    message: str
    incident_code: str
    reason: str
    status: str
    state: str
    host_mutation: bool


def fail(message: str) -> NoReturn:
    raise SystemExit(f"FAIL daemon socket rpc: {message}")


def expected_rpc_error(code: int, message: str, incident_code: str) -> ExpectedRpcError:
    return ExpectedRpcError(
        code=code,
        message=message,
        incident_code=incident_code,
        reason=incident_code,
        status="REFUSE",
        state="refused_host",
        host_mutation=False,
    )


def rpc_error(response: JsonObject, expected: ExpectedRpcError) -> JsonObject:
    if response.get("jsonrpc") != "2.0":
        fail(f"bad jsonrpc error response: {response}")
    error = response.get("error")
    if not isinstance(error, dict):
        fail(f"missing error: {response}")
    if error.get("code") != expected.code:
        fail(f"error code drifted for {expected.incident_code}: {response}")
    if error.get("message") != expected.message:
        fail(f"error message drifted for {expected.incident_code}: {response}")
    data = error.get("data")
    if not isinstance(data, dict):
        fail(f"missing error data: {response}")
    expected_data: JsonObject = {
        "incident_code": expected.incident_code,
        "reason": expected.reason,
        "state": expected.state,
        "status": expected.status,
        "host_mutation": expected.host_mutation,
    }
    for key, value in expected_data.items():
        if data.get(key) != value:
            fail(f"error data {key} drifted for {expected.incident_code}: {response}")
    return data
