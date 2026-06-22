"""Fake daemon script factory for authoritative TUI frame captures."""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from live_vm_json_helpers import JsonBoundaryError, JsonObject, json_text_field, parse_json_object_text


DEFAULT_FIXTURE = "fixtures/tui/daemon-delayed-live-events.jsonl"


def authoritative_daemon_script(fixture: str) -> str:
    return f'''#!/usr/bin/env python3
from __future__ import annotations
import json
import os
import sys
import time
from pathlib import Path
fixture = Path({fixture!r})
state_dir = Path(".")
args = sys.argv[1:]
follow = "--follow" in args
for index, arg in enumerate(args):
    if arg == "--state-dir" and index + 1 < len(args):
        state_dir = Path(args[index + 1])
state_dir.mkdir(parents=True, exist_ok=True)
journal = state_dir / "events.jsonl"
debug = state_dir / "authoritative-debug.log"
payload = sys.stdin.read().strip()
action = json.loads(payload) if payload else {{}}
kind = action.get("action", "") if isinstance(action, dict) else ""

def debug_line(message: str) -> None:
    with debug.open("a", encoding="utf-8") as handle:
        handle.write(f"pid={{os.getpid()}} follow={{follow}} kind={{kind}} {{message}}\\n")

def append_line(line: str) -> None:
    with journal.open("a", encoding="utf-8") as handle:
        handle.write(line + "\\n")
    print(line, flush=True)

def controller_text(key: str, fallback: str) -> str:
    value = action.get(key, fallback) if isinstance(action, dict) else fallback
    return value if isinstance(value, str) and value else fallback

def controller_event(line: str) -> str:
    event = json.loads(line)
    action_id = controller_text("action_id", "tui-vm-lab")
    rollback_id = controller_text("rollback_id", f"RB-{{action_id}}")
    event["action_id"] = action_id
    if event.get("target_action_id"):
        event["target_action_id"] = action_id
    if event.get("rollback_id"):
        event["rollback_id"] = rollback_id
    return json.dumps(event, separators=(",", ":"))

if follow:
    debug_line("start")
    for raw in fixture.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        event_line = controller_event(line)
        append_line(event_line)
        if json.loads(line).get("event") == "lab_run_active" and not controller_text("action_id", "").startswith("desktop-run-"):
            debug_line("sleep-active")
            time.sleep(60.0)
            break
        time.sleep(0.03)
elif kind == "run_lab_microvm_live":
    debug_line("start")
    for raw in fixture.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        event = json.loads(line)
        event_line = controller_event(line)
        append_line(event_line)
        if event.get("event") == "lab_run_active" and not controller_text("action_id", "").startswith("desktop-run-"):
            debug_line("sleep-active")
            time.sleep(60.0)
            break
        time.sleep(0.16)
elif kind in {"rollback_lab_run", "stop_lab_run"}:
    debug_line("start-control")
    base = {{
        "schema": "zig-scheduler/daemon-event/v1",
        "action": kind,
        "action_id": action.get("action_id", "tui-active-control") if isinstance(action, dict) else "tui-active-control",
        "target_action_id": action.get("target_action_id", "tui-vm-lab") if isinstance(action, dict) else "tui-vm-lab",
        "rollback_id": action.get("rollback_id", "RB-tui-vm-lab") if isinstance(action, dict) else "RB-tui-vm-lab",
        "artifact": "evidence/lab/run-all/tui-vm-lab-delayed/rollback-drill/audit-ledger.jsonl",
        "host_mutation": False,
    }}
    events = [
        {{**base, "seq": 101, "event": "rollback", "status": "active", "reason": "operator confirmed rollback"}},
        {{**base, "seq": 102, "event": "rollback_completed", "status": "PASS", "reason": "state restored"}},
        {{**base, "seq": 103, "event": "stage_finished", "action": "audit", "status": "PASS", "reason": "runtime samples linked to audit ledger"}},
        {{**base, "seq": 104, "event": "cleanup", "status": "active", "reason": "cleanup running"}},
        {{**base, "seq": 105, "event": "cleanup", "status": "PASS", "reason": "process scan clean"}},
        {{**base, "seq": 106, "event": "validation", "status": "PASS", "reason": "live bundle freshness accepted"}},
    ]
    for event in events:
        append_line(json.dumps(event, separators=(",", ":")))
        time.sleep(0.03)
else:
    event = {{"schema": "zig-scheduler/daemon-event/v1", "seq": 301, "event": "refusal", "action": kind, "status": "refused", "reason": "stale_or_unknown_target_action_id", "host_mutation": False}}
    append_line(json.dumps(event, separators=(",", ":")))
'''


