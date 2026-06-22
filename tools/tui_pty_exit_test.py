#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 tools/tui_pty_exit_test.py zig-out/bin/zig-scheduler-tui
"""PTY smoke and evidence scenarios for the root Linux scheduler TUI."""

from __future__ import annotations

import sys

from tui_pty_authoritative_frames import run_authoritative_frame_capture
from tui_pty_daemon_matrix import run_daemon_stale_duplicate_matrix
from tui_pty_delayed_live import run_delayed_live_stream
from tui_pty_live_controls import run_duplicate_stale_live_controls
from tui_pty_malformed_redaction import run_malformed_redaction
from tui_pty_process_ownership import run_process_ownership
from tui_pty_smoke import (
    run_interactive,
    run_interactive_daemon,
    run_rollback_stop_matrix,
    run_snapshot,
)

USAGE = "usage: tui_pty_exit_test.py [--scenario delayed-live-stream|malformed-redaction --fixture <jsonl> --evidence <path> | --scenario process-ownership|duplicate-stale-live-controls|authoritative-frames --evidence <path>] <tui-binary> [daemon-binary]"


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--scenario":
        return run_named_scenario(sys.argv[2:])
    if len(sys.argv) not in {2, 3}:
        print(USAGE, file=sys.stderr)
        return 2

    binary = sys.argv[1]
    daemon_binary = sys.argv[2] if len(sys.argv) == 3 else "zig-out/bin/zig-scheduler-daemon"
    snapshot_rc = run_snapshot(binary)
    if snapshot_rc != 0:
        return snapshot_rc
    interactive_rc = run_interactive(binary)
    if interactive_rc != 0:
        return interactive_rc
    daemon_rc = run_interactive_daemon(binary, daemon_binary)
    if daemon_rc != 0:
        return daemon_rc
    matrix_rc = run_rollback_stop_matrix(binary, daemon_binary)
    if matrix_rc != 0:
        return matrix_rc
    live_controls_rc = run_duplicate_stale_live_controls(binary, daemon_binary, ".omo/evidence/tui-pty-live-controls.txt")
    if live_controls_rc != 0:
        return live_controls_rc
    return run_daemon_stale_duplicate_matrix(daemon_binary)


def run_named_scenario(argv: list[str]) -> int:
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    scenario = argv[0]
    args = argv[1:]
    fixture = ""
    evidence = ""
    positional: list[str] = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--fixture" and index + 1 < len(args):
            fixture = args[index + 1]
            index += 2
        elif arg == "--evidence" and index + 1 < len(args):
            evidence = args[index + 1]
            index += 2
        else:
            positional.append(arg)
            index += 1
    if scenario == "delayed-live-stream" and len(positional) == 2 and fixture and evidence:
        return run_delayed_live_stream(positional[0], positional[1], fixture, evidence)
    if scenario == "malformed-redaction" and len(positional) == 2 and fixture and evidence:
        return run_malformed_redaction(positional[0], positional[1], fixture, evidence)
    if scenario == "process-ownership" and len(positional) == 2 and not fixture and evidence:
        return run_process_ownership(positional[0], positional[1], evidence)
    if scenario == "duplicate-stale-live-controls" and len(positional) == 2 and not fixture and evidence:
        return run_duplicate_stale_live_controls(positional[0], positional[1], evidence)
    if scenario == "authoritative-frames" and len(positional) == 2 and not fixture and evidence:
        return run_authoritative_frame_capture(positional[0], positional[1], evidence)
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
