#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 tools/tui_live_vm_pty_test.py --tui zig-out/bin/zig-scheduler-tui --daemon zig-out/bin/zig-scheduler-daemon --state-dir evidence/lab/tui-e2e/live/daemon-state --transcript evidence/lab/tui-e2e/live/tui-transcript.txt --keys mq
"""PTY driver for the TUI-launched live microVM lab e2e harness."""

from __future__ import annotations

from dataclasses import dataclass
import errno
import os
from pathlib import Path
import pty
import signal
import subprocess
import sys
import time
from typing import Final

DEFAULT_WIDTH: Final[str] = "120"
DEFAULT_HEIGHT: Final[str] = "30"
DEFAULT_TIMEOUT_SECONDS: Final[float] = 900.0


@dataclass(frozen=True, slots=True)
class Args:
    tui: str
    daemon: str
    state_dir: str
    transcript: Path
    keys: bytes
    width: str
    height: str
    timeout_seconds: float


class DriverError(Exception):
    """Raised when the live VM PTY driver input is invalid or times out."""


def parse_args(argv: list[str]) -> Args:
    values: dict[str, str] = {}
    index = 0
    while index < len(argv):
        option = argv[index]
        if option not in {"--tui", "--daemon", "--state-dir", "--transcript", "--keys", "--width", "--height", "--timeout-seconds"}:
            raise DriverError(usage())
        index += 1
        if index >= len(argv):
            raise DriverError(f"{option} requires a value")
        values[option] = argv[index]
        index += 1
    missing = [name for name in ("--tui", "--daemon", "--state-dir", "--transcript", "--keys") if name not in values]
    if missing:
        raise DriverError(f"missing required option(s): {', '.join(missing)}")
    keys = values["--keys"].encode("ascii", errors="strict")
    if not keys or any(byte in (10, 13, 0) for byte in keys):
        raise DriverError("keys must be non-empty ASCII without control delimiters")
    return Args(
        tui=values["--tui"],
        daemon=values["--daemon"],
        state_dir=values["--state-dir"],
        transcript=Path(values["--transcript"]),
        keys=keys,
        width=values.get("--width", DEFAULT_WIDTH),
        height=values.get("--height", DEFAULT_HEIGHT),
        timeout_seconds=float(values.get("--timeout-seconds", str(DEFAULT_TIMEOUT_SECONDS))),
    )


def usage() -> str:
    return "usage: tui_live_vm_pty_test.py --tui <bin> --daemon <bin> --state-dir <dir> --transcript <path> --keys <keys> [--width n] [--height n] [--timeout-seconds n]"


def run_tui(args: Args) -> int:
    args.transcript.parent.mkdir(parents=True, exist_ok=True)
    master_fd, slave_fd = pty.openpty()
    os.set_blocking(master_fd, False)
    proc: subprocess.Popen[bytes] | None = None
    output = ""
    try:
        proc = subprocess.Popen(  # noqa: S603
            [
                args.tui,
                "--interactive",
                "--screen",
                "vm-lab",
                "--width",
                args.width,
                "--height",
                args.height,
                "--daemon-state-dir",
                args.state_dir,
                "--daemon-bin",
                args.daemon,
            ],
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            start_new_session=True,
        )
        os.close(slave_fd)
        slave_fd = -1
        deadline = time.monotonic() + args.timeout_seconds
        time.sleep(0.25)
        output += read_available(master_fd)
        for key in args.keys:
            os.write(master_fd, bytes((key,)))
            time.sleep(0.10)
            output += read_available(master_fd)
        while proc.poll() is None:
            if time.monotonic() >= deadline:
                terminate_process_group(proc)
                raise DriverError(f"TUI live VM PTY run timed out after {args.timeout_seconds:.0f}s")
            time.sleep(0.25)
            output += read_available(master_fd)
        output += read_available(master_fd)
        return proc.returncode
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)
        args.transcript.write_text(output, encoding="utf-8")


def terminate_process_group(proc: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=5)
    except ProcessLookupError:
        return
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5)


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


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    rc = run_tui(args)
    if rc != 0:
        print(f"FAIL: TUI exited with status {rc}", file=sys.stderr)
        return 1
    print(f"PASS: TUI PTY transcript captured at {args.transcript}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (DriverError, OSError, UnicodeEncodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
