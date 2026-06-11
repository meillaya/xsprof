# /// script
# requires-python = ">=3.11"
# ///
# ─── How to run ───
# python3 qa/tui_snapshot_check.py <snapshot.txt> [<snapshot.txt> ...]

from __future__ import annotations

import re
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Final

ANSI_PATTERN: Final[re.Pattern[str]] = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
FORBIDDEN: Final[tuple[str, ...]] = (
    "Task Metrics",
    "completion_order",
    "Gantt",
    "production-ready",
)


@dataclass(frozen=True, slots=True)
class SnapshotIssue:
    path: Path
    line: int
    message: str


def cell_width(char: str) -> int:
    if unicodedata.combining(char):
        return 0
    if unicodedata.category(char) in {"Cc", "Cf"}:
        return 0
    if unicodedata.east_asian_width(char) in {"F", "W"}:
        return 2
    return 1


def display_width(text: str) -> int:
    return sum(cell_width(char) for char in text)


def strip_ansi(text: str) -> str:
    return ANSI_PATTERN.sub("", text)


def expected_width(lines: list[str]) -> int:
    for line in lines:
        stripped = strip_ansi(line)
        if stripped.startswith("╭") or stripped.startswith("┌"):
            return display_width(stripped)
    raise RuntimeError("snapshot has no top border")


def inspect_snapshot(path: Path) -> list[SnapshotIssue]:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        return [SnapshotIssue(path, exc.start + 1, f"invalid UTF-8: {exc.reason}")]
    lines = text.splitlines()
    width = expected_width(lines)
    issues: list[SnapshotIssue] = []
    for index, line in enumerate(lines, start=1):
        stripped = strip_ansi(line)
        current_width = display_width(stripped)
        if current_width > width:
            issues.append(SnapshotIssue(path, index, f"line width {current_width} exceeds {width}"))
        if stripped and stripped[0] in {"│", "├", "╰", "╭"} and current_width != width:
            issues.append(SnapshotIssue(path, index, f"border row width {current_width} differs from {width}"))
        for forbidden in FORBIDDEN:
            if forbidden.lower() in stripped.lower():
                issues.append(SnapshotIssue(path, index, f"forbidden text: {forbidden}"))
    if not any("sched_ext Lab Lifecycle" in line for line in lines):
        issues.append(SnapshotIssue(path, 0, "missing lifecycle section"))
    return issues


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: tui_snapshot_check.py <snapshot.txt> [<snapshot.txt> ...]", file=sys.stderr)
        return 2
    issues: list[SnapshotIssue] = []
    for raw in argv[1:]:
        issues.extend(inspect_snapshot(Path(raw)))
    if issues:
        for issue in issues:
            print(f"{issue.path}:{issue.line}: {issue.message}", file=sys.stderr)
        return 1
    print(f"PASS: validated {len(argv) - 1} TUI snapshots")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
