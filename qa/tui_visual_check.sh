#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TUI_CHECK=${TUI_CHECK:-/home/mei/.codex/plugins/cache/sisyphuslabs/omo/4.11.0/skills/visual-qa/scripts/cli.ts}

# SIZE_OK: this harness intentionally stays in one shell entrypoint because the
# gate evidence calls it directly and it has one responsibility: validate static
# TUI captures for visual-family grammar, root-only semantics, ANSI evidence, and
# malformed input behavior. The embedded Python is pure validation/fixture code,
# avoids new repo dependencies, and is covered by --self-test cases below.

usage() {
  cat <<'USAGE' >&2
usage: qa/tui_visual_check.sh --reference <sim-capture> --actual <root-capture> [--ansi <root-ansi>] [--cols <N>] [--self-test]

Validates root operator TUI visual family against a simulator reference capture without exact text matching.
Checks overflow, border alignment, simulator-family grammar tokens, root operator tokens,
forbidden simulator semantics in root captures, and ANSI presence when --ansi is supplied.
USAGE
}

reference=""
actual=""
ansi=""
cols=""
self_test=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reference) reference=${2:-}; shift 2 ;;
    --actual) actual=${2:-}; shift 2 ;;
    --ansi) ansi=${2:-}; shift 2 ;;
    --cols) cols=${2:-}; shift 2 ;;
    --self-test) self_test=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

validate_cli_inputs() {
  local missing=0
  if [[ -z "$reference" ]]; then
    echo "missing required --reference path" >&2
    missing=1
  elif [[ ! -f "$reference" ]]; then
    echo "reference capture does not exist: $reference" >&2
    missing=1
  fi
  if [[ -z "$actual" ]]; then
    echo "missing required --actual path" >&2
    missing=1
  elif [[ ! -f "$actual" ]]; then
    echo "actual capture does not exist: $actual" >&2
    missing=1
  fi
  if [[ -n "$ansi" && ! -f "$ansi" ]]; then
    echo "ansi capture does not exist: $ansi" >&2
    missing=1
  fi
  if [[ $missing -ne 0 ]]; then
    return 2
  fi
}

run_tui_check() {
  local file=$1
  local width=$2
  if [[ -f "$TUI_CHECK" ]] && command -v bun >/dev/null 2>&1; then
    bun "$TUI_CHECK" tui-check "$file" --cols "$width"
  else
    echo "SKIP: bundled tui-check unavailable; using built-in width/border checks only" >&2
  fi
}

