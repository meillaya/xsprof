"""Delayed live-stream PTY scenario for the root TUI harness."""

from __future__ import annotations

import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import time
from typing import Final

from tui_pty_io import first_order_error, read_available, strip_ansi

DELAYED_REQUIRED_MARKERS: Final[tuple[str, ...]] = (
    "[queued] VM run queued",
    "build PASS",
    "[booting] QEMU boot requested",
    "vm_marker PASS",
    "verifier PASS",
    "[attached] console attached",
    "[observing] runtime sample",
    "[rollback ready] rollback target ready",
    "rollback active",
    "rollback PASS",
    "audit PASS",
    "[cleanup] cleanup running",
    "[cleaned] VM resources cleaned",
    "[SAFE] footer mode SAFE",
)


def run_delayed_live_stream(binary: str, daemon_binary: str, fixture: str, evidence: str) -> int:
    if not Path(binary).exists():
        print(f"FAIL: missing TUI binary: {binary}", file=sys.stderr)
        return 1
    if not Path(daemon_binary).exists():
        print(f"FAIL: missing daemon binary: {daemon_binary}", file=sys.stderr)
        return 1
    if not Path(fixture).is_file():
        print(f"FAIL: missing delayed fixture: {fixture}", file=sys.stderr)
        return 1

    evidence_path = Path(evidence)
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    state_dir = evidence_path.parent / "task-6-delayed-live-stream-state"
    subprocess.run(["rm", "-rf", str(state_dir)], check=False)  # noqa: S603
    state_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="zigsched-delayed-daemon.") as tmp:
        shim = Path(tmp) / "delayed-daemon.py"
        eof_marker = state_dir / "fixture-eof.marker"
        shim.write_text(delayed_daemon_script(fixture, eof_marker), encoding="utf-8")
        shim.chmod(0o755)
        rc, transcript, marker_seen_before_eof, theme_seen_before_eof = run_delayed_tui_session(
            binary,
            str(shim),
            str(state_dir),
            eof_marker,
        )

    stripped = strip_ansi(transcript)
    missing = [marker for marker in DELAYED_REQUIRED_MARKERS if marker not in stripped]
    order_error = first_order_error(stripped, DELAYED_REQUIRED_MARKERS)
    evidence_text = "\n".join((
        "scenario=delayed-live-stream",
        f"tui_rc={rc}",
        f"fixture={fixture}",
        f"state_dir={state_dir}",
        f"first_intermediate_before_eof={marker_seen_before_eof}",
        f"theme_input_before_eof={theme_seen_before_eof}",
        f"missing={missing}",
        f"order_error={order_error}",
        "--- transcript ---",
        stripped,
    ))
    evidence_path.write_text(evidence_text, encoding="utf-8")
    subprocess.run(["rm", "-rf", str(state_dir)], check=False)  # noqa: S603
    if rc != 0 or missing or order_error or not marker_seen_before_eof or not theme_seen_before_eof:
        print(f"FAIL: delayed live stream scenario evidence={evidence}", file=sys.stderr)
        if missing:
            print("missing: " + ", ".join(missing), file=sys.stderr)
        if order_error:
            print(order_error, file=sys.stderr)
        if not marker_seen_before_eof:
            print("first intermediate frame did not appear before daemon EOF", file=sys.stderr)
        if not theme_seen_before_eof:
            print("live input did not update theme before daemon EOF", file=sys.stderr)
        return 1
    print(f"PASS: delayed live stream rendered ordered intermediate frames before daemon EOF evidence={evidence}")
    return 0


def delayed_daemon_script(fixture: str, eof_marker: Path) -> str:
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
        "    line = raw.strip()",
        "    if not line:",
        "        continue",
        "    accumulated.append(line)",
        '    journal.write_text("\\n".join(accumulated) + "\\n", encoding="utf-8")',
        "    print(line, flush=True)",
        "    time.sleep(0.18)",
        f'Path({str(eof_marker)!r}).write_text("fixture stdout closed\\n", encoding="utf-8")',
    ]
    return "\n".join(lines) + "\n"


def run_delayed_tui_session(binary: str, daemon_binary: str, state_dir: str, eof_marker: Path) -> tuple[int, str, bool, bool]:
    master_fd, slave_fd = pty.openpty()
    os.set_blocking(master_fd, False)
    proc: subprocess.Popen[bytes] | None = None
    output = ""
    marker_seen_before_eof = False
    theme_seen_before_eof = False
    sent_theme = False
    sent_quit = False
    deadline = time.monotonic() + 20.0
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
        os.write(master_fd, b"\rm")
        while time.monotonic() < deadline:
            time.sleep(0.05)
            output += read_available(master_fd)
            plain = strip_ansi(output)
            eof_seen = eof_marker.exists()
            if "[queued] VM run queued" in plain and not eof_seen:
                marker_seen_before_eof = True
            if marker_seen_before_eof and not sent_theme:
                os.write(master_fd, b"w")
                sent_theme = True
            if sent_theme and "theme cool dark" in plain and not eof_seen:
                theme_seen_before_eof = True
            if "[SAFE] footer mode SAFE" in plain and eof_seen and not sent_quit:
                os.write(master_fd, b"q")
                sent_quit = True
            if sent_quit and proc.poll() is not None:
                break
        if proc.poll() is None:
            proc.kill()
            return 1, output + read_available(master_fd), marker_seen_before_eof, theme_seen_before_eof
        rc = proc.wait(timeout=2)
        time.sleep(0.1)
        output += read_available(master_fd)
        return rc, output, marker_seen_before_eof, theme_seen_before_eof
    except subprocess.TimeoutExpired:
        if proc is not None:
            proc.kill()
        return 1, output, marker_seen_before_eof, theme_seen_before_eof
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)
