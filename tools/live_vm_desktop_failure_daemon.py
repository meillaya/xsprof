#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# ///
# ─── How to run ───
# python3 tools/live_vm_desktop_failure_daemon.py --foreground --state-dir .omo/evidence/task-08-failure-matrix/qemu_unavailable/state
from __future__ import annotations

import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from live_vm_json_helpers import JsonObject, json_text_field

SCHEMA: Final[str] = "zig-scheduler/daemon-event/v1"


@dataclass(frozen=True, slots=True)
class Args:
    state_dir: Path


def parse_args(argv: list[str]) -> Args:
    state_dir = Path(".omo/evidence/task-08-failure-matrix/default/state")
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in {"--foreground", "--follow"}:
            index += 1
        elif arg == "--state-dir":
            if index + 1 >= len(argv):
                raise SystemExit("missing --state-dir value")
            state_dir = Path(argv[index + 1])
            index += 2
        else:
            index += 1
    return Args(state_dir=state_dir)


def case_from_state_dir(state_dir: Path) -> str:
    for part in reversed(state_dir.parts):
        if part and part != "state":
            return part
    return "qemu_unavailable"


@dataclass(frozen=True, slots=True)
class ActionPayload:
    action_id: str
    action: str
    target_action_id: str


def read_action_payload(raw: str) -> ActionPayload:
    payload: JsonObject = {}
    if raw.strip():
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError:
            payload = {}
        else:
            if isinstance(decoded, dict):
                for key in ("action_id", "action", "target_action_id"):
                    value = decoded.get(key)
                    if isinstance(value, str):
                        payload[key] = value
    return ActionPayload(
        action_id=json_text_field(payload, "action_id", "desktop-run-1"),
        action=json_text_field(payload, "action", "run_lab_microvm_live"),
        target_action_id=json_text_field(payload, "target_action_id", "desktop-run-1"),
    )


def event(seq: int, name: str, action_id: str, status: str, reason: str, **extra: str | bool | int) -> str:
    row: dict[str, str | bool | int] = {
        "schema": SCHEMA,
        "seq": seq,
        "event": name,
        "action": "run_lab_microvm_live",
        "action_id": action_id,
        "status": status,
        "reason": reason,
        "host_mutation": False,
    }
    row.update(extra)
    return json.dumps(row, sort_keys=True, separators=(",", ":"))


def emit(lines: list[str], state_dir: Path) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    text = "\n".join(lines) + "\n"
    _ = (state_dir / "events.jsonl").write_text(text, encoding="utf-8")
    _ = sys.stdout.write(text)
    _ = sys.stdout.flush()


def run_case(case: str, state_dir: Path, action_id: str, action: str, target_action_id: str) -> int:
    match case:  # noqa: MATCH_OK - unknown fixture names intentionally emit controller-visible evidence.
        case "qemu_unavailable":
            emit([
                event(1, "stage_started", action_id, "queued", "microvm_live_runner_start"),
                event(2, "stage_finished", action_id, "SKIP", "qemu_unavailable"),
            ], state_dir)
        case "verifier_reject":
            emit([
                event(1, "stage_started", action_id, "queued", "microvm_live_runner_start"),
                event(2, "verifier", action_id, "REFUSE", "verifier_reject"),
            ], state_dir)
        case "lost_stream":
            emit([event(1, "stage_started", action_id, "queued", "microvm_live_runner_start"), "{not-json"], state_dir)
        case "timeout":
            emit([event(1, "stage_started", action_id, "queued", "microvm_live_runner_start")], state_dir)
            time.sleep(30)
        case "rollback_failure":
            if action == "rollback_lab_run":
                emit([event(1, "incident", action_id, "incident", "rollback_failure", target_action_id=target_action_id)], state_dir)
            else:
                emit([
                    event(1, "stage_started", action_id, "queued", "microvm_live_runner_start"),
                    event(2, "runtime_sample", action_id, "PASS", "runtime samples accepted"),
                ], state_dir)
        case "cleanup_residue":
            emit([
                event(1, "stage_started", action_id, "queued", "microvm_live_runner_start"),
                event(2, "cleanup", action_id, "REFUSE", "cleanup_residue"),
            ], state_dir)
        case "duplicate_stale_ids":
            emit([
                event(1, "stage_started", "stale-desktop-run", "queued", "duplicate_or_stale_action_id"),
            ], state_dir)
        case "host_mutation_true":
            emit([
                event(1, "runtime_sample", action_id, "PASS", "host_mutation_injected", host_mutation=True),
            ], state_dir)
        case unreachable:
            emit([event(1, "incident", action_id, "refused", f"unknown_failure_fixture:{unreachable}")], state_dir)
    return 0


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    case = case_from_state_dir(args.state_dir)
    action = read_action_payload(sys.stdin.read())
    return run_case(case, args.state_dir, action.action_id, action.action, action.target_action_id)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
