"""Malformed stream and redaction PTY scenario for the root TUI harness."""

from __future__ import annotations

import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import time
from typing import Final

if __package__:
    from .tui_pty_io import read_available, strip_ansi
else:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from tools.tui_pty_io import read_available, strip_ansi

REQUIRED_MARKERS: Final[tuple[str, ...]] = (
    "INCIDENT malformed_line",
    "ALERT STRIP",
    "• incident          INCIDENT malformed_line",
    "• incident raw",
    "latest · INCIDENT malformed_line",
    "current incident: INCIDENT malformed_line",
    "host_mutation=false",
)
PRIVATE_MARKERS: Final[tuple[str, ...]] = (
    "/home/mei",
    "/home/mei/projects/zig/zig-scheduler/private",
    "SECRET_TOKEN=abc123",
    "api_key=supersecret",
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
)
HOSTILE_TERMINAL_MARKERS: Final[tuple[str, ...]] = (
    "\x1b]2;OSC_TITLE_PROMPT_INJECTION",
    "\x1b[31mHOSTILE_RED_TEXT",
    "\x07HOSTILE_BELL_PROMPT",
    "\x08HOSTILE_BACKSPACE_PROMPT",
    "OSC_TITLE_PROMPT_INJECTION",
)
DEFAULT_FIXTURE: Final[str] = "fixtures/tui/daemon-malformed-private-lines.jsonl"


def run_daemon(fixture: str = DEFAULT_FIXTURE) -> int:
    fixture_path = Path(fixture)
    state_dir = Path(".")
    args = sys.argv[1:]
    for index, arg in enumerate(args):
        if arg == "--state-dir" and index + 1 < len(args):
            state_dir = Path(args[index + 1])
    state_dir.mkdir(parents=True, exist_ok=True)
    journal = state_dir / "events.jsonl"
    _ = sys.stdin.read()
    accumulated: list[str] = []
    for raw in fixture_path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        if not line:
            continue
        accumulated.append(line)
        _ = journal.write_text("\n".join(accumulated) + "\n", encoding="utf-8")
        print(line, flush=True)
        time.sleep(0.10)
    return 0


def run_malformed_redaction(binary: str, daemon_binary: str, fixture: str, evidence: str) -> int:
    if not Path(binary).exists():
        print(f"FAIL: missing TUI binary: {binary}", file=sys.stderr)
        return 1
    if not Path(daemon_binary).exists():
        print(f"FAIL: missing daemon binary: {daemon_binary}", file=sys.stderr)
        return 1
    if not Path(fixture).is_file():
        print(f"FAIL: missing malformed fixture: {fixture}", file=sys.stderr)
        return 1

    evidence_path = Path(evidence)
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    state_dir = evidence_path.parent / "task-8-malformed-redaction-state"
    _ = subprocess.run(["rm", "-rf", str(state_dir)], check=False)  # noqa: S603
    state_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="zigsched-malformed-daemon.") as tmp:
        shim = Path(tmp) / "malformed-daemon.py"
        _ = shim.write_text(malformed_daemon_script(fixture), encoding="utf-8")
        shim.chmod(0o755)
        rc, transcript = run_tui_session(binary, str(shim), str(state_dir))

    stripped = strip_ansi(transcript)
    missing = [marker for marker in REQUIRED_MARKERS if marker not in stripped]
    leaked = [marker for marker in PRIVATE_MARKERS if marker in stripped]
    hostile_leaked = [marker for marker in HOSTILE_TERMINAL_MARKERS if marker in transcript or marker in stripped]
    redacted_seen = "[redacted]" in stripped
    plain_control_leak = any(ord(char) < 32 and char not in "\n\r\t" for char in stripped) or "\x1b" in stripped
    evidence_text = "\n".join((
        "scenario=malformed-redaction",
        f"tui_rc={rc}",
        f"fixture={fixture}",
        f"state_dir={state_dir}",
        f"missing={missing}",
        f"leaked={leaked}",
        f"hostile_terminal_leaked={hostile_leaked}",
        f"plain_control_leak={plain_control_leak}",
        f"redacted_seen={redacted_seen}",
        "--- transcript ---",
        stripped,
    ))
    _ = evidence_path.write_text(evidence_text, encoding="utf-8")
    _ = subprocess.run(["rm", "-rf", str(state_dir)], check=False)  # noqa: S603
    if rc != 0 or missing or leaked or hostile_leaked or plain_control_leak or not redacted_seen:
        print(f"FAIL: malformed/redaction scenario evidence={evidence}", file=sys.stderr)
        if missing:
            print("missing: " + ", ".join(missing), file=sys.stderr)
        if leaked:
            print("leaked: " + ", ".join(leaked), file=sys.stderr)
        if hostile_leaked:
            print("hostile terminal leak: " + ", ".join(hostile_leaked), file=sys.stderr)
        if plain_control_leak:
            print("plain transcript still contains terminal controls", file=sys.stderr)
        if not redacted_seen:
            print("redacted preview not visible in transcript", file=sys.stderr)
        return 1
    print(f"PASS: malformed stream rendered first-class incident with redacted raw preview evidence={evidence}")
    return 0


def malformed_daemon_script(fixture: str) -> str:
    lines = [
        "#!/usr/bin/env python3",
        "from __future__ import annotations",
        "import sys",
        "import time",
        "from pathlib import Path",
        f"fixture = Path({fixture!r})",
        'state_dir = Path(".")',
        "args = sys.argv[1:]",
        "for i, arg in enumerate(args):",
        '    if arg == "--state-dir" and i + 1 < len(args):',
        "        state_dir = Path(args[i + 1])",
        "state_dir.mkdir(parents=True, exist_ok=True)",
        'journal = state_dir / "events.jsonl"',
        "_ = sys.stdin.read()",
        "accumulated: list[str] = []",
        'for raw in fixture.read_text(encoding="utf-8").splitlines():',
        "    line = raw.rstrip()",
        "    if not line:",
        "        continue",
        "    accumulated.append(line)",
        '    journal.write_text("\\n".join(accumulated) + "\\n", encoding="utf-8")',
        "    print(line, flush=True)",
        "    time.sleep(0.10)",
        "sys.exit(0)",
    ]
    return "\n".join(lines) + "\n"


def run_tui_session(binary: str, daemon_binary: str, state_dir: str) -> tuple[int, str]:
    master_fd, slave_fd = pty.openpty()
    os.set_blocking(master_fd, False)
    proc: subprocess.Popen[bytes] | None = None
    output = ""
    sent_quit = False
    deadline = time.monotonic() + 15.0
    try:
        proc = subprocess.Popen(  # noqa: S603
            [
                binary,
                "--interactive",
                "--test-mode",
                "--screen",
                "vm-lab",
                "--width",
                "197",
                "--height",
                "62",
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
        time.sleep(0.25)
        output += read_available(master_fd)
        _ = os.write(master_fd, b"\rm")
        while time.monotonic() < deadline:
            time.sleep(0.05)
            output += read_available(master_fd)
            plain = strip_ansi(output)
            if "INCIDENT malformed_line" in plain and "• incident raw" in plain and not sent_quit:
                _ = os.write(master_fd, b"q")
                sent_quit = True
            if sent_quit and proc.poll() is not None:
                break
        if proc.poll() is None:
            proc.kill()
            return 1, output + read_available(master_fd)
        rc = proc.wait(timeout=2)
        time.sleep(0.1)
        output += read_available(master_fd)
        return rc, output
    except subprocess.TimeoutExpired:
        if proc is not None:
            proc.kill()
        return 1, output
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)


if __name__ == "__main__":
    raise SystemExit(run_daemon())
