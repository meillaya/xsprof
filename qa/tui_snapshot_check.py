#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly (no venv, no pip install needed):
#      uv run qa/tui_snapshot_check.py <snapshot.txt> [<snapshot.txt> ...]
# 3. Or make executable and run:
#      chmod +x qa/tui_snapshot_check.py && ./qa/tui_snapshot_check.py <snapshot.txt>
# ──────────────────


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
VM_LIVE_REQUIRED: Final[tuple[str, ...]] = (
    "vm-live",
    "zigsched_minimal",
    "runtime samples",
    "rollback ready/completed",
    "release eligible",
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
    sched_ext_snapshot = "sched-ext" in path.name or any("sched_ext Readiness" in line for line in lines)
    if sched_ext_snapshot and not any("sched_ext Lab Lifecycle" in line for line in lines):
        issues.append(SnapshotIssue(path, 0, "missing lifecycle section"))
    if sched_ext_snapshot and "vm-live" in text:
        for required in VM_LIVE_REQUIRED:
            if required not in text:
                issues.append(SnapshotIssue(path, 0, f"missing vm-live lifecycle field: {required}"))
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
