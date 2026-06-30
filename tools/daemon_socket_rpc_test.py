#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.frontend_contract_pack_types import ContractPackError, parse_json_object
from tools.daemon_socket_rpc_assertions import JsonObject, expected_rpc_error, fail, rpc_error


def parse_response(data: bytes) -> JsonObject:
    try:
        return parse_json_object(data.decode(), "daemon socket response")
    except UnicodeDecodeError as exc:
        fail(f"response is not UTF-8 JSON: {exc}")
    except ContractPackError as exc:
        fail(str(exc))


def request_raw(sock: socket.socket, payload: bytes) -> JsonObject:
    sock.sendall(payload + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        chunk = sock.recv(65536)
        if not chunk:
            fail("socket closed before response")
        data += chunk
    return parse_response(data)


def request(sock: socket.socket, payload: JsonObject) -> JsonObject:
    return request_raw(sock, json.dumps(payload, separators=(",", ":")).encode())


def result(response: JsonObject) -> JsonObject:
    if response.get("jsonrpc") != "2.0":
        fail(f"bad jsonrpc response: {response}")
    value = response.get("result")
    if not isinstance(value, dict):
        fail(f"missing result: {response}")
    if value.get("host_mutation") is not False:
        fail(f"result did not preserve host_mutation=false: {response}")
    return value


def string_field(response: JsonObject, key: str) -> str:
    value = response.get(key)
    if not isinstance(value, str):
        fail(f"response field {key} is not a string: {response}")
    return value


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        fail("usage: daemon_socket_rpc_test.py <daemon-bin>")
    bin_path = Path(argv[0])
    state_dir = Path(".zig-cache/tmp/zig-scheduler-daemon-socket-rpc-test")
    sock_path = state_dir / "daemon.sock"
    if state_dir.exists():
        _ = subprocess.run(["rm", "-rf", str(state_dir)], check=True)
    state_dir.mkdir(parents=True)
    _ = os.chmod(state_dir, 0o700)
    outside_proc = subprocess.run([
        str(bin_path),
        "--foreground",
        "--state-dir",
        str(state_dir),
        "--socket",
        ".zig-cache/tmp/outside-daemon.sock",
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if outside_proc.returncode == 0:
        fail("daemon accepted a socket outside the state dir")
    _ = os.chmod(state_dir, 0o777)
    unsafe_dir_proc = subprocess.run([
        str(bin_path),
        "--foreground",
        "--state-dir",
        str(state_dir),
        "--socket",
        str(sock_path),
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if unsafe_dir_proc.returncode == 0 or sock_path.exists():
        fail("daemon accepted a group/world-writable state dir")
    _ = os.chmod(state_dir, 0o700)
    collisions = [
        state_dir / "not-a-socket",
        state_dir / "socket-dir",
        state_dir / "socket-symlink",
    ]
    _ = collisions[0].write_text("must not be unlinked")
    collisions[1].mkdir()
    os.symlink("not-a-socket", collisions[2])
    for collision in collisions:
        bad_proc = subprocess.run([
            str(bin_path),
            "--foreground",
            "--state-dir",
            str(state_dir),
            "--socket",
            str(collision),
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if bad_proc.returncode == 0 or not collision.exists():
            fail(f"daemon accepted or unlinked a non-socket collision: {collision}")
    _ = (state_dir / "events.jsonl").write_text(
        '{"schema":"zig-scheduler/daemon-event/v1","seq":1,"event":"lab_run_active","action":"run_lab_microvm_live","action_id":"rpc-live-active","target_id":"rpc-target-active","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-rpc-active","artifact":"evidence/lab/rpc-active","state":"partial_switch_lab","status":"active","host_mutation":false}\n'
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
            if sock_path.exists() and stat.S_IMODE(sock_path.stat().st_mode) == 0o600:
                break
            if proc.poll() is not None:
                stdout, stderr = proc.communicate()
                fail(f"daemon exited early rc={proc.returncode} stdout={stdout} stderr={stderr}")
            time.sleep(0.05)
        else:
            fail("socket did not appear with mode 0600")
        if not stat.S_ISSOCK(sock_path.stat().st_mode):
            fail("daemon socket path is not a socket")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(sock_path))
            _ = rpc_error(
                request_raw(client, b"{not-json"),
                expected_rpc_error(-32700, "parse_error", "malformed_rpc"),
            )
            _ = rpc_error(
                request(client, {"jsonrpc": "1.0", "id": "bad-version", "method": "daemon.version"}),
                expected_rpc_error(-32600, "invalid_request", "invalid_rpc_version"),
            )
            _ = rpc_error(
                request(client, {"jsonrpc": "2.0", "id": "unknown", "method": "daemon.unknown"}),
                expected_rpc_error(-32601, "method_not_found", "unknown_rpc_method"),
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
            _ = rpc_error(missing_action, expected_rpc_error(-32602, "invalid_params", "action_json_required"))
            submitted = result(request(client, {
                "jsonrpc": "2.0",
                "id": "preflight",
                "method": "actions.submit",
                "params": {"action_json": '{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"rpc-preflight-1"}'},
            }))
            if '"action":"preflight"' not in string_field(submitted, "events_jsonl"):
                fail(f"preflight action did not dispatch: {submitted}")
            refused = result(request(client, {
                "jsonrpc": "2.0",
                "id": "malformed-action",
                "method": "actions.submit",
                "params": {"action_json": "{not-json"},
            }))
            if "malformed_action" not in string_field(refused, "events_jsonl"):
                fail(f"malformed action was not refused: {refused}")
            mismatch = request(client, {
                "jsonrpc": "2.0",
                "id": "rollback-mismatch",
                "method": "actions.rollback",
                "params": {"action_json": '{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"rpc-wrong-method-1"}'},
            })
            _ = rpc_error(mismatch, expected_rpc_error(-32602, "invalid_params", "rpc_action_mismatch"))
            stop_mismatch = request(client, {
                "jsonrpc": "2.0",
                "id": "stop-mismatch",
                "method": "actions.stop",
                "params": {"action_json": '{"schema":"zig-scheduler/operator-action/v1","action":"preflight","action_id":"rpc-wrong-method-2"}'},
            })
            _ = rpc_error(stop_mismatch, expected_rpc_error(-32602, "invalid_params", "rpc_action_mismatch"))
            duplicate = result(request(client, {
                "jsonrpc": "2.0",
                "id": "duplicate-target",
                "method": "actions.submit",
                "params": {"action_json": '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"rpc-live-duplicate","run_id":"rpc-run-duplicate","target_id":"rpc-target-active","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-rpc-duplicate"}'},
            }))
            duplicate_events = string_field(duplicate, "events_jsonl")
            if "duplicate_target_id" not in duplicate_events or "stage_started" in duplicate_events:
                fail(f"duplicate active target was not visibly refused before dispatch: {duplicate}")
            stopped = result(request(client, {
                "jsonrpc": "2.0",
                "id": "stop-active",
                "method": "actions.stop",
                "params": {"action_json": '{"schema":"zig-scheduler/operator-action/v1","action":"stop","action_id":"rpc-stop-1","target_action_id":"rpc-live-active","rollback_id":"RB-rpc-active"}'},
            }))
            stopped_events = string_field(stopped, "events_jsonl")
            if '"event":"cleanup"' not in stopped_events or '"reason":"stop_cleanup_requested"' not in stopped_events:
                fail(f"actions.stop did not dispatch cleanup success: {stopped}")
            replay = result(request(client, {"jsonrpc": "2.0", "id": "replay", "method": "events.replay", "params": {"from_event_seq": 2}}))
            follow = result(request(client, {"jsonrpc": "2.0", "id": "follow", "method": "events.follow", "params": {"from_event_seq": 2}}))
            events = string_field(replay, "events_jsonl")
            if events != string_field(follow, "events_jsonl"):
                fail(f"events.follow diverged from replay: replay={replay} follow={follow}")
            if '"seq":1' in events or '"seq":2' not in events:
                fail(f"event replay cursor failed: {replay}")
            targets = result(request(client, {"jsonrpc": "2.0", "id": "targets", "method": "targets.list"}))
            if not isinstance(targets.get("active_targets"), list):
                fail(f"targets.list did not return a list: {targets}")
            _ = client.shutdown(socket.SHUT_RDWR)
        stdout, stderr = proc.communicate(timeout=5)
        if proc.returncode != 0:
            fail(f"daemon exited rc={proc.returncode} stdout={stdout} stderr={stderr}")
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                _ = proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        _ = subprocess.run(["rm", "-rf", str(state_dir)], check=False)
    print("PASS daemon socket rpc")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
