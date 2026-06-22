"""Daemon refusal matrix helpers for root TUI PTY smoke tests."""

from __future__ import annotations

import subprocess


def run_daemon_stale_duplicate_matrix(daemon_binary: str) -> int:
    state_dir = ".omo/evidence/tui-pty-stale-duplicate-test"
    subprocess.run(["rm", "-rf", state_dir], check=False)  # noqa: S603
    duplicate_payload = (
        '{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"dup"}\n'
        '{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"dup"}\n'
        '{"schema":"zig-scheduler/operator-action/v1","action":"rollback_lab_run","run_id":"stale",'
        '"target_action_id":"missing","rollback_id":"RB-missing"}\n'
    )
    completed = subprocess.run(  # noqa: S603
        [daemon_binary, "--foreground", "--state-dir", state_dir],
        input=duplicate_payload,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=10,
    )
    subprocess.run(["rm", "-rf", state_dir], check=False)  # noqa: S603
    output = completed.stdout + completed.stderr
    if completed.returncode != 0:
        return 1
    if "duplicate_action_id" not in output or "stale_or_unknown_target_action_id" not in output:
        return 1
    print("PASS: daemon stale/duplicate rollback matrix refused safely")
    return 0
