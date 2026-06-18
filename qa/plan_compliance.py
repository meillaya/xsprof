#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/plan_compliance.py --plan .omo/plans/production-sched-ext-roadmap.md --evidence .omo/evidence --require-red-green --require-manual-qa --require-commit-footer "Plan: .omo/plans/production-sched-ext-roadmap.md"
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys
from typing import Final

TASK_RE: Final[re.Pattern[str]] = re.compile(r"^- \[(?P<mark>[ x])\] (?P<task>T\d{2})\.", re.MULTILINE)


@dataclass(frozen=True, slots=True)
class Args:
    plan: Path
    evidence: Path
    require_red_green: bool
    require_manual_qa: bool
    commit_footer: str | None


@dataclass(frozen=True, slots=True)
class TaskEvidence:
    task: str
    red: bool
    green: bool
    manual: bool
    completed: bool


def parse_args(argv: list[str]) -> Args:
    plan: Path | None = None
    evidence: Path | None = None
    require_red_green = False
    require_manual_qa = False
    commit_footer: str | None = None
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--plan" and index + 1 < len(argv):
            plan = Path(argv[index + 1])
            index += 2
        elif arg == "--evidence" and index + 1 < len(argv):
            evidence = Path(argv[index + 1])
            index += 2
        elif arg == "--require-red-green":
            require_red_green = True
            index += 1
        elif arg == "--require-manual-qa":
            require_manual_qa = True
            index += 1
        elif arg == "--require-commit-footer" and index + 1 < len(argv):
            commit_footer = argv[index + 1]
            index += 2
        else:
            raise SystemExit(f"unknown or incomplete argument: {arg}")
    if plan is None:
        raise SystemExit("--plan is required")
    if evidence is None:
        raise SystemExit("--evidence is required")
    return Args(plan, evidence, require_red_green, require_manual_qa, commit_footer)


def git_log_contains(needle: str) -> bool:
    result = subprocess.run(
        ["git", "log", "--format=%B", "--max-count=200"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0 and needle in result.stdout


def ledger_contains(task: str) -> bool:
    ledger = Path(".omo/start-work/ledger.jsonl")
    if not ledger.exists():
        return False
    needle_task = f'"task": "{task}"'
    needle_event = '"event": "task-completed"'
    return any(needle_task in line and needle_event in line for line in ledger.read_text().splitlines())


def has_glob(evidence: Path, task: str, suffix: str) -> bool:
    return any(evidence.glob(f"task-{task}-*{suffix}*"))


def task_evidence(evidence: Path, task: str) -> TaskEvidence:
    return TaskEvidence(
        task=task,
        red=has_glob(evidence, task, "red"),
        green=has_glob(evidence, task, "green"),
        manual=any(evidence.glob(f"task-{task}-*.tmux.txt")) or any(evidence.glob(f"task-{task}-*.vm.txt")),
        completed=ledger_contains(task),
    )


def task_number(task: str) -> int:
    return int(task.removeprefix("T"))


def task_name(number: int) -> str:
    return f"T{number:02d}"


def task_span(tasks: list[str]) -> str:
    if not tasks:
        return "no tasks"
    if len(tasks) == 1:
        return f"{tasks[0]} (1 task)"
    ordered = sorted(tasks, key=task_number)
    return f"{ordered[0]}-{ordered[-1]} ({len(tasks)} tasks)"


def missing_tasks_in_sequence(tasks: list[str]) -> list[str]:
    if not tasks:
        return []
    task_numbers = {task_number(task) for task in tasks}
    first = min(task_numbers)
    last = max(task_numbers)
    return [task_name(number) for number in range(first, last + 1) if number not in task_numbers]


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    plan_text = args.plan.read_text()
    matches = list(TASK_RE.finditer(plan_text))
    tasks = {match.group("task"): match.group("mark") for match in matches}
    expected = list(dict.fromkeys(match.group("task") for match in matches))
    failures: list[str] = []
    print(f"plan={args.plan}")
    print(f"evidence={args.evidence}")
    print(f"tasks={task_span(expected)}")
    if not expected:
        failures.append("plan contains no tasks matching TASK_RE")
    for missing_task in missing_tasks_in_sequence(expected):
        failures.append(f"missing task {missing_task} in plan sequence")
    for task in expected:
        mark = tasks.get(task)
        evidence = task_evidence(args.evidence, task)
        complete = mark == "x"
        checkbox = "complete" if complete else "open"
        print(
            " ".join(
                [
                    f"{task}: checkbox={checkbox}",
                    f"red={evidence.red}",
                    f"green={evidence.green}",
                    f"manual={evidence.manual}",
                    f"ledger={evidence.completed}",
                ]
            )
        )
        if not complete:
            failures.append(f"{task} checkbox is not complete")
        if args.require_red_green and not (evidence.red and evidence.green):
            failures.append(f"{task} missing red or green evidence")
        if args.require_manual_qa and not evidence.manual:
            failures.append(f"{task} missing manual QA evidence")
        if not evidence.completed:
            failures.append(f"{task} missing task-completed ledger entry")
    if args.commit_footer is not None:
        footer_path = args.evidence / "final-commit-footer.txt"
        footer_present = git_log_contains(args.commit_footer) or (
            footer_path.exists() and args.commit_footer in footer_path.read_text()
        )
        print(f"commit_footer_required={args.commit_footer}")
        print(f"commit_footer_present={footer_present}")
        if not footer_present:
            failures.append("required commit footer not found in git log or final-commit-footer evidence")
    if failures:
        print("FAIL: plan compliance")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print(f"PASS: plan compliance {task_span(expected)} complete with required evidence")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