run_validator() {
  local ref=$1
  local act=$2
  local ansi_file=$3
  local width_arg=$4
  python3 - "$ref" "$act" "$ansi_file" "$width_arg" <<'PY'
from __future__ import annotations

import re
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
BORDER_LEFT = {"│", "├", "╭", "╰", "┌", "└"}
BORDER_RIGHT = {"│", "┤", "╮", "╯", "┐", "┘"}
REFERENCE_FAMILY_TOKENS = (
    "▚ zig-scheduler",
    "│",
    "─",
    "┌",
    "└",
)
ACTUAL_FAMILY_TOKENS = (
    "▚ zig-scheduler",
    "NORMAL",
    "↵",
    "╭",
    "╰",
    "├",
    "│",
)
ROOT_REQUIRED_TOKENS = (
    "live microVM lab",
    "lifecycle lanes",
    "runtime samples",
    "rollback",
    "cleanup",
    "FAIL-CLOSED",
    "host fail-closed",
    "zigsched_minimal",
)
FORBIDDEN_ROOT_TOKENS = (
    "Task Metrics",
    "completion_order",
    "Gantt",
    "scenario arrivals",
    "policy [FCFS]",
    "run queue",
    "arrival tick",
    "production-ready",
)

@dataclass(frozen=True)
class Capture:
    path: Path
    text: str
    plain: str
    lines: list[str]


def cell_width(ch: str) -> int:
    if unicodedata.combining(ch):
        return 0
    if unicodedata.category(ch) in {"Cc", "Cf"}:
        return 0
    if unicodedata.east_asian_width(ch) in {"F", "W"}:
        return 2
    return 1


def display_width(text: str) -> int:
    return sum(cell_width(ch) for ch in text)


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def load_capture(raw: str, label: str) -> Capture:
    if not raw:
        raise ValueError(f"missing {label} path")
    path = Path(raw)
    if not path.is_file():
        raise ValueError(f"{label} capture does not exist: {path}")
    text = path.read_text(encoding="utf-8")
    plain = strip_ansi(text)
    lines = plain.splitlines()
    if not lines:
        raise ValueError(f"{label} capture is empty: {path}")
    if len(lines) < 8:
        raise ValueError(f"{label} capture is truncated: {path} has {len(lines)} lines")
    return Capture(path=path, text=text, plain=plain, lines=lines)


def infer_width(capture: Capture) -> int:
    for line in capture.lines:
        stripped = line.rstrip("\n")
        if stripped.startswith(("╭", "┌")):
            return display_width(stripped)
    return max(display_width(line) for line in capture.lines)


def assert_tokens(capture: Capture, tokens: tuple[str, ...], label: str) -> list[str]:
    return [f"{capture.path}: missing {label} token: {token}" for token in tokens if token not in capture.plain]


def border_issues(capture: Capture, expected: int, strict_outer: bool) -> list[str]:
    issues: list[str] = []
    saw_top = False
    saw_bottom = False
    for idx, line in enumerate(capture.lines, start=1):
        if not line:
            issues.append(f"{capture.path}:{idx}: blank/truncated line inside capture")
            continue
        width = display_width(line)
        if width > expected:
            issues.append(f"{capture.path}:{idx}: line width {width} exceeds expected {expected}")
        first = line[0]
        last = line[-1]
        if strict_outer and (first in BORDER_LEFT or last in BORDER_RIGHT):
            if width != expected:
                issues.append(f"{capture.path}:{idx}: border row width {width} differs from expected {expected}")
            if first not in BORDER_LEFT:
                issues.append(f"{capture.path}:{idx}: missing left border")
            if last not in BORDER_RIGHT:
                issues.append(f"{capture.path}:{idx}: missing right border")
        if line.startswith(("╭", "┌")):
            saw_top = True
        if line.startswith(("╰", "└")):
            saw_bottom = True
    if strict_outer and not saw_top:
        issues.append(f"{capture.path}: missing top border")
    if strict_outer and not saw_bottom:
        issues.append(f"{capture.path}: missing bottom border")
    return issues


def main() -> int:
    ref = load_capture(sys.argv[1], "reference")
    act = load_capture(sys.argv[2], "actual")
    ansi_path = sys.argv[3]
    width_arg = sys.argv[4]
    expected = int(width_arg) if width_arg else infer_width(act)
    ref_width = infer_width(ref)
    if ref_width != expected:
        return fail([f"{ref.path}: reference width {ref_width} does not match actual/cols {expected}"])

    issues: list[str] = []
    issues.extend(border_issues(ref, expected, False))
    issues.extend(border_issues(act, expected, True))
    issues.extend(assert_tokens(ref, REFERENCE_FAMILY_TOKENS, "simulator-family"))
    issues.extend(assert_tokens(act, ACTUAL_FAMILY_TOKENS, "simulator-family"))
    issues.extend(assert_tokens(act, ROOT_REQUIRED_TOKENS, "operator"))
    for token in FORBIDDEN_ROOT_TOKENS:
        if token.lower() in act.plain.lower():
            issues.append(f"{act.path}: forbidden simulator/root claim token present: {token}")
    if ansi_path:
        ansi = load_capture(ansi_path, "ansi")
        if not ANSI_RE.search(ansi.text):
            issues.append(f"{ansi.path}: missing ANSI escape/style capture; use tmux capture-pane -e -p")
        issues.extend(assert_tokens(ansi, ACTUAL_FAMILY_TOKENS, "ansi simulator-family"))
        issues.extend(assert_tokens(ansi, ROOT_REQUIRED_TOKENS, "ansi operator"))
    if issues:
        return fail(issues)
    print(f"PASS: visual QA harness validated reference={ref.path} actual={act.path} cols={expected} ansi={'yes' if ansi_path else 'not-required'}")
    return 0


def fail(issues: list[str]) -> int:
    for issue in issues:
        print(issue, file=sys.stderr)
    return 1

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(exc, file=sys.stderr)
        raise SystemExit(1)
PY
}

if [[ $self_test -eq 1 ]]; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/tui-visual-check.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  good_ref="$tmp/ref.txt"
  good_actual="$tmp/actual.txt"
  good_ansi="$tmp/actual-ansi.txt"
  bad_short="$tmp/short.txt"
  bad_overflow="$tmp/overflow.txt"
  bad_no_ansi="$tmp/no-ansi.txt"
  missing_ref="$tmp/missing-ref.txt"
  missing_actual="$tmp/missing-actual.txt"
  missing_ansi="$tmp/missing-ansi.txt"
  python3 - "$good_ref" "$good_actual" <<'PYFIX'
from pathlib import Path
import sys
WIDTH = 120

