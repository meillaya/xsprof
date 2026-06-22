#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 tools/tui_pty_exit_test.py --scenario duplicate-stale-live-controls --evidence .omo/evidence/task-7-authoritative-tui-live-vm-redesign-refusals.txt zig-out/bin/zig-scheduler-tui zig-out/bin/zig-scheduler-daemon
"""Active live-control PTY scenario for Todo 7 TUI evidence."""

from __future__ import annotations

import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import time

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.tui_pty_io import read_available, strip_ansi
from tools.tui_pty_live_control_expectations import (
    HELP_CLOSE_SETTLE_SECONDS,
    ROLLBACK_SESSION_MARKERS,
    STOP_SESSION_MARKERS,
    Marker,
    has_all_markers,
    missing_marker_ids,
)



def collect_for(fd: int, seconds: float) -> str:
    output = ""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        time.sleep(0.05)
        output += read_available(fd)
    return output


def run_duplicate_stale_live_controls(binary: str, daemon_binary: str, evidence: str) -> int:
    _ = daemon_binary
    if not Path(binary).exists():
        print(f"FAIL: missing TUI binary: {binary}", file=sys.stderr)
        return 1

    evidence_path = Path(evidence)
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zigsched-live-controls.") as tmp:
        shim = Path(tmp) / "live-controls-daemon.py"
        _ = shim.write_text(live_controls_daemon_script(), encoding="utf-8")
        _ = shim.chmod(0o755)
        stop_state = evidence_path.parent / "task-7-live-controls-stop-state"
        rollback_state = evidence_path.parent / "task-7-live-controls-rollback-state"
        stop_rc, stop_transcript = run_control_session(binary, str(shim), str(stop_state), b"s??jkss", STOP_SESSION_MARKERS)
        rollback_rc, rollback_transcript = run_control_session(binary, str(shim), str(rollback_state), b"bbbbs", ROLLBACK_SESSION_MARKERS)

    stripped_stop = strip_ansi(stop_transcript)
    stripped_rollback = strip_ansi(rollback_transcript)
    combined = "\n=== stop/help/scrub session ===\n" + stripped_stop + "\n=== rollback/duplicate/stale session ===\n" + stripped_rollback
    missing = missing_marker_ids(combined)
    _ = evidence_path.write_text(
        "\n".join(
            (
                "scenario=duplicate-stale-live-controls",
                f"stop_rc={stop_rc}",
                f"rollback_rc={rollback_rc}",
                f"missing={missing}",
                "--- transcript ---",
                combined,
            )
        ),
        encoding="utf-8",
    )
    if stop_rc != 0 or rollback_rc != 0 or missing:
        print(f"FAIL: duplicate/stale live controls evidence={evidence}", file=sys.stderr)
        if missing:
            print("missing: " + ", ".join(missing), file=sys.stderr)
        return 1
    print(f"PASS: duplicate/stale live controls evidence={evidence}")
    return 0


