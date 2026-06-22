#!/usr/bin/env python3
"""Validate the backend capability matrix against its explicit contract."""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from json import JSONDecodeError
from pathlib import Path
from typing import Final


EXPECTED_CONTRACT_PATH: Final[Path] = Path(__file__).with_name("backend_capability_matrix_expected.json")
EXPECTED_SCHEMA: Final[str] = "zig-scheduler/backend-capability-matrix-contract/v1"
FRONTEND_TERMS: Final[tuple[str, ...]] = ("frontend", "theme", "animation", "hotkey", "tui", "webview", "browser", "desktop")
DEFERRED_MARKERS: Final[tuple[str, ...]] = ("deferred", "non-goal", "not implement", "no source", "no build")
PROMPT_INJECTION_TERMS: Final[tuple[str, ...]] = (
    "ignore all failures", "ignore failures", "checker to ignore", "ignore the checker", "pass the checker",
    "tells the checker", "force pass", "always pass", "treat as pass", "bypass checker",
)
POSITIVE_FRONTEND_CLAIMS: Final[tuple[str, ...]] = (
    "frontend implemented", "frontend delivered", "frontend build is complete", "frontend build are complete",
    "frontend build artifact is ready", "theme implemented", "animation implemented", "hotkey implemented",
    "tui implemented", "webview implemented", "browser implemented", "desktop implemented",
    "webview source is ready", "desktop build is complete",
)


@dataclass(frozen=True, slots=True)
class MatrixRow:
    row_id: str
    design_claim: str
    backend_obligation: str
    evidence_gate: str


@dataclass(frozen=True, slots=True)
class ExpectedRow:
    row_id: str
    design_claim: str
    backend_obligation: str
    evidence_gate: str
    deferred: bool


class MatrixError(Exception):
    """Raised when the backend capability matrix is incomplete or unsafe."""


def parse_args(argv: list[str]) -> Path:
    if len(argv) == 2 and argv[0] == "--matrix":
        return Path(argv[1])
    raise MatrixError("usage: backend_capability_matrix_check.py --matrix <path>")


def cell_text(cell: str) -> str:
    return cell.strip().strip("`").strip()


def normalize_cell(text: str) -> str:
    return " ".join(text.split())


def parse_rows(text: str) -> tuple[list[MatrixRow], list[str]]:
    rows: list[MatrixRow] = []
    failures: list[str] = []
    for line_no, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line.startswith("|"):
            continue
        cells = [cell_text(cell) for cell in line.strip("|").split("|")]
        if not cells or cells[0] in {"ID", "---"} or set(cells[0]) <= {"-", " ", ":"}:
            continue
        if len(cells) != 4:
            failures.append(f"line {line_no}: matrix row must have 4 cells")
            continue
        rows.append(
            MatrixRow(
                row_id=cells[0],
                design_claim=cells[1],
                backend_obligation=cells[2],
                evidence_gate=cells[3],
            ),
        )
    if not rows:
        failures.append("matrix table must contain backend capability rows")
    return rows, failures


def parse_expected_row(raw_row, index: int) -> ExpectedRow:
    match raw_row:
        case {
            "id": str(row_id),
            "design_claim": str(design_claim),
            "backend_obligation": str(backend_obligation),
            "evidence_gate": str(evidence_gate),
            "deferred": bool(deferred),
        }:
            return ExpectedRow(
                row_id=row_id,
                design_claim=design_claim,
                backend_obligation=backend_obligation,
                evidence_gate=evidence_gate,
                deferred=deferred,
            )
        case _:
            raise MatrixError(f"expected contract row {index} is malformed")


def load_expected_rows(path: Path) -> tuple[ExpectedRow, ...]:
    try:
        raw_contract = json.loads(path.read_text())
    except JSONDecodeError as exc:
        raise MatrixError(f"expected contract JSON is invalid: {exc}") from exc
    match raw_contract:
        case {"schema": str(schema), "rows": list(raw_rows)} if schema == EXPECTED_SCHEMA:
            return tuple(parse_expected_row(raw_row, index) for index, raw_row in enumerate(raw_rows, start=1))
        case _:
            raise MatrixError("expected contract must contain schema v1 and rows")


def collect_duplicate_ids(row_ids: list[str]) -> list[str]:
    seen: set[str] = set()
    duplicates: list[str] = []
    for row_id in row_ids:
        if row_id in seen and row_id not in duplicates:
            duplicates.append(row_id)
        seen.add(row_id)
    return duplicates


def first_rows_by_id(rows: list[MatrixRow]) -> dict[str, MatrixRow]:
    rows_by_id: dict[str, MatrixRow] = {}
    for row in rows:
        if row.row_id not in rows_by_id:
            rows_by_id[row.row_id] = row
    return rows_by_id


