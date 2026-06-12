#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 tools/tui_pty_exit_test.py zig-out/bin/zig-scheduler-tui
"""PTY smoke test for the root Linux scheduler TUI snapshot path."""

from __future__ import annotations

import os
import pty
import subprocess
import sys
import time
import errno
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
    if len(sys.argv) != 2:
        print("usage: tui_pty_exit_test.py <tui-binary>", file=sys.stderr)
        return 2

    binary = sys.argv[1]
    snapshot_rc = run_snapshot(binary)
    if snapshot_rc != 0:
        return snapshot_rc
    return run_interactive(binary)


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
        print(output, file=sys.stderr)
        return 1
    if "Linux Scheduler Operator" not in output or "SNAPSHOT" not in output:
        print("FAIL: TUI PTY output missing operator snapshot markers", file=sys.stderr)
        print(output, file=sys.stderr)
        return 1
    print("PASS: root TUI PTY snapshot exited cleanly")
    return 0


def run_interactive(binary: str) -> int:
    master_fd, slave_fd = pty.openpty()
    proc: subprocess.Popen[bytes] | None = None
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
        os.write(master_fd, b"rq")
        completed_rc = proc.wait(timeout=10)
        time.sleep(0.1)
        output = read_all(master_fd)
    except subprocess.TimeoutExpired:
        if proc is not None:
            proc.kill()
        print("FAIL: TUI interactive timed out under PTY", file=sys.stderr)
        return 1
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)

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


def read_all(fd: int) -> str:
    chunks: list[bytes] = []
    while True:
        try:
            chunk = os.read(fd, 8192)
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