def live_controls_daemon_script() -> str:
    return r'''#!/usr/bin/env python3
from __future__ import annotations
import json, sys, time
from pathlib import Path
from typing import TypedDict

class DaemonEvent(TypedDict, total=False):
    schema: str; action: str; action_id: str; target_action_id: str
    rollback_id: str; host_mutation: bool; seq: int; event: str
    status: str; reason: str; artifact: str; sample_sequence: int

def read_action(payload: str) -> DaemonEvent:
    if not payload:
        return {}
    try:
        raw = json.loads(payload)
    except json.JSONDecodeError:
        return {}
    return raw if isinstance(raw, dict) else {}

def action_text(action: DaemonEvent, key: str, fallback: str) -> str:
    value = action.get(key, fallback)
    return value if isinstance(value, str) else fallback

payload = sys.stdin.read().strip(); action = read_action(payload)
state_dir = Path("."); args = sys.argv[1:]; follow = "--follow" in args
for i, arg in enumerate(args):
    if arg == "--state-dir" and i + 1 < len(args):
        state_dir = Path(args[i + 1])
state_dir.mkdir(parents=True, exist_ok=True); journal = state_dir / "events.jsonl"

def emit(event: DaemonEvent, delay: float = 0.05) -> None:
    line = json.dumps(event, separators=(",", ":"))
    with journal.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")
    print(line, flush=True)
    time.sleep(delay)

if follow:
    base = {
        "schema": "zig-scheduler/daemon-event/v1",
        "action": "run_lab_microvm_live",
        "action_id": "tui-vm-lab",
        "host_mutation": False,
    }
    emit({**base, "seq": 1, "event": "stage_started", "status": "queued", "reason": "microvm_live_runner_start", "artifact": "evidence/lab/run-all/tui-vm-lab"}, 0.08)
    emit({**base, "seq": 2, "event": "runtime_sample", "status": "PASS", "reason": "runtime samples accepted", "sample_sequence": 1}, 0.08)
    emit({**base, "seq": 3, "event": "lab_run_active", "status": "active", "rollback_id": "RB-tui-vm-lab", "artifact": "evidence/lab/run-all/tui-vm-lab"}, 1.8)
    emit({**base, "seq": 4, "event": "runtime_sample", "status": "PASS", "reason": "runtime samples accepted", "sample_sequence": 2}, 12.0)
else:
    kind = action_text(action, "action", "")
    action_id = action_text(action, "action_id", "tui-active-control")
    base = {
        "schema": "zig-scheduler/daemon-event/v1",
        "action": kind,
        "action_id": action_id,
        "target_action_id": action_text(action, "target_action_id", "tui-vm-lab"),
        "rollback_id": action_text(action, "rollback_id", "RB-tui-vm-lab"),
        "host_mutation": False,
    }
    if kind == "rollback_lab_run":
        emit({**base, "seq": 20, "event": "rollback", "status": "queued", "reason": "operator rollback queued"}, 0.02)
        emit({**base, "seq": 21, "event": "rollback", "status": "active", "reason": "rollback drill active"}, 0.02)
        emit({**base, "seq": 22, "event": "rollback_completed", "status": "PASS", "reason": "rollback drill completed"}, 0.02)
    elif kind == "stop_lab_run":
        emit({**base, "seq": 30, "event": "cleanup", "status": "active", "reason": "operator stop requested"}, 0.02)
    else:
        emit({**base, "seq": 40, "event": "refusal", "status": "refused", "reason": "stale_or_unknown_target_action_id"}, 0.02)
'''


def run_control_session(
    binary: str,
    daemon_binary: str,
    state_dir: str,
    active_keys: bytes,
    expected_markers: tuple[Marker, ...],
) -> tuple[int, str]:
    _ = subprocess.run(["rm", "-rf", state_dir], check=False)  # noqa: S603
    Path(state_dir).mkdir(parents=True, exist_ok=True)
    master_fd, slave_fd = pty.openpty()
    os.set_blocking(master_fd, False)
    proc: subprocess.Popen[bytes] | None = None
    output = ""
    sent_active = False
    sent_quit = False
    deadline = time.monotonic() + 45.0
    try:
        proc = subprocess.Popen(  # noqa: S603
            [
                binary,
                "--interactive",
                "--test-mode",
                "--screen",
                "vm-lab",
                "--width",
                "197",
                "--height",
                "62",
                "--daemon-state-dir",
                state_dir,
                "--daemon-bin",
                daemon_binary,
            ],
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
        )
        os.close(slave_fd)
        slave_fd = -1
        time.sleep(0.2)
        output += read_available(master_fd)
        _ = os.write(master_fd, b"\rm")
        previous_key = -1
        while time.monotonic() < deadline:
            time.sleep(0.05)
            output += read_available(master_fd)
            plain = strip_ansi(output)
            incident_pos = max(plain.rfind("INCIDENT   cursor"), plain.rfind("INCIDENT     q quit"))
            target_ready = plain.rfind("[rollback ready] rollback target ready") > incident_pos and plain.rfind("rollback id         RB-tui-vm-lab") > incident_pos
            if target_ready and not sent_active:
                output += collect_for(master_fd, 0.5)
                for key in active_keys:
                    _ = os.write(master_fd, bytes((key,)))
                    settle_seconds = 0.75
                    if key == ord("?") and previous_key == ord("?"):
                        settle_seconds = HELP_CLOSE_SETTLE_SECONDS
                    output += collect_for(master_fd, settle_seconds)
                    previous_key = key
                sent_active = True
            plain = strip_ansi(output)
            if sent_active and not sent_quit and has_all_markers(plain, expected_markers):
                _ = os.write(master_fd, b"q")
                sent_quit = True
            if sent_quit and proc.poll() is not None:
                break
        if proc.poll() is None:
            proc.kill()
            return 1, output + read_available(master_fd)
        rc = proc.wait(timeout=2)
        time.sleep(0.1)
        output += read_available(master_fd)
        return rc, output
    except subprocess.TimeoutExpired:
        if proc is not None:
            proc.kill()
        return 1, output
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)
        _ = subprocess.run(["rm", "-rf", state_dir], check=False)  # noqa: S603
