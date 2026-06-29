#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, NoReturn


def fail(message: str) -> NoReturn:
    raise SystemExit(f"FAIL daemon socket rpc: {message}")


def request(sock: socket.socket, payload: dict[str, Any]) -> dict[str, Any]:
    sock.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        chunk = sock.recv(65536)
        if not chunk:
            fail("socket closed before response")
        data += chunk
    raw = json.loads(data.decode())
    if not isinstance(raw, dict):
        fail("response is not an object")
    return raw


def result(response: dict[str, Any]) -> dict[str, Any]:
    if response.get("jsonrpc") != "2.0":
        fail(f"bad jsonrpc response: {response}")
    value = response.get("result")
    if not isinstance(value, dict):
        fail(f"missing result: {response}")
    if value.get("host_mutation") is not False:
        fail(f"result did not preserve host_mutation=false: {response}")
    return value


def rpc_error(response: dict[str, Any], incident_code: str) -> dict[str, Any]:
    if response.get("jsonrpc") != "2.0":
        fail(f"bad jsonrpc error response: {response}")
    error = response.get("error")
    if not isinstance(error, dict):
        fail(f"missing error: {response}")
    data = error.get("data")
    if not isinstance(data, dict):
        fail(f"missing error data: {response}")
    expected = {
        "incident_code": incident_code,
        "reason": incident_code,
        "state": "refused_host",
        "status": "REFUSE",
        "host_mutation": False,
    }
    for key, value in expected.items():
        if data.get(key) != value:
            fail(f"error data {key} drifted for {incident_code}: {response}")
    return data


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        fail("usage: daemon_socket_rpc_test.py <daemon-bin>")
    bin_path = Path(argv[0])
    state_dir = Path(".zig-cache/tmp/zig-scheduler-daemon-socket-rpc-test")
    sock_path = state_dir / "daemon.sock"
    if state_dir.exists():
        subprocess.run(["rm", "-rf", str(state_dir)], check=True)
    state_dir.mkdir(parents=True)
    collision = state_dir / "not-a-socket"
    collision.write_text("must not be unlinked")
    bad_proc = subprocess.run([
        str(bin_path),
        "--foreground",
        "--state-dir",
        str(state_dir),
        "--socket",
        str(collision),
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if bad_proc.returncode == 0 or not collision.exists():
        fail("daemon accepted or unlinked a non-socket collision")
    (state_dir / "events.jsonl").write_text(
        '{"schema":"zig-scheduler/daemon-event/v1","seq":1,"event":"lab_run_active","action":"run_lab_microvm_live","action_id":"rpc-live-active","target_id":"rpc-target-active","rollback_id":"RB-rpc-active","artifact":"evidence/lab/rpc-active","state":"partial_switch_lab","status":"active","host_mutation":false}\n'
    )
    proc = subprocess.Popen([
        str(bin_path),
        "--foreground",
        "--state-dir",
        str(state_dir),
        "--socket",
        str(sock_path),
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.time() + 5
        while time.time() < deadline:
            if sock_path.exists():
                break
            if proc.poll() is not None:
                stdout, stderr = proc.communicate()
                fail(f"daemon exited early rc={proc.returncode} stdout={stdout} stderr={stderr}")
            time.sleep(0.05)
        else:
            fail("socket did not appear")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(sock_path))
            rpc_error(
                request(client, {"jsonrpc": "1.0", "id": "bad-version", "method": "daemon.version"}),
                "invalid_rpc_version",
            )
            version = result(request(client, {"jsonrpc": "2.0", "id": "version", "method": "daemon.version"}))
            if version.get("event_schema") != "zig-scheduler/daemon-event/v1":
                fail(f"bad version result: {version}")
            missing_action = request(client, {
                "jsonrpc": "2.0",
                "id": "missing-action-json",
                "method": "actions.submit",
                "params": {},
            })
            rpc_error(missing_action, "action_json_required")
            submitted = result(request(client, {
                "jsonrpc": "2.0",
                "id": "preflight",
                "method": "actions.submit",
                "params": {"action_json": '{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"rpc-preflight-1"}'},
            }))
            if '"action":"preflight"' not in submitted.get("events_jsonl", ""):
                fail(f"preflight action did not dispatch: {submitted}")
            refused = result(request(client, {
                "jsonrpc": "2.0",
                "id": "malformed-action",
                "method": "actions.submit",
                "params": {"action_json": "{not-json"},
            }))
            if "malformed_action" not in refused.get("events_jsonl", ""):
                fail(f"malformed action was not refused: {refused}")
            mismatch = request(client, {
                "jsonrpc": "2.0",
                "id": "rollback-mismatch",
                "method": "actions.rollback",
                "params": {"action_json": '{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"rpc-wrong-method-1"}'},
            })
            rpc_error(mismatch, "rpc_action_mismatch")
            duplicate = result(request(client, {
                "jsonrpc": "2.0",
                "id": "duplicate-target",
                "method": "actions.submit",
                "params": {"action_json": '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"rpc-live-duplicate","run_id":"rpc-run-duplicate","target_id":"rpc-target-active","rollback_id":"RB-rpc-duplicate"}'},
            }))
            duplicate_events = duplicate.get("events_jsonl", "")
            if "duplicate_target_id" not in duplicate_events or "stage_started" in duplicate_events:
                fail(f"duplicate active target was not visibly refused before dispatch: {duplicate}")
            replay = result(request(client, {"jsonrpc": "2.0", "id": "replay", "method": "events.replay", "params": {"from_event_seq": 2}}))
            events = replay.get("events_jsonl", "")
            if '"seq":1' in events or '"seq":2' not in events:
                fail(f"event replay cursor failed: {replay}")
            targets = result(request(client, {"jsonrpc": "2.0", "id": "targets", "method": "targets.list"}))
            if not isinstance(targets.get("active_targets"), list):
                fail(f"targets.list did not return a list: {targets}")
            client.shutdown(socket.SHUT_RDWR)
        stdout, stderr = proc.communicate(timeout=5)
        if proc.returncode != 0:
            fail(f"daemon exited rc={proc.returncode} stdout={stdout} stderr={stderr}")
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        subprocess.run(["rm", "-rf", str(state_dir)], check=False)
    print("PASS daemon socket rpc")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
