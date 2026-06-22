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

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.tui_live_vm_cleanup import (
    cleanup_live_artifacts_without_daemon_kill,
    cleanup_launched_live_processes,
    run_self_test,
    wait_for_event_journal,
)
from tools.tui_pty_io import strip_ansi

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
    tui_idle_timeout_polls: str


class DriverError(Exception):
    """Raised when the live VM PTY driver input is invalid or times out."""


def parse_args(argv: list[str]) -> Args:
    values: dict[str, str] = {}
    index = 0
    while index < len(argv):
        option = argv[index]
        if option not in {"--tui", "--daemon", "--state-dir", "--transcript", "--keys", "--width", "--height", "--timeout-seconds", "--tui-idle-timeout-polls"}:
            raise DriverError(usage())
        index += 1
        if index >= len(argv):
            raise DriverError(f"{option} requires a value")
        values[option] = argv[index]
        index += 1
    missing = [name for name in ("--tui", "--daemon", "--state-dir", "--transcript", "--keys") if name not in values]
    if missing:
        raise DriverError(f"missing required option(s): {', '.join(missing)}")
    key_text = values["--keys"]
    keys = b"".join(b"\r" if char == "@" else char.encode("ascii", errors="strict") for char in key_text)
    if not keys or any(byte in (10, 0) for byte in keys):
        raise DriverError("keys must be non-empty ASCII without NUL/newline delimiters; use @ for Enter")
    return Args(
        tui=values["--tui"],
        daemon=values["--daemon"],
        state_dir=values["--state-dir"],
        transcript=Path(values["--transcript"]),
        keys=keys,
        width=values.get("--width", DEFAULT_WIDTH),
        height=values.get("--height", DEFAULT_HEIGHT),
        timeout_seconds=float(values.get("--timeout-seconds", str(DEFAULT_TIMEOUT_SECONDS))),
        tui_idle_timeout_polls=values.get("--tui-idle-timeout-polls", ""),
    )


def usage() -> str:
    return "usage: tui_live_vm_pty_test.py --tui <bin> --daemon <bin> --state-dir <dir> --transcript <path> --keys <keys> [--width n] [--height n] [--timeout-seconds n]"


def run_tui(args: Args) -> int:
    args.transcript.parent.mkdir(parents=True, exist_ok=True)
    master_fd, slave_fd = pty.openpty()
    os.set_blocking(master_fd, False)
    proc: subprocess.Popen[bytes] | None = None
    output = ""
    force_cleanup = False
    incident_quit_sent = False
    try:
        proc = subprocess.Popen(  # noqa: S603
            [
                args.tui,
                "--interactive",
                *( ["--test-mode"] if args.tui_idle_timeout_polls else [] ),
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
                *( ["--test-idle-timeout-polls", args.tui_idle_timeout_polls] if args.tui_idle_timeout_polls else [] ),
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
        for index, key in enumerate(args.keys):
            _ = os.write(master_fd, bytes((key,)))
            if index == 0 and key == ord("m"):
                output = collect_until_marker(master_fd, output, "ATTACH TARGET", 2.0)
            else:
                time.sleep(0.35)
                output += read_available(master_fd)
        while proc.poll() is None:
            if time.monotonic() >= deadline:
                force_cleanup = True
                terminate_process_group(proc)
                output += "\nINCIDENT timeout\n"
                raise DriverError(f"TUI live VM PTY run timed out after {args.timeout_seconds:.0f}s")
            time.sleep(0.25)
            output += read_available(master_fd)
            plain = strip_ansi(output)
            if not incident_quit_sent and ("current incident: INCIDENT" in plain or ("│ INCIDENT" in plain and "host_mutation=false" in plain)):
                _ = os.write(master_fd, b"q")
                incident_quit_sent = True
        output += read_available(master_fd)
        force_cleanup = proc.returncode != 0
        return proc.returncode
    finally:
        wait_for_event_journal(args.state_dir)
        if force_cleanup:
            cleanup_launched_live_processes(args.state_dir)
        else:
            cleanup_live_artifacts_without_daemon_kill(args.state_dir)
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)
        _ = args.transcript.write_text(output, encoding="utf-8")


def collect_until_marker(fd: int, output: str, marker: str, timeout_seconds: float) -> str:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        time.sleep(0.05)
        output += read_available(fd)
        if marker in strip_ansi(output):
            return output
    return output


def terminate_process_group(proc: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        _ = proc.wait(timeout=5)
    except ProcessLookupError:
        return
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        _ = proc.wait(timeout=5)


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
    if argv == ["--self-test"]:
        return run_self_test()
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
