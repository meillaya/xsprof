#!/usr/bin/env python3
"""Deterministic hung fake daemon for desktop controller timeout tests."""

from __future__ import annotations

import os
import signal
import sys
import time
from pathlib import Path
from types import FrameType


def state_dir_from_args(argv: list[str]) -> Path:
    for index, arg in enumerate(argv):
        if arg == "--state-dir" and index + 1 < len(argv):
            return Path(argv[index + 1])
    return Path(".")


def main(argv: list[str]) -> int:
    state_dir = state_dir_from_args(argv)
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "hung-daemon.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
    _ = sys.stdin.read()

    def ignore_term(_signum: int, _frame: FrameType | None) -> None:
        (state_dir / "hung-daemon-saw-term").write_text("true\n", encoding="utf-8")

    signal.signal(signal.SIGTERM, ignore_term)
    while True:
        time.sleep(1.0)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
