"""Basic root TUI PTY smoke scenarios used by tui_pty_exit_test."""

from __future__ import annotations

import os
import pty
import subprocess
import sys
import time
from typing import Final

from tui_pty_io import read_available

SNAPSHOT_ARGS: Final[tuple[str, ...]] = (
    "--snapshot",
    "--screen",
    "preflight",
    "--width",
    "100",
    "--height",
    "30",
)
INTERACTIVE_ARGS: Final[tuple[str, ...]] = (
    "--interactive",
    "--test-mode",
    "--screen",
    "preflight",
    "--width",
    "100",
    "--height",
    "30",
)


def run_snapshot(binary: str) -> int:
    master_fd, slave_fd = pty.openpty()
    try:
        completed = subprocess.run(  # noqa: S603
            [binary, *SNAPSHOT_ARGS],
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            check=False,
            timeout=10,
        )
        os.close(slave_fd)
        slave_fd = -1
        output = os.read(master_fd, 20000).decode("utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        print("FAIL: TUI snapshot timed out under PTY", file=sys.stderr)
        return 1
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)

    if completed.returncode != 0:
        print(f"FAIL: TUI exited {completed.returncode}", file=sys.stderr)
        return 1
    if "▚ zig-scheduler" not in output or "SNAPSHOT" not in output:
        print("FAIL: TUI PTY output missing operator snapshot markers", file=sys.stderr)
        return 1
    print("PASS: root TUI PTY snapshot exited cleanly")
    return 0


def run_interactive_keys(binary: str, keys: bytes) -> tuple[int, str]:
    master_fd, slave_fd = pty.openpty()
    os.set_blocking(master_fd, False)
    proc: subprocess.Popen[bytes] | None = None
    completed_rc = -1
    output = ""
    try:
        proc = subprocess.Popen(  # noqa: S603
            [binary, *INTERACTIVE_ARGS],
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
        )
        os.close(slave_fd)
        slave_fd = -1
        time.sleep(0.2)
        output += read_available(master_fd)
        for key in keys:
            os.write(master_fd, bytes((key,)))
            time.sleep(0.25)
            output += read_available(master_fd)
        completed_rc = proc.wait(timeout=10)
        time.sleep(0.1)
        output += read_available(master_fd)
    except subprocess.TimeoutExpired:
        if proc is not None:
            proc.kill()
        print("FAIL: TUI interactive timed out under PTY", file=sys.stderr)
        return 1, ""
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)
    return completed_rc, output


def run_interactive(binary: str) -> int:
    completed_rc, output = run_interactive_keys(binary, b"rq")
    if completed_rc != 0:
        print(f"FAIL: interactive TUI exited {completed_rc}", file=sys.stderr)
        print(output, file=sys.stderr)
        return 1
    if "ACTION queued run_lab_host_safe" not in output or "FAIL-CLOSED" not in output:
        print("FAIL: interactive TUI output missing queued action markers", file=sys.stderr)
        print(output, file=sys.stderr)
        return 1
    print("PASS: root TUI PTY interactive action queued cleanly")
    return 0


def run_tui_daemon_sequence(binary: str, daemon_binary: str, state_dir: str, keys: bytes) -> tuple[int, str, str]:
    subprocess.run(["rm", "-rf", state_dir], check=False)  # noqa: S603
    master_fd, slave_fd = pty.openpty()
    os.set_blocking(master_fd, False)
    proc: subprocess.Popen[bytes] | None = None
    completed_rc = -1
    output = ""
    try:
        proc = subprocess.Popen(  # noqa: S603
            [
                binary,
                *INTERACTIVE_ARGS,
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
        for key in keys:
            os.write(master_fd, bytes((key,)))
            time.sleep(0.25)
            output += read_available(master_fd)
        completed_rc = proc.wait(timeout=30)
        time.sleep(0.1)
        output += read_available(master_fd)
    except subprocess.TimeoutExpired:
        if proc is not None:
            proc.kill()
        print("FAIL: daemon TUI interactive timed out under PTY", file=sys.stderr)
        return 1, "", ""
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)

    journal_path = f"{state_dir}/events.jsonl"
    try:
        with open(journal_path, encoding="utf-8") as journal_file:
            journal = journal_file.read()
    except FileNotFoundError:
        journal = ""
    finally:
        subprocess.run(["rm", "-rf", state_dir], check=False)  # noqa: S603
    return completed_rc, output, journal


def run_interactive_daemon(binary: str, daemon_binary: str) -> int:
    completed_rc, output, journal = run_tui_daemon_sequence(
        binary,
        daemon_binary,
        ".omo/evidence/tui-pty-daemon-test",
        b"vq",
    )
    if completed_rc != 0:
        print(f"FAIL: daemon interactive TUI exited {completed_rc}", file=sys.stderr)
        print(output, file=sys.stderr)
        return 1
    if journal == "":
        print(output, file=sys.stderr)
        return 1
    if "verifier queued/refused host-safe" not in output:
        print("FAIL: TUI output missing verifier daemon refusal status", file=sys.stderr)
        print(output, file=sys.stderr)
        return 1
    if '"action":"verifier_only"' not in journal or "host_mutation_refused" not in journal:
        print("FAIL: daemon journal missing verifier_only refusal", file=sys.stderr)
        return 1
    print("PASS: root TUI PTY dispatched verifier action through daemon")
    return 0


def run_rollback_stop_matrix(binary: str, daemon_binary: str) -> int:
    _ = daemon_binary
    rollback_rc, rollback_output = run_interactive_keys(binary, b"\rmbbq")
    if rollback_rc != 0 or "CONFIRM rollback — press b again" not in rollback_output or "ACTION queued rollback" not in rollback_output:
        print("FAIL: TUI rollback control matrix missing confirmation or dispatch", file=sys.stderr)
        return 1

    stop_rc, stop_output = run_interactive_keys(binary, b"\rmssq")
    if stop_rc != 0 or "CONFIRM stop — press s again" not in stop_output or "ACTION queued stop" not in stop_output:
        print("FAIL: TUI stop control matrix missing confirmation or dispatch", file=sys.stderr)
        return 1

    print("PASS: root TUI PTY rollback/stop key matrix completed")
    return 0
