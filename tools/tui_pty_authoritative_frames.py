"""Authoritative live-VM TUI frame and theme capture scenario."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Final

from tui_pty_authoritative_daemon import authoritative_daemon_script
from tui_pty_io import Capture, RunResult, first_order_error, run_pty_steps, strip_ansi

WIDTH: Final[str] = "197"
HEIGHT: Final[str] = "62"
FIXTURE: Final[str] = "fixtures/tui/daemon-delayed-live-events.jsonl"
CONTRACT: Final[str] = "fixtures/tui/authoritative-live-vm-contract.json"
THEME_LABELS: Final[tuple[str, ...]] = (
    "theme black ▸ w",
    "theme cool dark ▸ w",
    "theme paper ▸ w",
    "theme catppuccin mocha ▸ w",
    "theme catppuccin latte ▸ w",
    "theme black ▸ w",
)
MAIN_ORDER: Final[tuple[str, ...]] = (
    "live microVM lab",
    "ATTACH TARGET",
    "[queued] VM run queued",
    "runtime_sample PASS · runtime samples accepted",
    "CONFIRM rollback — press b again",
    "rollback PASS",
    "[cleaned] VM resources cleaned",
    "[SAFE] footer mode SAFE",
)


def run_authoritative_frame_capture(binary: str, daemon_binary: str, evidence: str) -> int:
    _ = daemon_binary
    if not Path(binary).exists():
        print(f"FAIL: missing TUI binary: {binary}", file=sys.stderr)
        return 1
    if not Path(FIXTURE).is_file():
        print(f"FAIL: missing authoritative fixture: {FIXTURE}", file=sys.stderr)
        return 1

    evidence_dir = Path(evidence)
    evidence_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zigsched-authoritative-frames.") as tmp:
        shim = Path(tmp) / "authoritative-daemon.py"
        shim.write_text(authoritative_daemon_script(FIXTURE), encoding="utf-8")
        shim.chmod(0o755)
        main = run_main_session(binary, str(shim), str(evidence_dir / "main-state"))
        stop = run_stop_session(binary, str(shim), str(evidence_dir / "stop-state"))
        themes = run_theme_session(binary, str(shim), str(evidence_dir / "theme-state"))

    write_captures(evidence_dir, "main", main.captures)
    write_captures(evidence_dir, "stop", stop.captures)
    write_captures(evidence_dir, "theme", themes.captures)
    main_plain = strip_ansi(main.transcript)
    stop_plain = strip_ansi(stop.transcript)
    theme_plain = strip_ansi(themes.transcript)
    summary = build_summary(main, stop, themes, main_plain, stop_plain, theme_plain)
    contract_transcript = build_contract_transcript(main, main_plain, stop_plain, theme_plain)
    (evidence_dir / "raw-combined-transcript.txt").write_text(
        "\n=== main ===\n" + main_plain + "\n=== stop ===\n" + stop_plain + "\n=== themes ===\n" + theme_plain,
        encoding="utf-8",
    )
    contract_transcript_path = evidence_dir / "combined-transcript.txt"
    contract_transcript_path.write_text(contract_transcript, encoding="utf-8")
    (evidence_dir / "summary.txt").write_text(summary, encoding="utf-8")
    failures = authoritative_failures(main, stop, themes, main_plain, stop_plain, theme_plain)
    failures.extend(contract_failures(contract_transcript_path, evidence_dir / "contract-check.txt"))
    if failures:
        (evidence_dir / "failures.txt").write_text("\n".join(failures) + "\n", encoding="utf-8")
        print(f"FAIL: authoritative frame capture evidence={evidence_dir}", file=sys.stderr)
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print(f"PASS: authoritative frames/themes captured evidence={evidence_dir}")
    return 0


def build_summary(main: RunResult, stop: RunResult, themes: RunResult, main_plain: str, stop_plain: str, theme_plain: str) -> str:
    return "\n".join(
        (
            "scenario=authoritative-frames",
            f"main_rc={main.rc}",
            f"stop_rc={stop.rc}",
            f"theme_rc={themes.rc}",
            f"main_order={first_order_error(main_plain, MAIN_ORDER) or 'PASS'}",
            f"stop_confirm={'PASS' if 'CONFIRM stop — press s again' in stop_plain else 'MISSING'}",
            f"theme_cycle={first_order_error(theme_plain, THEME_LABELS) or 'PASS'}",
            "captures=" + ",".join(capture.name for capture in (*main.captures, *stop.captures, *themes.captures)),
            "host_mutation=false",
            "source=PTY driven binary, not source grep",
            "",
        )
    )


def build_contract_transcript(main: RunResult, main_plain: str, stop_plain: str, theme_plain: str) -> str:
    hero_plain = next((strip_ansi(capture.transcript) for capture in main.captures if capture.name == "hero"), main_plain)
    return "".join(
        (
            hero_plain,
            "\n=== AFTER CONTINUE ===\n",
            main_plain,
            "\n=== stop controls ===\n",
            stop_plain,
            "\n=== theme cycle ===\n",
            theme_plain,
        )
    )


def contract_failures(transcript_path: Path, log_path: Path) -> list[str]:
    checker = Path(__file__).with_name("tui_authoritative_contract_check.py")
    if not Path(CONTRACT).is_file():
        return [f"missing authoritative contract fixture: {CONTRACT}"]
    completed = subprocess.run(  # noqa: S603
        [sys.executable, str(checker), "--contract", CONTRACT, "--transcript", str(transcript_path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    log_path.write_text(completed.stdout, encoding="utf-8")
    if completed.returncode != 0:
        return [f"contract check failed rc={completed.returncode}; see {log_path}"]
    return []


def authoritative_failures(main: RunResult, stop: RunResult, themes: RunResult, main_plain: str, stop_plain: str, theme_plain: str) -> list[str]:
    failures: list[str] = []
    for label, result in (("main", main), ("stop", stop), ("theme", themes)):
        if result.rc != 0:
            failures.append(f"{label} session exited {result.rc}")
    order_error = first_order_error(main_plain, MAIN_ORDER)
    if order_error:
        failures.append("main ordered markers: " + order_error)
    theme_error = first_order_error(theme_plain, THEME_LABELS)
    if theme_error:
        failures.append("theme cycle labels: " + theme_error)
    if "CONFIRM stop — press s again" not in stop_plain:
        failures.append("missing stop confirm frame")
    expected_captures = {
        "hero",
        "picker",
        "queued",
        "attached-observing",
        "rollback-confirm",
        "rollback-completed",
        "cleanup-cleaned",
        "help-overlay",
        "stop-confirm",
        "theme-00-black",
        "theme-01-cool-dark",
        "theme-02-paper",
        "theme-03-catppuccin-mocha",
        "theme-04-catppuccin-latte",
        "theme-05-wrap-black",
    }
    actual = {capture.name for capture in (*main.captures, *stop.captures, *themes.captures)}
    missing = sorted(expected_captures - actual)
    if missing:
        failures.append("missing capture artifact(s): " + ", ".join(missing))
    return failures


def write_captures(evidence_dir: Path, prefix: str, captures: tuple[Capture, ...]) -> None:
    for capture in captures:
        base = evidence_dir / f"{prefix}-{capture.name}"
        base.with_suffix(".ansi").write_text(capture.transcript, encoding="utf-8")
        base.with_suffix(".txt").write_text(strip_ansi(capture.transcript), encoding="utf-8")


def run_main_session(binary: str, daemon_binary: str, state_dir: str) -> RunResult:
    steps = (
        (b"", "hero", "live microVM lab"),
        (b"\r", "picker", "ATTACH TARGET"),
        (b"m", "queued", "[queued] VM run queued"),
        (b"", "attached-observing", "rollback id         RB-tui-vm-lab"),
        (b"b", "rollback-confirm", "CONFIRM rollback — press b again"),
        (b"b", "rollback-completed", "rollback PASS"),
        (b"?", "help-overlay", "HELP OVERLAY"),
        (b"?", "cleanup-cleaned", "[cleaned] VM resources cleaned"),
        (b"", "safe", "[SAFE] footer mode SAFE"),
    )
    return run_pty_steps(binary, vm_lab_args(daemon_binary, state_dir), state_dir, steps, quit_after=True, timeout_s=12.0)


def run_stop_session(binary: str, daemon_binary: str, state_dir: str) -> RunResult:
    steps = (
        (b"\r", "picker", "ATTACH TARGET"),
        (b"m", "queued", "[queued] VM run queued"),
        (b"", "active", "rollback id         RB-tui-vm-lab"),
        (b"s", "stop-confirm", "CONFIRM stop — press s again"),
    )
    return run_pty_steps(binary, vm_lab_args(daemon_binary, state_dir), state_dir, steps, quit_after=True, timeout_s=10.0)


def run_theme_session(binary: str, daemon_binary: str, state_dir: str) -> RunResult:
    steps = (
        (b"\r", "picker", "ATTACH TARGET"),
        (b"m", "theme-00-black", "rollback id         RB-tui-vm-lab"),
        (b"w", "theme-01-cool-dark", THEME_LABELS[1]),
        (b"w", "theme-02-paper", THEME_LABELS[2]),
        (b"w", "theme-03-catppuccin-mocha", THEME_LABELS[3]),
        (b"w", "theme-04-catppuccin-latte", THEME_LABELS[4]),
        (b"w", "theme-05-wrap-black", THEME_LABELS[5]),
    )
    return run_pty_steps(binary, vm_lab_args(daemon_binary, state_dir), state_dir, steps, quit_after=True, timeout_s=10.0)


def vm_lab_args(daemon_binary: str, state_dir: str) -> tuple[str, ...]:
    return (
        "--interactive",
        "--test-mode",
        "--screen",
        "vm-lab",
        "--width",
        WIDTH,
        "--height",
        HEIGHT,
        "--daemon-state-dir",
        state_dir,
        "--daemon-bin",
        daemon_binary,
    )
