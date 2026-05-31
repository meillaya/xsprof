#!/usr/bin/env python3
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

ENTER_ALT = b"\x1b[?1049h"
EXIT_ALT = b"\x1b[?1049l"
SHOW_CURSOR = b"\x1b[?25h"
CLEAR = b"\x1b[2J"
HOME = b"\x1b[H"


def drain(master_fd):
    out = bytearray()
    while True:
        readable, _, _ = select.select([master_fd], [], [], 0)
        if not readable:
            return bytes(out)
        try:
            chunk = os.read(master_fd, 8192)
        except OSError as exc:
            if exc.errno in (errno.EIO, errno.EBADF):
                return bytes(out)
            raise
        if not chunk:
            return bytes(out)
        out.extend(chunk)


def run_case(exe, name, input_bytes):
    master_fd, slave_fd = pty.openpty()
    try:
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        env = os.environ.copy()
        env.setdefault("TERM", "xterm-256color")
        proc = subprocess.Popen(
            [exe],
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
            cwd=os.getcwd(),
            env=env,
        )
    finally:
        os.close(slave_fd)

    output = bytearray()
    sent = False
    deadline = time.time() + 10.0
    try:
        while time.time() < deadline:
            readable, _, _ = select.select([master_fd], [], [], 0.05)
            if readable:
                try:
                    chunk = os.read(master_fd, 8192)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
            if not sent and ENTER_ALT in output:
                os.write(master_fd, input_bytes)
                sent = True
            if sent and proc.poll() is not None:
                output.extend(drain(master_fd))
                break
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)
            raise AssertionError(f"{name}: TUI did not exit after input")
        if proc.returncode != 0:
            raise AssertionError(f"{name}: process exited with {proc.returncode}\n{bytes(output)!r}")
    finally:
        os.close(master_fd)

    data = bytes(output)
    for token, label in ((ENTER_ALT, "enter alternate screen"), (EXIT_ALT, "exit alternate screen"), (SHOW_CURSOR, "show cursor")):
        if token not in data:
            raise AssertionError(f"{name}: missing {label} sequence")
    exit_index = data.rfind(EXIT_ALT)
    clear_index = data.rfind(CLEAR)
    home_index = data.rfind(HOME)
    if not (exit_index < clear_index < home_index):
        raise AssertionError(f"{name}: cleanup must exit alternate screen before final clear/home")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: tui_pty_exit_test.py <zig-scheduler-tui>")
    exe = sys.argv[1]
    if not os.path.exists(exe):
        raise AssertionError(f"missing executable: {exe}")
    run_case(exe, "quit-key", b"q")
    run_case(exe, "ctrl-c-byte", b"\x03")


if __name__ == "__main__":
    main()
