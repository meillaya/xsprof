#!/usr/bin/env python3
"""Integration proof that desktop controller timeout kills a hung fake daemon."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import TypeAlias


JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


def process_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_if_alive(pid: int) -> None:
    if not process_is_alive(pid):
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            return
        time.sleep(0.2)


def json_rows(output: str) -> list[JsonObject]:
    rows: list[JsonObject] = []
    for line in output.splitlines():
        if not line.startswith("{"):
            continue
        parsed = json.loads(line)
        if isinstance(parsed, dict):
            rows.append(parsed)
    return rows


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: live_controller_timeout_test.py <desktop-app>", file=sys.stderr)
        return 2
    app = argv[0]
    with tempfile.TemporaryDirectory(prefix="zig-scheduler-live-controller-timeout-") as state_dir:
        command = [
            app,
            "--fake-daemon",
            "tools/live_controller_hung_daemon.py",
            "--state-dir",
            state_dir,
            "--bridge-test",
            "timeout-run",
        ]
        completed = subprocess.run(  # noqa: S603
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10.0,
            check=False,
        )
        pid_path = Path(state_dir) / "hung-daemon.pid"
        if not pid_path.exists():
            print(completed.stdout, end="")
            print(completed.stderr, end="", file=sys.stderr)
            print("FAIL: hung daemon pid marker was not written", file=sys.stderr)
            return 1
        pid = int(pid_path.read_text(encoding="utf-8").strip())
        try:
            rows = json_rows(completed.stdout)
            timeout_rows = [row for row in rows if row.get("event") == "incident" and row.get("reason") == "stream_timeout"]
            if completed.returncode != 0:
                print(completed.stdout, end="")
                print(completed.stderr, end="", file=sys.stderr)
                print(f"FAIL: timeout bridge command exited {completed.returncode}", file=sys.stderr)
                return 1
            if "controller_status=incident" not in completed.stdout or "child_terminated=true" not in completed.stdout:
                print(completed.stdout, end="")
                print("FAIL: timeout bridge did not report incident and child_terminated=true", file=sys.stderr)
                return 1
            if not timeout_rows:
                print(completed.stdout, end="")
                print("FAIL: stream_timeout incident missing from controller history", file=sys.stderr)
                return 1
            if process_is_alive(pid):
                print(completed.stdout, end="")
                print(f"FAIL: hung daemon pid {pid} survived controller timeout termination", file=sys.stderr)
                return 1
            print(f"PASS live-controller-timeout pid={pid} stream_timeout=true child_terminated=true process_alive=false")
            return 0
        finally:
            terminate_if_alive(pid)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
