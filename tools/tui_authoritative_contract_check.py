#!/usr/bin/env python3
"""Validate a live-VM TUI transcript against the authoritative text contract."""

from __future__ import annotations

import argparse
from collections.abc import Callable
from dataclasses import dataclass
import json
import sys
from pathlib import Path
from typing import Final, TypeAlias, override

SCHEMA: Final[str] = "zig-scheduler/tui-authoritative-live-vm-contract/v1"
INITIAL_PHASE_SEPARATORS: Final[tuple[str, ...]] = (
    "\n=== AFTER CONTINUE ===\n",
    "\n=== after continue ===\n",
    "\n## after continue\n",
    "\n## after-enter\n",
    "\f",
)
REQUIRED_SECTIONS: Final[tuple[str, ...]] = (
    "initial_screen",
    "after_continue_screen",
    "dashboard_screen",
    "controls_help",
    "incident_failure_markers",
)
JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
LOAD_JSON: Callable[[str], JsonValue] = json.loads


@dataclass(frozen=True, slots=True)
class ContractError(Exception):
    detail: str

    @override
    def __str__(self) -> str:
        return self.detail


@dataclass(frozen=True, slots=True)
class ProvenanceSource:
    path: str
    sha256: str


@dataclass(frozen=True, slots=True)
class MarkerGroup:
    name: str
    markers: list[str]


@dataclass(frozen=True, slots=True)
class ContractSection:
    required_markers: list[str]
    any_of: list[MarkerGroup]
    forbidden_before_continue: list[str]


@dataclass(frozen=True, slots=True)
class AuthoritativeContract:
    derived_from: list[ProvenanceSource]
    sections: dict[str, ContractSection]
    ordered_groups: list[MarkerGroup]


class CliNamespace(argparse.Namespace):
    contract: Path | None
    transcript: Path | None

    def __init__(self) -> None:
        super().__init__()
        self.contract = None
        self.transcript = None


@dataclass(frozen=True, slots=True)
class CliArgs:
    contract: Path
    transcript: Path


def parse_args(argv: list[str]) -> CliArgs:
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument("--contract", required=True, type=Path, help="contract JSON fixture")
    _ = parser.add_argument("--transcript", required=True, type=Path, help="captured TUI transcript text")
    parsed = parser.parse_args(argv, namespace=CliNamespace())
    if parsed.contract is None or parsed.transcript is None:
        raise ContractError("missing required contract checker arguments")
    return CliArgs(contract=parsed.contract, transcript=parsed.transcript)


