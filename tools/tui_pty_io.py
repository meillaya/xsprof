"""Shared PTY text and read helpers for root TUI smoke scenarios."""

from __future__ import annotations

from dataclasses import dataclass
import errno
import os
from pathlib import Path
import pty
import re
import shutil
import subprocess
import time

from typing import Final

PTY_QUIT_GRACE_SECONDS: Final[float] = 3.0
PTY_POLL_SECONDS: Final[float] = 0.05
PTY_WAIT_TIMEOUT_SECONDS: Final[int] = 2


@dataclass(frozen=True, slots=True)
class Capture:
    name: str
    transcript: str


@dataclass(frozen=True, slots=True)
class RunResult:
    rc: int
    transcript: str
    captures: tuple[Capture, ...]


ANSI_OR_CONTROL_RE = re.compile(
    r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\|$)"
    r"|\x1b\[[0-9;?]*[ -/]*[@-~]"
    r"|\x1b[P^_X].*?(?:\x1b\\|$)"
    r"|\x1b."
    r"|[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]",
    re.DOTALL,
)


def strip_ansi(text: str) -> str:
    return ANSI_OR_CONTROL_RE.sub("", text)


def first_order_error(text: str, markers: tuple[str, ...]) -> str:
    cursor = -1
    for marker in markers:
        pos = text.find(marker, cursor + 1)
        if pos < 0:
            return f"missing ordered marker: {marker}"
        cursor = pos
    return ""


PENDING_UTF8: dict[int, bytes] = {}


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
    data = PENDING_UTF8.pop(fd, b"") + b"".join(chunks)
    if not data:
        return ""
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        if exc.reason == "unexpected end of data":
            PENDING_UTF8[fd] = data[exc.start :]
            return data[: exc.start].decode("utf-8", errors="replace")
        return data.decode("utf-8", errors="replace")


def run_pty_steps(binary: str, argv: tuple[str, ...], state_dir: str, steps: tuple[tuple[bytes, str, str], ...], quit_after: bool, timeout_s: float) -> RunResult:
    shutil.rmtree(state_dir, ignore_errors=True)
    Path(state_dir).mkdir(parents=True, exist_ok=True)
    master_fd, slave_fd = pty.openpty()
    os.set_blocking(master_fd, False)
    proc: subprocess.Popen[bytes] | None = None
    output = ""
    captures: list[Capture] = []
    try:
        proc = subprocess.Popen((binary, *argv), stdin=slave_fd, stdout=slave_fd, stderr=slave_fd)  # noqa: S603
        os.close(slave_fd)
        slave_fd = -1
        for keys, name, marker in steps:
            plain_start = len(strip_ansi(output))
            if keys:
                os.write(master_fd, keys)
            output = collect_until(master_fd, output, marker, plain_start, timeout_s)
            if marker in strip_ansi(output)[plain_start:]:
                captures.append(Capture(name, output))
        if quit_after:
            os.write(master_fd, b"q")
        deadline = time.monotonic() + PTY_QUIT_GRACE_SECONDS
        while proc.poll() is None and time.monotonic() < deadline:
            time.sleep(PTY_POLL_SECONDS)
            output += read_available(master_fd)
        if proc.poll() is None:
            proc.kill()
            output += read_available(master_fd)
            return RunResult(1, output, tuple(captures))
        rc = proc.wait(timeout=PTY_WAIT_TIMEOUT_SECONDS)
        output += read_available(master_fd)
        return RunResult(rc, output, tuple(captures))
    except subprocess.TimeoutExpired:
        if proc is not None:
            proc.kill()
        return RunResult(1, output, tuple(captures))
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        PENDING_UTF8.pop(master_fd, None)
        os.close(master_fd)


def collect_until(fd: int, output: str, marker: str, plain_start: int, timeout_s: float) -> str:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        time.sleep(PTY_POLL_SECONDS)
        output += read_available(fd)
        if marker in strip_ansi(output)[plain_start:]:
            return output
    return output