def top(): return "╭" + "─" * (WIDTH - 2) + "╮"
def mid(): return "├" + "─" * (WIDTH - 2) + "┤"
def bot(): return "╰" + "─" * (WIDTH - 2) + "╯"
def row(left, middle, right):
    cells = [(left, 34), (middle, 24), (right, WIDTH - 68)]
    body = "│ "
    body += cells[0][0][:cells[0][1]].ljust(cells[0][1])
    body += " │ "
    body += cells[1][0][:cells[1][1]].ljust(cells[1][1])
    body += " │ "
    body += cells[2][0][:cells[2][1]].ljust(cells[2][1])
    body += " │"
    return body
ref = "\n".join([
    top(),
    row("▚ zig-scheduler", "simulator family", "NORMAL ↵"),
    mid(),
    row("dashboard ┌", "reference", "dense pane"),
    row("lifecycle", "events", "counters"),
    row("border grammar └", "aligned", "visual tokens"),
    mid(),
    row("footer", "? help h home w theme", "FAIL-CLOSED"),
    bot(),
]) + "\n"
actual = "\n".join([
    top(),
    row("▚ zig-scheduler", "live microVM lab", "NORMAL ↵"),
    mid(),
    row("lifecycle lanes", "runtime samples", "cleanup"),
    row("rollback", "zigsched_minimal", "host fail-closed"),
    row("VM-only attach path", "evidence", "FAIL-CLOSED"),
    mid(),
    row("footer", "? help h home w theme", "FAIL-CLOSED"),
    bot(),
]) + "\n"
Path(sys.argv[1]).write_text(ref, encoding="utf-8")
Path(sys.argv[2]).write_text(actual, encoding="utf-8")
PYFIX
  printf '\033[36m%s\033[0m\n' "$(cat "$good_actual")" > "$good_ansi"
  printf '╭bad╮\n' > "$bad_short"
  { cat "$good_actual"; printf 'this line intentionally overflows cols xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'; } > "$bad_overflow"
  cp "$good_actual" "$bad_no_ansi"

  expect_clean_failure() {
    local label=$1
    shift
    local out="$tmp/${label}.out"
    if "$@" >"$out" 2>&1; then
      echo "self-test failed: $label accepted" >&2
      cat "$out" >&2
      exit 1
    fi
    if grep -E "Traceback|File \"|raise SystemExit" "$out" >/dev/null; then
      echo "self-test failed: $label emitted traceback" >&2
      cat "$out" >&2
      exit 1
    fi
  }

  expect_clean_failure truncated run_validator "$good_ref" "$bad_short" "" "120"
  expect_clean_failure overflow run_validator "$good_ref" "$bad_overflow" "" "120"
  expect_clean_failure no_ansi run_validator "$good_ref" "$good_actual" "$bad_no_ansi" "120"
  expect_clean_failure missing_reference run_validator "$missing_ref" "$good_actual" "" "120"
  expect_clean_failure missing_actual run_validator "$good_ref" "$missing_actual" "" "120"
  expect_clean_failure missing_ansi run_validator "$good_ref" "$good_actual" "$missing_ansi" "120"
  run_validator "$good_ref" "$good_actual" "$good_ansi" "120" >/dev/null
  echo "PASS: tui_visual_check self-test rejected malformed/truncated/overflow/no-ANSI/missing-path captures and accepted good fixtures"
  exit 0
fi

if [[ -z "$reference" || -z "$actual" ]]; then
  usage
  exit 2
fi
validate_cli_inputs
if [[ -n "$cols" && ! "$cols" =~ ^[0-9]+$ ]]; then
  echo "--cols must be numeric" >&2
  exit 2
fi
if [[ -z "$cols" ]]; then
  cols=$(python3 - "$actual" <<'PY'
from pathlib import Path
import re, sys, unicodedata
ansi=re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
def w(s):
    total=0
    for ch in s:
        if unicodedata.combining(ch) or unicodedata.category(ch) in {"Cc","Cf"}: continue
        total += 2 if unicodedata.east_asian_width(ch) in {"F","W"} else 1
    return total
for line in ansi.sub("", Path(sys.argv[1]).read_text(encoding="utf-8")).splitlines():
    if line.startswith(("╭","┌")):
        print(w(line)); raise SystemExit(0)
raise SystemExit(1)
PY
)
fi
run_validator "$reference" "$actual" "$ansi" "$cols"
run_tui_check "$reference" "$cols"
run_tui_check "$actual" "$cols"
if [[ -n "$ansi" ]]; then
  run_tui_check "$ansi" "$cols"
fi
