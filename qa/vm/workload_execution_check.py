#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/vm/workload_execution_check.py --serial evidence/lab/<run>/live/serial.txt --scenario workload-cpu-saturation
# python3 qa/vm/workload_execution_check.py --self-test
"""Validate row-local workload_execution VM serial evidence."""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

JSON_MARKER: Final[str] = "ZIGSCHED_JSON "
PASS_STATUS: Final[str] = "PASS"
FAIL_STATUSES: Final[frozenset[str]] = frozenset(("FAIL", "REFUSE"))


@dataclass(frozen=True, slots=True)
class WorkloadExecution:
    scenario: str
    status: str
    rc: int
    host_mutation: bool


class WorkloadExecutionError(Exception):
    """Raised when workload_execution evidence cannot support a PASS row."""


def parse_json_events(serial_text: str) -> list[JsonObject]:
    events: list[JsonObject] = []
    for line_number, line in enumerate(serial_text.splitlines(), start=1):
        marker_index = line.find(JSON_MARKER)
        if marker_index < 0:
            continue
        try:
            raw = json.loads(line[marker_index + len(JSON_MARKER) :])
        except json.JSONDecodeError as exc:
            raise WorkloadExecutionError(f"invalid VM JSON event at serial line {line_number}: {exc.msg}") from exc
        if not isinstance(raw, dict):
            raise WorkloadExecutionError(f"VM JSON event at serial line {line_number} is not an object")
        events.append(raw)
    return events


def parse_workload_execution(row: JsonObject, context: str) -> WorkloadExecution:
    scenario = row.get("scenario")
    if not isinstance(scenario, str) or scenario == "":
        raise WorkloadExecutionError(f"{context}.scenario must be non-empty text")
    status = row.get("status")
    if not isinstance(status, str) or status == "":
        raise WorkloadExecutionError(f"{context}.status must be non-empty text")
    rc = row.get("rc")
    if not isinstance(rc, int):
        raise WorkloadExecutionError(f"{context}.rc must be an integer")
    host_mutation = row.get("host_mutation")
    if not isinstance(host_mutation, bool):
        raise WorkloadExecutionError(f"{context}.host_mutation must be a boolean")
    return WorkloadExecution(scenario=scenario, status=status, rc=rc, host_mutation=host_mutation)


def workload_execution_events(serial_text: str) -> list[WorkloadExecution]:
    parsed: list[WorkloadExecution] = []
    for index, event in enumerate(parse_json_events(serial_text)):
        if event.get("event") == "workload_execution":
            parsed.append(parse_workload_execution(event, f"workload_execution[{index}]"))
    return parsed


def require_workload_pass(serial_text: str, scenario: str) -> None:
    executions = [event for event in workload_execution_events(serial_text) if event.scenario == scenario]
    if not executions:
        raise WorkloadExecutionError(f"missing workload_execution evidence for scenario {scenario}")
    failing = [event for event in executions if event.status in FAIL_STATUSES or event.rc != 0 or event.host_mutation]
    if failing:
        statuses = ", ".join(f"{event.status}/rc={event.rc}" for event in failing)
        raise WorkloadExecutionError(f"workload_execution failure for scenario {scenario}: {statuses}")
    if not any(event.status == PASS_STATUS for event in executions):
        statuses = ", ".join(event.status for event in executions)
        raise WorkloadExecutionError(f"workload_execution for scenario {scenario} has no PASS status: {statuses}")


def validate_serial_file(serial: Path, scenario: str) -> None:
    require_workload_pass(serial.read_text(encoding="utf-8", errors="replace"), scenario)


def expect_reject(serial_text: str, scenario: str, label: str) -> None:
    try:
        require_workload_pass(serial_text, scenario)
    except WorkloadExecutionError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise WorkloadExecutionError(f"expected rejection did not occur: {label}")


def self_test() -> None:
    row_scenario = "workload-cpu-saturation"
    unrelated_pass = 'ZIGSCHED_JSON {"event":"workload_execution","scenario":"workload-cgroup-weight-quota","status":"PASS","rc":0,"host_mutation":false}'
    row_fail = 'ZIGSCHED_JSON {"event":"workload_execution","scenario":"workload-cpu-saturation","status":"FAIL","rc":9,"host_mutation":false}'
    row_pass = 'ZIGSCHED_JSON {"event":"workload_execution","scenario":"workload-cpu-saturation","status":"PASS","rc":0,"host_mutation":false}'
    expect_reject(f"{unrelated_pass}\n{row_fail}\n", row_scenario, "unrelated PASS with row-local FAIL")
    expect_reject(f"{unrelated_pass}\n", row_scenario, "unrelated PASS without row-local event")
    require_workload_pass(f"{unrelated_pass}\n{row_pass}\n", row_scenario)
    with TemporaryDirectory() as tmp:
        serial = Path(tmp) / "serial.txt"
        serial.write_text(f"{unrelated_pass}\n{row_pass}\n", encoding="utf-8")
        validate_serial_file(serial, row_scenario)
    print("PASS workload_execution no-fake-PASS self-test")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate row-local workload_execution PASS evidence in VM serial output.")
    _ = parser.add_argument("--serial", type=Path)
    _ = parser.add_argument("--scenario")
    _ = parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return args
    if args.serial is None or not isinstance(args.scenario, str) or args.scenario == "":
        parser.error("--serial and --scenario are required unless --self-test is used")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.self_test:
            self_test()
        else:
            validate_serial_file(args.serial, args.scenario)
            print(f"PASS workload_execution {args.scenario}")
        return 0
    except (OSError, WorkloadExecutionError) as exc:
        print(f"FAIL workload_execution: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
