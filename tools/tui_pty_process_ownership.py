"""PTY scenario proving TUI-owned daemon PGID cleanup leaves siblings alone."""

from __future__ import annotations

import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import time

from tui_pty_io import read_available, strip_ansi


def run_process_ownership(binary: str, daemon_binary: str, evidence: str) -> int:
    _ = daemon_binary
    if not Path(binary).exists():
        print(f"FAIL: missing TUI binary: {binary}", file=sys.stderr)
        return 1

    evidence_path = Path(evidence)
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    state_dir = evidence_path.parent / "task-6A-process-ownership-state"
    subprocess.run(["rm", "-rf", str(state_dir)], check=False)  # noqa: S603
    state_dir.mkdir(parents=True, exist_ok=True)

    sibling = subprocess.Popen(["sleep", "60"])  # noqa: S603
    sibling_alive_after = False
    owned_child_gone = False
    daemon_gone = False
    term_marker_seen = False
    rc = 1
    transcript = ""
    info_text = ""
    with tempfile.TemporaryDirectory(prefix="zigsched-process-owner.") as tmp:
        tmp_path = Path(tmp)
        info_path = tmp_path / "owned-info.txt"
        term_marker = tmp_path / "term-received.txt"
        shim = tmp_path / "owned-daemon.py"
        shim.write_text(process_owner_daemon_script(info_path, term_marker), encoding="utf-8")
        shim.chmod(0o755)
        rc, transcript = run_owned_tui_session(binary, str(shim), str(state_dir), info_path)
        info_text = read_text(info_path)
        term_marker_seen = term_marker.exists()
        daemon_pid = pid_from_info(info_text, "daemon_pid")
        owned_child_pid = pid_from_info(info_text, "owned_child_pid")
        if daemon_pid is not None:
            daemon_gone = wait_until_not_running(daemon_pid, deadline_s=3.0)
        if owned_child_pid is not None:
            owned_child_gone = wait_until_not_running(owned_child_pid, deadline_s=3.0)
        sibling_alive_after = is_running(sibling.pid)

    sibling_cleanup = "already-dead"
    if is_running(sibling.pid):
        sibling.terminate()
        try:
            sibling.wait(timeout=2)
            sibling_cleanup = "terminated"
        except subprocess.TimeoutExpired:
            sibling.kill()
            sibling.wait(timeout=2)
            sibling_cleanup = "killed"

    stripped = strip_ansi(transcript)
    evidence_text = "\n".join(
        (
            "scenario=process-ownership",
            f"tui_rc={rc}",
            f"state_dir={state_dir}",
            f"daemon_started={bool(info_text)}",
            f"term_marker_seen={term_marker_seen}",
            f"daemon_gone_after_cleanup={daemon_gone}",
            f"owned_child_gone_after_cleanup={owned_child_gone}",
            f"sibling_pid={sibling.pid}",
            f"sibling_alive_after_cleanup={sibling_alive_after}",
            f"sibling_cleanup={sibling_cleanup}",
            "--- owned-info ---",
            info_text,
            "--- transcript ---",
            stripped,
        )
    )
    evidence_path.write_text(evidence_text, encoding="utf-8")
    subprocess.run(["rm", "-rf", str(state_dir)], check=False)  # noqa: S603

    if rc != 0 or not info_text or not term_marker_seen or not daemon_gone or not owned_child_gone or not sibling_alive_after:
        print(f"FAIL: process ownership scenario evidence={evidence}", file=sys.stderr)
        print(evidence_text, file=sys.stderr)
        return 1
    print(f"PASS: process ownership cleanup killed owned PGID and preserved sibling evidence={evidence}")
    return 0


def process_owner_daemon_script(info_path: Path, term_marker: Path) -> str:
    return f'''#!/usr/bin/env python3
from __future__ import annotations
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

info_path = Path({str(info_path)!r})
term_marker = Path({str(term_marker)!r})

def on_term(signum, frame):
    fd = os.open(term_marker, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.write(fd, b"SIGTERM received by daemon\\n")
    finally:
        os.close(fd)

signal.signal(signal.SIGTERM, on_term)
args = sys.argv[1:]
state_dir = Path(".")
for index, arg in enumerate(args):
    if arg == "--state-dir" and index + 1 < len(args):
        state_dir = Path(args[index + 1])
state_dir.mkdir(parents=True, exist_ok=True)
journal = state_dir / "events.jsonl"
_ = sys.stdin.read()
owned_child = subprocess.Popen(["sleep", "60"])
daemon_pid = os.getpid()
daemon_pgid = os.getpgid(0)
daemon_sid = os.getsid(0)
owned_child_pgid = os.getpgid(owned_child.pid)
info_path.write_text(
    f"daemon_pid={{daemon_pid}}\\n"
    f"daemon_pgid={{daemon_pgid}}\\n"
    f"daemon_sid={{daemon_sid}}\\n"
    f"owned_child_pid={{owned_child.pid}}\\n"
    f"owned_child_pgid={{owned_child_pgid}}\\n",
    encoding="utf-8",
)
event = {{"schema":"zig-scheduler/daemon-event/v1","seq":1,"event":"state_changed","state":"queued","status":"queued","message":"[queued] VM run queued","host_mutation":False}}
line = json.dumps(event, separators=(",", ":"))
journal.write_text(line + "\\n", encoding="utf-8")
print(line, flush=True)
while True:
    time.sleep(1)
'''


def run_owned_tui_session(binary: str, daemon_binary: str, state_dir: str, info_path: Path) -> tuple[int, str]:
    master_fd, slave_fd = pty.openpty()
    os.set_blocking(master_fd, False)
    proc: subprocess.Popen[bytes] | None = None
    output = ""
    sent_quit = False
    deadline = time.monotonic() + 12.0
    try:
        proc = subprocess.Popen(  # noqa: S603
            [
                binary,
                "--interactive",
                "--test-mode",
                "--screen",
                "vm-lab",
                "--width",
                "100",
                "--height",
                "30",
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
        time.sleep(0.25)
        output += read_available(master_fd)
        os.write(master_fd, b"\rm")
        while time.monotonic() < deadline:
            time.sleep(0.05)
            output += read_available(master_fd)
            if info_path.exists() and not sent_quit:
                os.write(master_fd, b"q")
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


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""


def pid_from_info(text: str, key: str) -> int | None:
    prefix = key + "="
    for line in text.splitlines():
        if line.startswith(prefix):
            try:
                return int(line.removeprefix(prefix))
            except ValueError:
                return None
    return None


def is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    state = proc_state(pid)
    return state is None or state != "Z"


def proc_state(pid: int) -> str | None:
    try:
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    parts = stat.split()
    if len(parts) < 3:
        return None
    return parts[2]


def wait_until_not_running(pid: int, deadline_s: float) -> bool:
    deadline = time.monotonic() + deadline_s
    while time.monotonic() < deadline:
        if not is_running(pid):
            return True
        time.sleep(0.05)
    return not is_running(pid)
