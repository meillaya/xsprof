#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class ServerStartTimeout(Exception):
    """Raised when the web harness does not answer before the smoke deadline."""


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def write_fake_daemon(root: Path) -> Path:
    daemon = root / "fake-live-vm-daemon.py"
    daemon.write_text(textwrap.dedent('''\
        #!/usr/bin/env python3
        import json, sys, time
        payload = json.loads(sys.stdin.readline())
        action = payload.get('action', 'run_lab_microvm_live')
        action_id = payload.get('action_id', 'web-test')
        rollback_id = payload.get('rollback_id', 'RB-web-test')
        rows = [
          {'schema':'zig-scheduler/daemon-event/v1','event':'stage_started','action':action,'action_id':action_id,'rollback_id':rollback_id,'status':'queued','reason':'microvm_live_runner_start','host_mutation':False},
          {'schema':'zig-scheduler/daemon-event/v1','event':'microvm_boot','action':action,'action_id':action_id,'status':'PASS','reason':'guest kernel booted','host_mutation':False},
          {'schema':'zig-scheduler/daemon-event/v1','event':'bpf_register','action':action,'action_id':action_id,'status':'PASS','reason':'runtime ops observed','host_mutation':False},
          {'schema':'zig-scheduler/daemon-event/v1','event':'runtime_sample','action':action,'action_id':action_id,'status':'PASS','state':'observing','reason':'runtime samples accepted','sample_sequence':1,'host_mutation':False},
          {'schema':'zig-scheduler/daemon-event/v1','event':'cleanup','action':action,'action_id':action_id,'status':'PASS','reason':'process scan clean','host_mutation':False},
          {'schema':'zig-scheduler/daemon-event/v1','event':'validation','action':action,'action_id':action_id,'status':'PASS','reason':'live bundle freshness accepted','host_mutation':False},
        ]
        for row in rows:
            print(json.dumps(row), flush=True)
            time.sleep(0.02)
    '''))
    daemon.chmod(0o755)
    return daemon


def wait_for_server(base: str) -> None:
    deadline = time.monotonic() + 5
    last: URLError | TimeoutError | OSError | None = None
    while time.monotonic() < deadline:
        try:
            urlopen(base + "/api/status", timeout=0.4).read()
            return
        except (URLError, TimeoutError, OSError) as exc:
            last = exc
            time.sleep(0.05)
    raise ServerStartTimeout(f"server did not start: {last}")


def main() -> int:
    repo = Path.cwd()
    with tempfile.TemporaryDirectory(prefix="live-vm-web-smoke-") as tmp_raw:
        tmp = Path(tmp_raw)
        daemon = write_fake_daemon(tmp)
        state_dir = repo / ".omo/evidence/live-vm-web-smoke"
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / "web-events.jsonl").unlink(missing_ok=True)
        port = free_port()
        base = f"http://127.0.0.1:{port}"
        proc = subprocess.Popen(
            [sys.executable, "tools/live_vm_web_server.py", "--port", str(port), "--daemon-bin", str(daemon), "--state-dir", str(state_dir)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            wait_for_server(base)
            html = urlopen(base + "/", timeout=5).read().decode()
            assert "live microVM lab" in html
            status = json.load(urlopen(base + "/api/status", timeout=5))
            assert status["host_mutation"] is False
            assert status["mode"] == "vm-lab-only"
            try:
                urlopen(Request(base + "/api/action/run", data=b"{}", method="POST"), timeout=5)
                raise AssertionError("unauthenticated POST unexpectedly accepted")
            except HTTPError as exc:
                assert exc.code == 403
                refused = json.load(exc)
                assert refused["event"] == "incident"
                assert refused["status"] == "refused"
                assert refused["reason"] == "invalid_or_missing_bridge_nonce"
                assert refused["host_mutation"] is False
            nonce = status["bridge_nonce"]
            try:
                urlopen(Request(
                    base + "/api/action/run",
                    data=b"{}",
                    method="POST",
                    headers={"X-ZigScheduler-Bridge-Nonce": nonce},
                ), timeout=5)
                raise AssertionError("nonce-only no-Origin POST unexpectedly accepted")
            except HTTPError as exc:
                assert exc.code == 403
                refused = json.load(exc)
                assert refused["event"] == "incident"
                assert refused["status"] == "refused"
                assert refused["reason"] == "missing_bridge_origin"
                assert refused["host_mutation"] is False
            accepted = json.load(urlopen(Request(
                base + "/api/action/run",
                data=b"{}",
                method="POST",
                headers={"X-ZigScheduler-Bridge-Nonce": nonce, "Origin": base},
            ), timeout=5))
            assert accepted["accepted"] is True
            assert accepted["payload"]["action"] == "run_lab_microvm_live"
            assert accepted["payload"]["schema"] == "zig-scheduler/operator-action/v1"
            assert "command" not in accepted["payload"] and "shell" not in accepted["payload"] and "argv" not in accepted["payload"]
            time.sleep(0.25)
            status = json.load(urlopen(base + "/api/status", timeout=5))
            assert status["event_count"] >= 4, status
            with urlopen(base + "/api/events", timeout=5) as res:
                first = res.readline().decode()
            assert first.startswith("data: ")
            assert '"host_mutation": false' in first
            journal = state_dir / "web-events.jsonl"
            text = journal.read_text()
            assert '"host_mutation": false' in text
            assert '"command"' not in text and '"shell"' not in text and '"argv"' not in text
            print("PASS live-vm-web smoke: source bridge nonce required, no-Origin nonce POST refused, same-origin VM-lab action accepted, SSE journal safe")
            return 0
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())