def validate_contract(rows: list[MatrixRow], expected_rows: tuple[ExpectedRow, ...]) -> list[str]:
    failures: list[str] = []
    actual_ids = [row.row_id for row in rows]
    expected_ids = [row.row_id for row in expected_rows]
    expected_id_set = set(expected_ids)
    actual_id_set = set(actual_ids)
    for row_id in collect_duplicate_ids(actual_ids):
        failures.append(f"duplicate matrix row: {row_id}")
    failures.extend(f"missing required matrix row: {row_id}" for row_id in expected_ids if row_id not in actual_id_set)
    failures.extend(f"unexpected matrix row: {row_id}" for row_id in actual_ids if row_id not in expected_id_set)
    if actual_ids != expected_ids:
        failures.append("matrix row order/IDs must match qa/backend_capability_matrix_expected.json")
    actual_by_id = first_rows_by_id(rows)
    for expected in expected_rows:
        actual = actual_by_id.get(expected.row_id)
        if actual is None:
            continue
        failures.extend(validate_row_cells(actual, expected))
    return failures


def validate_row_cells(actual: MatrixRow, expected: ExpectedRow) -> list[str]:
    failures: list[str] = []
    checks = (
        ("design claim / cue", actual.design_claim, expected.design_claim),
        ("backend obligation", actual.backend_obligation, expected.backend_obligation),
        ("evidence and gate", actual.evidence_gate, expected.evidence_gate),
    )
    for label, actual_cell, expected_cell in checks:
        if normalize_cell(actual_cell) != normalize_cell(expected_cell):
            failures.append(f"{actual.row_id}: {label} cell differs from expected contract")
    return failures


def frontend_row_text(row: MatrixRow) -> str:
    return f"{row.design_claim} {row.backend_obligation} {row.evidence_gate}".lower()


def has_deferred_marker(text: str) -> bool:
    return any(marker in text for marker in DEFERRED_MARKERS)


def positive_frontend_claim(text: str) -> str | None:
    for claim in POSITIVE_FRONTEND_CLAIMS:
        if claim in text:
            return claim
    return None


def validate_frontend_scope(rows: list[MatrixRow], expected_rows: tuple[ExpectedRow, ...], prose: str) -> list[str]:
    failures: list[str] = []
    deferred_ids = {row.row_id for row in expected_rows if row.deferred}
    for row in rows:
        text = frontend_row_text(row)
        claim = positive_frontend_claim(text)
        if claim is not None:
            failures.append(f"{row.row_id}: frontend implementation claim is forbidden: {claim}")
        if row.row_id in deferred_ids and any(term in text for term in FRONTEND_TERMS) and not has_deferred_marker(text):
            failures.append(f"{row.row_id}: frontend/theme/UI terms must be deferred/non-goal in row content")
    for raw_line in prose.splitlines():
        lowered = raw_line.lower()
        if any(term in lowered for term in FRONTEND_TERMS) and not has_deferred_marker(lowered):
            failures.append(f"frontend/theme/UI prose must be explicitly deferred/non-goal: {raw_line.strip()}")
    return failures


def prose_without_table_rows(text: str) -> str:
    lines: list[str] = []
    for raw_line in text.splitlines():
        if not raw_line.strip().startswith("|"):
            lines.append(raw_line)
    return "\n".join(lines)


def validate_global_text(text: str) -> list[str]:
    failures: list[str] = []
    if "design.html" not in text:
        failures.append("matrix must name design.html as inert product evidence")
    if "host_mutation=false" not in text:
        failures.append("matrix must preserve host_mutation=false safety contract")
    if "rollback" not in text.lower():
        failures.append("matrix must include rollback obligations")
    if "lifecycle" not in text.lower():
        failures.append("matrix must include lifecycle obligations")
    lowered_text = text.lower()
    for term in PROMPT_INJECTION_TERMS:
        if term in lowered_text:
            failures.append(f"matrix contains prompt-injection/pass override language: {term}")
    return failures


def validate_matrix(path: Path) -> list[str]:
    text = path.read_text()
    expected_rows = load_expected_rows(EXPECTED_CONTRACT_PATH)
    rows, failures = parse_rows(text)
    failures.extend(validate_contract(rows, expected_rows))
    failures.extend(validate_global_text(text))
    failures.extend(validate_frontend_scope(rows, expected_rows, prose_without_table_rows(text)))
    return failures


def main(argv: list[str]) -> int:
    try:
        matrix_path = parse_args(argv)
        failures = validate_matrix(matrix_path)
    except FileNotFoundError:
        print("FAIL: missing file")
        return 1
    except MatrixError as exc:
        print(f"FAIL: {exc}")
        return 1
    if failures:
        print("FAIL: backend capability matrix")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print(f"PASS: backend capability matrix ({matrix_path})")
    print(f"required_rows={len(load_expected_rows(EXPECTED_CONTRACT_PATH))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