def load_json_object(path: Path) -> JsonObject:
    try:
        raw = LOAD_JSON(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ContractError(f"missing contract fixture: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ContractError(f"invalid contract JSON {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ContractError("contract root must be a JSON object")
    return raw


def load_contract(path: Path) -> AuthoritativeContract:
    raw = load_json_object(path)
    schema = require_string(raw.get("schema"), "schema")
    if schema != SCHEMA:
        raise ContractError(f"unsupported contract schema: {schema!r}")
    return parse_contract(raw)


def read_transcript(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError as exc:
        raise ContractError(f"missing transcript: {path}") from exc
    if text == "":
        raise ContractError(f"empty transcript: {path}")
    return text


def require_string(value: JsonValue | None, field: str) -> str:
    if not isinstance(value, str) or value == "":
        raise ContractError(f"contract field {field} must be a non-empty string")
    return value


def require_string_list(value: JsonValue | None, field: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise ContractError(f"contract field {field} must be a non-empty string list")
    result: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or item == "":
            raise ContractError(f"contract field {field}[{index}] must be a non-empty string")
        result.append(item)
    return result


def optional_string_list(value: JsonValue | None, field: str) -> list[str]:
    if value is None:
        return []
    return require_string_list(value, field)


def require_object_list(value: JsonValue | None, field: str) -> list[JsonObject]:
    if not isinstance(value, list) or not value:
        raise ContractError(f"contract field {field} must be a non-empty object list")
    result: list[JsonObject] = []
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise ContractError(f"contract field {field}[{index}] must be an object")
        result.append(item)
    return result


def section(contract: JsonObject, name: str) -> JsonObject:
    value = contract.get(name)
    if not isinstance(value, dict):
        raise ContractError(f"contract section {name} must be an object")
    return value


def parse_marker_groups(value: JsonValue | None, field: str) -> list[MarkerGroup]:
    groups: list[MarkerGroup] = []
    for index, group in enumerate(require_object_list(value, field)):
        groups.append(
            MarkerGroup(
                name=require_string(group.get("name"), f"{field}[{index}].name"),
                markers=require_string_list(group.get("markers"), f"{field}[{index}].markers"),
            )
        )
    return groups


def parse_optional_marker_groups(value: JsonValue | None, field: str) -> list[MarkerGroup]:
    if value is None:
        return []
    return parse_marker_groups(value, field)


def parse_provenance(raw: JsonObject) -> list[ProvenanceSource]:
    sources: list[ProvenanceSource] = []
    for index, item in enumerate(require_object_list(raw.get("derived_from"), "derived_from")):
        sources.append(
            ProvenanceSource(
                path=require_string(item.get("path"), f"derived_from[{index}].path"),
                sha256=require_string(item.get("sha256"), f"derived_from[{index}].sha256"),
            )
        )
    return sources


def parse_contract_section(raw: JsonObject, name: str) -> ContractSection:
    current = section(raw, name)
    return ContractSection(
        required_markers=require_string_list(current.get("required_markers"), f"{name}.required_markers"),
        any_of=parse_optional_marker_groups(current.get("any_of"), f"{name}.any_of"),
        forbidden_before_continue=optional_string_list(
            current.get("forbidden_before_continue"),
            f"{name}.forbidden_before_continue",
        ),
    )


def parse_contract(raw: JsonObject) -> AuthoritativeContract:
    return AuthoritativeContract(
        derived_from=parse_provenance(raw),
        sections={name: parse_contract_section(raw, name) for name in REQUIRED_SECTIONS},
        ordered_groups=parse_marker_groups(raw.get("ordered_groups"), "ordered_groups"),
    )


def line_for_missing(label: str, needle: str) -> str:
    return f"FAIL {label}: missing required marker {needle!r}"


def check_required(transcript: str, label: str, markers: list[str]) -> list[str]:
    return [line_for_missing(label, marker) for marker in markers if marker not in transcript]


def check_forbidden(transcript: str, label: str, markers: list[str]) -> list[str]:
    return [f"FAIL {label}: forbidden pre-continue marker is visible {marker!r}" for marker in markers if marker in transcript]


def check_ordered(transcript: str, label: str, markers: list[str]) -> list[str]:
    failures: list[str] = []
    cursor = 0
    for marker in markers:
        pos = transcript.find(marker, cursor)
        if pos < 0:
            failures.append(f"FAIL {label}: missing ordered marker {marker!r} after byte offset {cursor}")
        else:
            cursor = pos + len(marker)
    return failures


def check_any_of(transcript: str, label: str, groups: list[MarkerGroup]) -> list[str]:
    failures: list[str] = []
    for group in groups:
        if not any(marker in transcript for marker in group.markers):
            failures.append(f"FAIL {label}: missing any marker for {group.name!r}: {group.markers!r}")
    return failures


def initial_phase(transcript: str) -> str:
    """Return the transcript span before the user continues from the hero.

    Single-screen captures have no separator, so the entire capture is the
    initial phase. Multi-screen evidence can insert one of these plain text
    separators before the picker/dashboard transcript.
    """
    cut = len(transcript)
    for separator in INITIAL_PHASE_SEPARATORS:
        pos = transcript.find(separator)
        if pos >= 0:
            cut = min(cut, pos)
    return transcript[:cut]


def validate_provenance(contract: AuthoritativeContract) -> list[str]:
    failures: list[str] = []
    for source in contract.derived_from:
        if not source.path.startswith(".omo/evidence/authoritative-design-review/"):
            failures.append(f"FAIL provenance: source path is outside authoritative design review captures {source.path!r}")
        if len(source.sha256) != 64 or any(ch not in "0123456789abcdef" for ch in source.sha256):
            failures.append(f"FAIL provenance: source {source.path!r} has invalid sha256 {source.sha256!r}")
    return failures


def validate_sections(contract: AuthoritativeContract, transcript: str) -> list[str]:
    failures: list[str] = []
    initial_transcript = initial_phase(transcript)

    for name, current in contract.sections.items():
        target = initial_transcript if name == "initial_screen" else transcript
        failures.extend(check_required(target, name, current.required_markers))
        failures.extend(check_any_of(target, name, current.any_of))
        failures.extend(check_forbidden(initial_transcript, name, current.forbidden_before_continue))

    return failures


def validate_ordered_groups(contract: AuthoritativeContract, transcript: str) -> list[str]:
    failures: list[str] = []
    for group in contract.ordered_groups:
        failures.extend(check_ordered(transcript, group.name, group.markers))
    return failures


def validate(contract: AuthoritativeContract, transcript: str) -> list[str]:
    failures: list[str] = []
    failures.extend(validate_provenance(contract))
    failures.extend(validate_sections(contract, transcript))
    failures.extend(validate_ordered_groups(contract, transcript))
    return failures


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        contract = load_contract(args.contract)
        transcript = read_transcript(args.transcript)
        failures = validate(contract, transcript)
    except ContractError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if failures:
        for failure in failures:
            print(failure)
        print(
            f"RED authoritative TUI contract: {len(failures)} failure(s) in {args.transcript} against {args.contract}",
            file=sys.stderr,
        )
        return 1

    print(f"PASS authoritative TUI contract: {args.transcript} matches {args.contract}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