def run_daemon(fixture: str = DEFAULT_FIXTURE) -> int:
    fixture_path = Path(fixture)
    state_dir = Path(".")
    args = sys.argv[1:]
    follow = "--follow" in args
    for index, arg in enumerate(args):
        if arg == "--state-dir" and index + 1 < len(args):
            state_dir = Path(args[index + 1])
    state_dir.mkdir(parents=True, exist_ok=True)
    journal = state_dir / "events.jsonl"
    debug = state_dir / "authoritative-debug.log"
    payload = sys.stdin.read().strip()

    def debug_line(message: str) -> None:
        with debug.open("a", encoding="utf-8") as handle:
            _ = handle.write(f"pid={os.getpid()} follow={follow} kind={kind} {message}\n")

    def append_line(line: str) -> None:
        with journal.open("a", encoding="utf-8") as handle:
            _ = handle.write(line + "\n")
        print(line, flush=True)

    def read_payload(raw_payload: str) -> JsonObject:
        if not raw_payload:
            return {}
        try:
            return parse_json_object_text(raw_payload, "stdin action")
        except JsonBoundaryError:
            return {}

    def action_text(source: JsonObject, key: str, fallback: str) -> str:
        return json_text_field(source, key, fallback)

    def controller_event(line: str) -> str:
        try:
            event = parse_json_object_text(line, fixture_path.as_posix())
        except JsonBoundaryError:
            return line
        action_id = action_text(action, "action_id", "tui-vm-lab")
        rollback_id = action_text(action, "rollback_id", f"RB-{action_id}")
        event["action_id"] = action_id
        if event.get("target_action_id"):
            event["target_action_id"] = action_id
        if event.get("rollback_id"):
            event["rollback_id"] = rollback_id
        return json.dumps(event, separators=(",", ":"))

    action = read_payload(payload)
    kind = action_text(action, "action", "")

    if follow or kind == "run_lab_microvm_live":
        debug_line("start")
        for raw in fixture_path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line:
                continue
            event_line = controller_event(line)
            append_line(event_line)
            if json.loads(line).get("event") == "lab_run_active" and not action_text(action, "action_id", "").startswith("desktop-run-"):
                debug_line("sleep-active")
                time.sleep(60.0)
                break
            time.sleep(0.03)
    elif kind in {"rollback_lab_run", "stop_lab_run"}:
        debug_line("start-control")
        base: JsonObject = {
            "schema": "zig-scheduler/daemon-event/v1",
            "action": kind,
            "action_id": action_text(action, "action_id", "desktop-active-control"),
            "target_action_id": action_text(action, "target_action_id", "desktop-run-1"),
            "rollback_id": action_text(action, "rollback_id", "RB-desktop-run-1"),
            "artifact": "evidence/lab/run-all/tui-vm-lab-delayed/rollback-drill/audit-ledger.jsonl",
            "host_mutation": False,
        }
        events: list[JsonObject] = [
            {**base, "seq": 101, "event": "rollback", "status": "active", "reason": "operator confirmed rollback"},
            {**base, "seq": 102, "event": "rollback_completed", "status": "PASS", "reason": "state restored"},
            {**base, "seq": 103, "event": "stage_finished", "action": "audit", "status": "PASS", "reason": "runtime samples linked to audit ledger"},
            {**base, "seq": 104, "event": "cleanup", "status": "active", "reason": "cleanup running"},
            {**base, "seq": 105, "event": "cleanup", "status": "PASS", "reason": "process scan clean"},
            {**base, "seq": 106, "event": "validation", "status": "PASS", "reason": "live bundle freshness accepted"},
        ]
        for event in events:
            append_line(json.dumps(event, separators=(",", ":")))
            time.sleep(0.03)
    else:
        event: JsonObject = {"schema": "zig-scheduler/daemon-event/v1", "seq": 301, "event": "refusal", "action": kind, "status": "refused", "reason": "stale_or_unknown_target_action_id", "host_mutation": False}
        append_line(json.dumps(event, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(run_daemon())
