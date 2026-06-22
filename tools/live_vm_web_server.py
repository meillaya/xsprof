#!/usr/bin/env python3
# noqa: SIZE_OK - standalone browser/live-VM evidence harness kept indivisible so smoke artifacts, state, bridge, and handler behavior remain in one auditable script.
from __future__ import annotations

import argparse
import json
import os
import posixpath
import secrets
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Final, TypeAlias
from urllib.parse import urlparse

ACTION_SCHEMA: Final[str] = "zig-scheduler/operator-action/v1"
EVENT_SCHEMA: Final[str] = "zig-scheduler/daemon-event/v1"
WEB_SCHEMA: Final[str] = "zig-scheduler/live-vm-web/v1"

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
CONTENT_TYPES: Final[dict[str, str]] = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".jsx": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
}


@dataclass(frozen=True, slots=True)
class Args:
    host: str
    port: int
    app_root: Path
    design_root: Path
    authoritative_html: Path
    state_dir: Path
    daemon_bin: Path
    once: bool


class LiveVmWebState:
    def __init__(self, args: Args) -> None:
        self.args = args
        self.lock = threading.Condition()
        self.events: list[JsonObject] = []
        self.proc: subprocess.Popen[str] | None = None
        self.active_action_id = ""
        self.rollback_id = ""
        self.audit_id = ""
        self.seq = 0
        self.bridge_nonce = secrets.token_urlsafe(24)
        self.allowed_origin = f"http://{args.host}:{args.port}"
        self.args.state_dir.mkdir(parents=True, exist_ok=True)

    def next_seq(self) -> int:
        self.seq += 1
        return self.seq

    def snapshot(self) -> JsonObject:
        with self.lock:
            active = self.proc is not None and self.proc.poll() is None
            return {
                "schema": WEB_SCHEMA,
                "mode": "vm-lab-only",
                "host_mutation": False,
                "production_ready": False,
                "daemon_bin": str(self.args.daemon_bin),
                "state_dir": str(self.args.state_dir),
                "active": active,
                "active_action_id": self.active_action_id,
                "rollback_id": self.rollback_id,
                "audit_id": self.audit_id,
                "event_count": len(self.events),
                "bridge_mode": "browser-source",
                "bridge_nonce": self.bridge_nonce,
                "allowed_origin": self.allowed_origin,
            }

    def record(self, event: JsonObject) -> None:
        event = dict(event)
        event.setdefault("schema", EVENT_SCHEMA)
        event.setdefault("host_mutation", False)
        if event.get("host_mutation") is not False:
            event = {
                "schema": EVENT_SCHEMA,
                "seq": self.next_seq(),
                "event": "incident",
                "action": event.get("action", "live_vm_web"),
                "status": "refused",
                "reason": "host_mutation_not_false",
                "host_mutation": False,
            }
        event.setdefault("seq", self.next_seq())
        event.setdefault("source", "live-vm-web")
        line = json.dumps(event, sort_keys=True)
        with self.lock:
            self.events.append(event)
            if len(self.events) > 1000:
                self.events = self.events[-1000:]
            with (self.args.state_dir / "web-events.jsonl").open("a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            self.lock.notify_all()

    def duplicate_refusal(self, action_id: str) -> JsonObject:
        event = {
            "schema": EVENT_SCHEMA,
            "event": "refusal",
            "action": "run_lab_microvm_live",
            "action_id": action_id,
            "status": "refused",
            "reason": "duplicate_action_id",
            "host_mutation": False,
        }
        self.record(event)
        return event

    def stale_refusal(self, action: str, action_id: str) -> JsonObject:
        event = {
            "schema": EVENT_SCHEMA,
            "event": "refusal",
            "action": action,
            "action_id": action_id,
            "target_action_id": self.active_action_id,
            "rollback_id": self.rollback_id,
            "status": "refused",
            "reason": "stale_or_unknown_target_action_id",
            "host_mutation": False,
        }
        self.record(event)
        return event

    def bridge_refusal(self, method: str, reason: str) -> JsonObject:
        event = {
            "schema": EVENT_SCHEMA,
            "event": "incident",
            "action": "live_vm_bridge",
            "bridge_method": method,
            "status": "refused",
            "reason": reason,
            "host_mutation": False,
        }
        self.record(event)
        return event

    def start_action(self, action: str) -> tuple[int, JsonObject]:
        if action not in {"run", "rollback", "stop"}:
            return HTTPStatus.NOT_FOUND, self.bridge_refusal(action, "unsupported_bridge_method")
        if not self.args.daemon_bin.exists():
            event = {
                "schema": EVENT_SCHEMA,
                "event": "incident",
                "action": "run_lab_microvm_live" if action == "run" else f"{action}_lab_run",
                "status": "refused",
                "reason": "daemon_unavailable",
                "host_mutation": False,
            }
            self.record(event)
            return HTTPStatus.SERVICE_UNAVAILABLE, event

        now = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
        suffix = f"web-vm-lab-{os.getpid()}-{int(time.time() * 1000) % 100000}"
        with self.lock:
            active = self.proc is not None and self.proc.poll() is None
            if action == "run" and active:
                return HTTPStatus.CONFLICT, self.duplicate_refusal(self.active_action_id or suffix)
            if action in {"rollback", "stop"} and not self.active_action_id:
                return HTTPStatus.CONFLICT, self.stale_refusal(f"{action}_lab_run", suffix)

        if action == "run":
            action_id = suffix
            payload = {
                "schema": ACTION_SCHEMA,
                "action": "run_lab_microvm_live",
                "action_id": action_id,
                "run_id": action_id,
                "audit_id": f"AUD-{now}-{os.getpid()}",
                "rollback_id": f"RB-{action_id}",
            }
        else:
            with self.lock:
                target_action_id = self.active_action_id
                rollback_id = self.rollback_id
                audit_id = self.audit_id
            action_id = f"web-{action}-{int(time.time() * 1000) % 100000}"
            payload = {
                "schema": ACTION_SCHEMA,
                "action": f"{action}_lab_run",
                "action_id": action_id,
                "run_id": f"web-{action}",
                "audit_id": audit_id,
                "rollback_id": rollback_id,
                "target_action_id": target_action_id,
            }

        status, result = self._spawn_daemon(payload)
        return status, result

    def _spawn_daemon(self, payload: JsonObject) -> tuple[int, JsonObject]:
        argv = [str(self.args.daemon_bin), "--foreground", "--follow", "--state-dir", str(self.args.state_dir)]
        try:
            proc = subprocess.Popen(
                argv,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except OSError as exc:
            event = {
                "schema": EVENT_SCHEMA,
                "event": "incident",
                "action": payload["action"],
                "action_id": payload.get("action_id", ""),
                "status": "refused",
                "reason": f"daemon_spawn_failed:{exc.__class__.__name__}",
                "host_mutation": False,
            }
            self.record(event)
            return HTTPStatus.SERVICE_UNAVAILABLE, event

        assert proc.stdin is not None
        proc.stdin.write(json.dumps(payload, sort_keys=True) + "\n")
        proc.stdin.close()

        with self.lock:
            if payload["action"] == "run_lab_microvm_live":
                self.proc = proc
                self.active_action_id = str(payload.get("action_id", ""))
                self.rollback_id = str(payload.get("rollback_id", ""))
                self.audit_id = str(payload.get("audit_id", ""))

        self.record({
            "schema": EVENT_SCHEMA,
            "event": "stage_started",
            "action": payload["action"],
            "action_id": payload.get("action_id", ""),
            "rollback_id": payload.get("rollback_id", ""),
            "status": "queued",
            "reason": "browser_live_vm_bridge_queued",
            "host_mutation": False,
        })
        thread = threading.Thread(target=self._read_daemon, args=(proc,), daemon=True)
        thread.start()
        return HTTPStatus.ACCEPTED, {"accepted": True, "payload": payload, "host_mutation": False}

    def _read_daemon(self, proc: subprocess.Popen[str]) -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            raw = line.strip()
            if not raw:
                continue
            try:
                event = json.loads(raw)
            except json.JSONDecodeError:
                event = {
                    "schema": EVENT_SCHEMA,
                    "event": "incident",
                    "action": "run_lab_microvm_live",
                    "action_id": self.active_action_id,
                    "status": "refused",
                    "reason": "lost_stream_non_json",
                    "host_mutation": False,
                }
            if isinstance(event, dict):
                self.record(event)
        proc.wait(timeout=5)


class Handler(SimpleHTTPRequestHandler):
    server: LiveVmWebServer

    def log_message(self, format: str, *args: str) -> None:
        if not self.server.args.once:
            super().log_message(format, *args)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/status":
            self.send_json(HTTPStatus.OK, self.server.state.snapshot())
            return
        if path == "/api/events":
            self.send_events()
            return
        if path == "/favicon.ico" or path == "/favicon.svg":
            self.send_file(self.server.args.app_root / "favicon.svg", "image/svg+xml")
            return
        if path == "/" or path == "/index.html":
            root_html = self.server.args.authoritative_html if self.server.args.authoritative_html.exists() else self.server.args.app_root / "index.html"
            self.send_file(root_html, "text/html; charset=utf-8")
            return
        if path == "/source.html":
            self.send_file(self.server.args.app_root / "index.html", "text/html; charset=utf-8")
            return
        if path.startswith("/design/"):
            rel = path[len("/design/"):]
            self.send_static(self.server.args.design_root, rel)
            return
        self.send_static(self.server.args.app_root, path.lstrip("/"))

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        action = {
            "/api/action/run": "run",
            "/api/action/rollback": "rollback",
            "/api/action/stop": "stop",
        }.get(parsed.path)
        if action is None:
            self.send_json(HTTPStatus.NOT_FOUND, self.server.state.bridge_refusal(parsed.path, "unknown_bridge_endpoint"))
            return
        auth_error = self.bridge_auth_error()
        if auth_error is not None:
            self.send_json(HTTPStatus.FORBIDDEN, self.server.state.bridge_refusal(action, auth_error))
            return
        # Body is intentionally ignored: browser clients cannot submit arbitrary daemon JSON.
        status, payload = self.server.state.start_action(action)
        self.send_json(status, payload)

    def bridge_auth_error(self) -> str | None:
        nonce = self.headers.get("X-ZigScheduler-Bridge-Nonce", "")
        if nonce != self.server.state.bridge_nonce:
            return "invalid_or_missing_bridge_nonce"
        origin = self.headers.get("Origin")
        if origin is None:
            return "missing_bridge_origin"
        if origin != self.server.state.allowed_origin:
            return "origin_mismatch"
        return None

    def send_events(self) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        index = 0
        deadline = time.monotonic() + (0.8 if self.server.args.once else 3600 * 24)
        while time.monotonic() < deadline:
            with self.server.state.lock:
                while index >= len(self.server.state.events) and time.monotonic() < deadline:
                    self.server.state.lock.wait(timeout=0.25)
                events = self.server.state.events[index:]
                index = len(self.server.state.events)
            for event in events:
                try:
                    self.wfile.write(b"data: ")
                    self.wfile.write(json.dumps(event, sort_keys=True).encode("utf-8"))
                    self.wfile.write(b"\n\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return
            if self.server.args.once and index > 0:
                return

    def send_static(self, root: Path, rel: str) -> None:
        clean = posixpath.normpath("/" + rel).lstrip("/")
        if clean.startswith("../") or clean == "..":
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        target = (root / clean).resolve()
        root_resolved = root.resolve()
        if root_resolved not in target.parents and target != root_resolved:
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        if target.is_dir():
            target = target / "index.html"
        ctype = CONTENT_TYPES.get(target.suffix, "text/plain; charset=utf-8")
        self.send_file(target, ctype)

    def send_file(self, path: Path, ctype: str) -> None:
        try:
            data = path.read_bytes()
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, status: int, payload: JsonObject) -> None:
        data = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


class LiveVmWebServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], args: Args) -> None:
        super().__init__(server_address, Handler)
        self.args = args
        self.state = LiveVmWebState(args)


