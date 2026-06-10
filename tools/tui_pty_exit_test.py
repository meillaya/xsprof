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


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: tui_pty_exit_test.py <tui-binary>", file=sys.stderr)
        return 2

    binary = sys.argv[1]
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


if __name__ == "__main__":
    raise SystemExit(main())
