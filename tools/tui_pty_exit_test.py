#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 tools/tui_pty_exit_test.py zig-out/bin/zig-scheduler-tui
"""PTY smoke test for the root Linux scheduler TUI snapshot path."""

from __future__ import annotations

import errno
import os
import pty
import subprocess
import sys
import time
from typing import Final

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


def main() -> int:
    if len(sys.argv) not in {2, 3}:
        print("usage: tui_pty_exit_test.py <tui-binary> [daemon-binary]", file=sys.stderr)
        return 2

    binary = sys.argv[1]
    daemon_binary = sys.argv[2] if len(sys.argv) == 3 else "zig-out/bin/zig-scheduler-daemon"
    snapshot_rc = run_snapshot(binary)
    if snapshot_rc != 0:
        return snapshot_rc
    interactive_rc = run_interactive(binary)
    if interactive_rc != 0:
        return interactive_rc
    daemon_rc = run_interactive_daemon(binary, daemon_binary)
    if daemon_rc != 0:
        return daemon_rc
    matrix_rc = run_rollback_stop_matrix(binary, daemon_binary)
    if matrix_rc != 0:
        return matrix_rc
    return run_daemon_stale_duplicate_matrix(daemon_binary)


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
    subprocess.run(["rm", "-rf", state_dir], check=False)
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
        subprocess.run(["rm", "-rf", state_dir], check=False)
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
    rollback_rc, rollback_output = run_interactive_keys(binary, b"mbbq")
    if rollback_rc != 0 or "CONFIRM rollback press b again" not in rollback_output or "ACTION queued rollback" not in rollback_output:
        print("FAIL: TUI rollback control matrix missing confirmation or dispatch", file=sys.stderr)
        return 1

    stop_rc, stop_output = run_interactive_keys(binary, b"mssq")
    if stop_rc != 0 or "CONFIRM stop press s again" not in stop_output or "ACTION queued stop" not in stop_output:
        print("FAIL: TUI stop control matrix missing confirmation or dispatch", file=sys.stderr)
        return 1

    print("PASS: root TUI PTY rollback/stop key matrix completed")
    return 0


def run_daemon_stale_duplicate_matrix(daemon_binary: str) -> int:
    state_dir = ".omo/evidence/tui-pty-stale-duplicate-test"
    subprocess.run(["rm", "-rf", state_dir], check=False)
    duplicate_payload = (
        '{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"dup"}\n'
        '{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"dup"}\n'
        '{"schema":"zig-scheduler/operator-action/v1","action":"rollback_lab_run","run_id":"stale",'
        '"target_action_id":"missing","rollback_id":"RB-missing"}\n'
    )
    completed = subprocess.run(  # noqa: S603
        [daemon_binary, "--foreground", "--state-dir", state_dir],
        input=duplicate_payload,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=10,
    )
    subprocess.run(["rm", "-rf", state_dir], check=False)
    output = completed.stdout + completed.stderr
    if completed.returncode != 0:
        return 1
    if "duplicate_action_id" not in output or "stale_or_unknown_target_action_id" not in output:
        return 1
    print("PASS: daemon stale/duplicate rollback matrix refused safely")
    return 0


def read_available(fd: int) -> str:
    chunks: list[bytes] = []
    while True:
        try:
            chunk = os.read(fd, 8192)
        except BlockingIOError:
            break
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks).decode("utf-8", errors="replace")



if __name__ == "__main__":
    raise SystemExit(main())