def parse_args(argv: list[str]) -> Args:
    parser = argparse.ArgumentParser(description="Serve the browser live microVM lab UI")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--app-root", default="web/live-vm-lab")
    parser.add_argument("--design-root", default="design")
    parser.add_argument("--authoritative-html", default="authoritative-final-design.html")
    parser.add_argument("--state-dir", default=".omo/evidence/live-vm-web")
    parser.add_argument("--daemon-bin", default="zig-out/bin/zig-scheduler-daemon")
    parser.add_argument("--once", action="store_true", help="serve one request loop for smoke tests")
    ns = parser.parse_args(argv)
    return Args(
        host=ns.host,
        port=ns.port,
        app_root=Path(ns.app_root),
        design_root=Path(ns.design_root),
        authoritative_html=Path(ns.authoritative_html),
        state_dir=Path(ns.state_dir),
        daemon_bin=Path(ns.daemon_bin),
        once=ns.once,
    )


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if not (args.app_root / "index.html").exists():
        print(f"missing web app root: {args.app_root}", file=sys.stderr)
        return 2
    if not args.design_root.exists():
        print(f"missing design root: {args.design_root}", file=sys.stderr)
        return 2
    server = LiveVmWebServer((args.host, args.port), args)
    server.state.allowed_origin = f"http://{args.host}:{server.server_port}"
    url = f"http://{args.host}:{server.server_port}/"
    print(f"live VM lab browser UI: {url}", flush=True)
    print("mode=vm-lab-only host_mutation=false production_ready=false", flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        print("live VM lab browser UI interrupted", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
