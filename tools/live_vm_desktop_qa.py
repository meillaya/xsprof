#!/usr/bin/env python3
# noqa: SIZE_OK - OS-level GUI acceptance harness remains one window/process/evidence scenario runner after JSON helper extraction.
# /// script
# requires-python = ">=3.11"
# ///
# ─── How to run ───
# xvfb-run -a python3 tools/live_vm_desktop_qa.py --app zig-out/bin/zig-scheduler-live-vm-desktop --fake-daemon --scenario smoke
# xvfb-run -a python3 tools/live_vm_desktop_qa.py --app zig-out/bin/zig-scheduler-live-vm-desktop --fake-daemon --scenario duplicate-stale
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Literal, TypedDict, assert_never

EVIDENCE_DIR: Final = Path(".omo/evidence/task-07-desktop-fake")
RUNS_DIR: Final = EVIDENCE_DIR / "runs"
WINDOW_TITLE: Final = "live microVM lab"
FAKE_DAEMON: Final = Path("tools/tui_pty_authoritative_daemon.py")
Scenario = Literal["smoke", "duplicate-stale", "full"]
Outcome = Literal["PASS", "SKIP", "FAIL"]
SMOKE_SCREENSHOTS: Final = ("00-hero.png", "01-running.png", "02-theme.png", "03-help.png")
DUPLICATE_SCREENSHOTS: Final = ("10-duplicate-refusal.png", "11-stale-refusal.png")
STATE_FILES: Final = ("events.jsonl", "window-state.jsonl", "dom-debug.jsonl", "desktop-offline.html", "authoritative-debug.log")


class DesktopQaError(Exception):
    """Typed domain failure for desktop QA harness operations."""


class LogRow(TypedDict, total=False):
    ts_ms: int
    event: str
    outcome: Outcome
    detail: str
    command: list[str]
    path: str
    window_id: str
    assertion: str
    expected: str
    actual: str
    missing: list[str]
    exit_code: int
    display: str
    gdk_backend: str
    webkit_disable_compositing: str
    libgl_always_software: str
    webkit_disable_dmabuf: str
    gsk_renderer: str
    method: str
    bytes: int


@dataclass(frozen=True, slots=True)
class Args:
    app: Path
    fake_daemon: bool
    scenario: Scenario
    allow_skip: bool


@dataclass(slots=True)  # noqa: MUTABLE_OK - owns process lifecycle during QA cleanup.
class Harness:
    args: Args
    run_dir: Path
    state_dir: Path
    action_log: Path
    scenario_log: Path
    app_stdout: Path
    app_stderr: Path
    proc: subprocess.Popen[str] | None = None

    def log(self, row: LogRow) -> None:
        data: LogRow = {"ts_ms": int(time.time() * 1000), **row}
        encoded = json.dumps(data, sort_keys=True) + "\n"
        for path in (self.action_log, self.scenario_log):
            with path.open("a", encoding="utf-8") as handle:
                _ = handle.write(encoded)

    def skip(self, detail: str, missing: list[str] | None = None) -> int:
        row: LogRow = {"event": "skip", "outcome": "SKIP", "detail": detail}
        if missing is not None:
            row["missing"] = missing
        self.log(row)
        print(f"SKIP live-vm-desktop-qa: {detail}")
        return 0 if self.args.allow_skip else 1

    def fail(self, detail: str) -> int:
        self.log({"event": "fail", "outcome": "FAIL", "detail": detail})
        print(f"FAIL live-vm-desktop-qa: {detail}", file=sys.stderr)
        return 1

    def launch(self) -> None:
        command = [str(self.args.app), "--state-dir", str(self.state_dir)]
        if self.args.fake_daemon:
            command.extend(["--fake-daemon", str(FAKE_DAEMON)])
        self.log({"event": "launch", "command": command})
        self.app_stdout.parent.mkdir(parents=True, exist_ok=True)
        out = self.app_stdout.open("w", encoding="utf-8")
        err = self.app_stderr.open("w", encoding="utf-8")
        try:
            env = os.environ.copy()
            if env.get("DISPLAY"):
                _ = env.setdefault("GDK_BACKEND", "x11")
                _ = env.setdefault("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
                _ = env.setdefault("LIBGL_ALWAYS_SOFTWARE", "1")
                _ = env.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
                _ = env.setdefault("GSK_RENDERER", "cairo")
            self.log({"event": "environment", "display": env.get("DISPLAY", ""), "gdk_backend": env.get("GDK_BACKEND", ""), "webkit_disable_compositing": env.get("WEBKIT_DISABLE_COMPOSITING_MODE", ""), "libgl_always_software": env.get("LIBGL_ALWAYS_SOFTWARE", ""), "webkit_disable_dmabuf": env.get("WEBKIT_DISABLE_DMABUF_RENDERER", ""), "gsk_renderer": env.get("GSK_RENDERER", "")})
            self.proc = subprocess.Popen(command, stdout=out, stderr=err, text=True, start_new_session=True, env=env)
        finally:
            out.close()
            err.close()

    def cleanup(self) -> None:
        if self.proc is None:
            return
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
                _ = self.proc.wait(timeout=2)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    self.log({"event": "cleanup-sigkill-missing", "detail": "process group already exited before SIGKILL"})
                _ = self.proc.wait(timeout=2)
        self.log({"event": "cleanup", "exit_code": int(self.proc.returncode or 0)})


def usage() -> str:
    return "usage: live_vm_desktop_qa.py --app APP [--fake-daemon] --scenario {smoke,duplicate-stale,full} [--allow-skip]"


def parse_scenario(raw: str) -> Scenario:
    match raw:  # noqa: MATCH_OK - open CLI string parser rejects unknown values before returning a Scenario literal.
        case "smoke":
            return "smoke"
        case "duplicate-stale":
            return "duplicate-stale"
        case "full":
            return "full"
        case _:
            print(usage(), file=sys.stderr)
            print(f"live_vm_desktop_qa.py: error: invalid --scenario: {raw}", file=sys.stderr)
            raise SystemExit(2)


def parse_args(argv: list[str]) -> Args:
    app: Path | None = None
    scenario: Scenario | None = None
    fake_daemon = False
    allow_skip = False
    index = 0
    while index < len(argv):
        token = argv[index]
        match token:  # noqa: MATCH_OK - open CLI token parser rejects unknown arguments with usage text.
            case "--app":
                index += 1
                if index >= len(argv):
                    print(usage(), file=sys.stderr)
                    print("live_vm_desktop_qa.py: error: --app requires a value", file=sys.stderr)
                    raise SystemExit(2)
                app = Path(argv[index])
            case "--scenario":
                index += 1
                if index >= len(argv):
                    print(usage(), file=sys.stderr)
                    print("live_vm_desktop_qa.py: error: --scenario requires a value", file=sys.stderr)
                    raise SystemExit(2)
                scenario = parse_scenario(argv[index])
            case "--fake-daemon":
                fake_daemon = True
            case "--allow-skip":
                allow_skip = True
            case "-h" | "--help":
                print(usage())
                raise SystemExit(0)
            case _:
                print(usage(), file=sys.stderr)
                print(f"live_vm_desktop_qa.py: error: unknown argument: {token}", file=sys.stderr)
                raise SystemExit(2)
        index += 1
    if app is None:
        print(usage(), file=sys.stderr)
        print("live_vm_desktop_qa.py: error: --app is required", file=sys.stderr)
        raise SystemExit(2)
    if scenario is None:
        print(usage(), file=sys.stderr)
        print("live_vm_desktop_qa.py: error: --scenario is required", file=sys.stderr)
        raise SystemExit(2)
    return Args(app=app, fake_daemon=fake_daemon, scenario=scenario, allow_skip=allow_skip)


def require_tools() -> list[str]:
    missing = [name for name in ("xdotool",) if shutil.which(name) is None]
    if shutil.which("import") is None and (shutil.which("xwd") is None or shutil.which("convert") is None):
        missing.append("ImageMagick import or xwd+convert window capture")
    if os.environ.get("DISPLAY", "") == "":
        missing.append("DISPLAY (run under xvfb-run -a or another X server)")
    return missing


def run_cmd(command: list[str], timeout: float = 5.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True, timeout=timeout)


def wait_for_window(harness: Harness) -> str | None:
    deadline = time.monotonic() + 8
    last = ""
    while time.monotonic() < deadline:
        if harness.proc is not None and harness.proc.poll() is not None:
            stdout = harness.app_stdout.read_text(encoding="utf-8", errors="replace")[-500:]
            stderr = harness.app_stderr.read_text(encoding="utf-8", errors="replace")[-500:]
            harness.log({"event": "app-exited", "exit_code": int(harness.proc.returncode or 0), "actual": stdout + stderr})
            return None
        result = run_cmd(["xdotool", "search", "--name", WINDOW_TITLE], timeout=1)
        if result.returncode == 0:
            time.sleep(1.2)
            ids = [line.strip() for line in result.stdout.splitlines() if line.strip()]
            if ids:
                return ids[-1]
        last = result.stderr.strip()
        time.sleep(0.15)
    harness.log({"event": "window-timeout", "detail": last})
    return None


def activate(window_id: str) -> None:
    _ = run_cmd(["xdotool", "windowactivate", "--sync", window_id], timeout=2)


def key(window_id: str, keysym: str) -> None:
    activate(window_id)
    _ = run_cmd(["xdotool", "key", "--window", window_id, keysym], timeout=2)
    time.sleep(0.8)


def window_geometry(window_id: str) -> tuple[int, int, int, int] | None:
    result = run_cmd(["xdotool", "getwindowgeometry", "--shell", window_id], timeout=2)
    if result.returncode != 0:
        return None
    values: dict[str, int] = {}
    for line in result.stdout.splitlines():
        if "=" not in line:
            continue
        key, raw = line.split("=", 1)
        if key in {"X", "Y", "WIDTH", "HEIGHT"}:
            try:
                values[key] = int(raw)
            except ValueError:
                return None
    if all(key in values for key in ("X", "Y", "WIDTH", "HEIGHT")):
        return values["X"], values["Y"], values["WIDTH"], values["HEIGHT"]
    return None


def screenshot(harness: Harness, window_id: str, name: str) -> Path:
    target = harness.run_dir / name
    activate(window_id)
    time.sleep(0.8)
    geometry = window_geometry(window_id)
    if geometry is None:
        raise DesktopQaError(f"cannot resolve target window geometry for {window_id}")
    if shutil.which("import") is not None:
        result = run_cmd(["import", "-window", window_id, str(target)], timeout=8)
        method = "imagemagick-import-window-id"
    elif shutil.which("xwd") is not None and shutil.which("convert") is not None:
        xwd_path = target.with_suffix(".xwd")
        xwd = run_cmd(["xwd", "-silent", "-id", window_id, "-out", str(xwd_path)], timeout=8)
        if xwd.returncode == 0:
            result = run_cmd(["convert", str(xwd_path), str(target)], timeout=8)
            xwd_path.unlink(missing_ok=True)
        else:
            result = xwd
        method = "xwd-window-id-convert"
    else:
        raise DesktopQaError("missing concrete X11 window capture API: ImageMagick import or xwd+convert")
    if result.returncode != 0:
        raise DesktopQaError(result.stderr.strip() or f"screenshot failed for {name}")
    harness.log({"event": "screenshot", "path": str(target), "window_id": window_id, "method": method, "actual": f"geometry={geometry[0]},{geometry[1]} {geometry[2]}x{geometry[3]}"})
    return target


def window_title(window_id: str) -> str:
    result = run_cmd(["xdotool", "getwindowname", window_id], timeout=2)
    return result.stdout.strip()


def screenshot_probe(harness: Harness, path: Path) -> bool:
    if not path.exists() or path.stat().st_size <= 0:
        harness.log({"event": "assert", "outcome": "FAIL", "assertion": "screenshot_nonempty", "path": str(path)})
        return False
    if shutil.which("identify") is not None:
        result = run_cmd(["identify", "-format", "%wx%h", str(path)], timeout=3)
        ok = result.returncode == 0 and "x" in result.stdout
        harness.log({"event": "assert", "outcome": "PASS" if ok else "FAIL", "assertion": "target_window_screenshot_dimensions", "path": str(path), "actual": result.stdout.strip() or result.stderr.strip()})
        return ok
    harness.log({"event": "assert", "outcome": "PASS", "assertion": "screenshot_nonempty", "path": str(path), "bytes": path.stat().st_size})
    return True


def assert_image_changed(harness: Harness, before: Path, after: Path, label: str) -> bool:
    if shutil.which("compare") is None:
        harness.log({"event": "assert", "outcome": "FAIL", "assertion": label, "detail": "missing ImageMagick compare"})
        return False
    result = run_cmd(["compare", "-metric", "AE", str(before), str(after), "null:"], timeout=5)
    metric = (result.stderr or result.stdout).strip()
    try:
        changed = int(metric.split()[0]) > 0
    except (IndexError, ValueError):
        changed = False
    harness.log({"event": "assert", "outcome": "PASS" if changed else "FAIL", "assertion": label, "actual": metric})
    return changed


def read_text_file(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def wait_for_file_marker(harness: Harness, path: Path, marker: str, label: str) -> str:
    deadline = time.monotonic() + 6
    text = read_text_file(path)
    while time.monotonic() < deadline:
        text = read_text_file(path)
        if marker.lower() in text.lower():
            harness.log({"event": "state-marker", "outcome": "PASS", "assertion": label, "expected": marker, "path": str(path), "actual": text[-800:]})
            return text
        time.sleep(0.15)
    harness.log({"event": "state-marker", "outcome": "FAIL", "assertion": label, "expected": marker, "path": str(path), "actual": text[-800:]})
    return text


def assert_marker(harness: Harness, marker: str, text: str, label: str) -> bool:
    ok = marker.lower() in text.lower()
    harness.log({"event": "assert", "outcome": "PASS" if ok else "FAIL", "assertion": label, "expected": marker, "actual": text[-800:]})
    return ok


def smoke(harness: Harness, window_id: str) -> int:
    state_dir = harness.state_dir
    dom_path = state_dir / "dom-debug.jsonl"
    window_state_path = state_dir / "window-state.jsonl"
    events_path = state_dir / "events.jsonl"
    hero = screenshot(harness, window_id, "00-hero.png")
    key(window_id, "m")
    _ = wait_for_file_marker(harness, events_path, "runtime_sample", "controller_event_history_run")
    _ = wait_for_file_marker(harness, window_state_path, "qa_state=running", "controller_rendered_state_run")
    running = screenshot(harness, window_id, "01-running.png")
    key(window_id, "w")
    _ = wait_for_file_marker(harness, window_state_path, "qa_state=theme_key", "window_rendered_theme_key")
    theme = screenshot(harness, window_id, "02-theme.png")
    key(window_id, "question")
    _ = wait_for_file_marker(harness, window_state_path, "qa_state=help_key", "window_rendered_help_key")
    help_shot = screenshot(harness, window_id, "03-help.png")
    rendered = all(screenshot_probe(harness, path) for path in (hero, running, theme, help_shot))
    rendered = rendered and assert_image_changed(harness, running, theme, "theme_key_changes_target_window_pixels")
    rendered = rendered and assert_image_changed(harness, theme, help_shot, "help_key_changes_target_window_pixels")
    proof = "\n".join([read_text_file(dom_path), read_text_file(window_state_path), read_text_file(events_path)])
    expected = ["live microVM lab", "daemon event stream", "host_mutation=false", "FAIL-CLOSED", "qa_state=running", "controller_status=accepted", "runtime_sample"]
    missing = [marker for marker in expected if not assert_marker(harness, marker, proof, "window_state_layer_and_controller_history")]
    if not rendered:
        missing.append("real window screenshot dimensions")
    if missing:
        return harness.fail("missing required WebView/controller markers: " + ", ".join(missing))
    print("PASS live-vm-desktop smoke: real window screenshots, rendered state layer, and controller event history captured")
    return 0


def duplicate_stale(harness: Harness, window_id: str) -> int:
    state_dir = harness.state_dir
    events_path = state_dir / "events.jsonl"
    window_state_path = state_dir / "window-state.jsonl"
    key(window_id, "m")
    _ = wait_for_file_marker(harness, events_path, "runtime_sample", "controller_event_history_initial_run")
    key(window_id, "m")
    _ = wait_for_file_marker(harness, events_path, "duplicate_action_id", "controller_event_history_duplicate")
    _ = wait_for_file_marker(harness, window_state_path, "qa_state=duplicate_refusal", "controller_rendered_duplicate")
    dup = screenshot(harness, window_id, "10-duplicate-refusal.png")
    key(window_id, "b")
    _ = wait_for_file_marker(harness, events_path, "stale_or_unknown_target_action_id", "controller_event_history_stale")
    _ = wait_for_file_marker(harness, window_state_path, "qa_state=stale_refusal", "controller_rendered_stale")
    stale = screenshot(harness, window_id, "11-stale-refusal.png")
    rendered = all(screenshot_probe(harness, path) for path in (dup, stale))
    proof = "\n".join([read_text_file(window_state_path), read_text_file(events_path)])
    markers = ("qa_state=duplicate_refusal", "cause=duplicate_run_action", "duplicate_action_id", "qa_state=stale_refusal", "stale_or_unknown_target_action_id", "controller_source=event_history", "host_mutation=false")
    missing = [marker for marker in markers if not assert_marker(harness, marker, proof, "controller_backed_duplicate_stale")]
    if not rendered:
        missing.append("real duplicate/stale screenshot dimensions")
    if missing:
        return harness.fail("missing duplicate/stale controller-backed markers: " + ", ".join(missing))
    print("PASS live-vm-desktop duplicate-stale: controller-backed refusal screenshots and event history captured")
    return 0


def scenario_screenshots(scenario: Scenario) -> tuple[str, ...]:
    match scenario:
        case "smoke":
            return SMOKE_SCREENSHOTS
        case "duplicate-stale":
            return DUPLICATE_SCREENSHOTS
        case "full":
            return SMOKE_SCREENSHOTS + DUPLICATE_SCREENSHOTS
        case unreachable:
            assert_never(unreachable)


def create_harness(args: Args) -> Harness:
    EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    stamp = f"{int(time.time() * 1000)}-{os.getpid()}-{args.scenario}"
    run_dir = RUNS_DIR / stamp
    state_dir = run_dir / f"state-{args.scenario}"
    run_dir.mkdir(parents=True, exist_ok=False)
    state_dir.mkdir(parents=True, exist_ok=True)
    return Harness(
        args=args,
        run_dir=run_dir,
        state_dir=state_dir,
        action_log=run_dir / "action-log.jsonl",
        scenario_log=run_dir / f"{args.scenario}-action-log.jsonl",
        app_stdout=run_dir / "app.stdout",
        app_stderr=run_dir / "app.stderr",
    )


def normalized_log_text(harness: Harness, path: Path) -> str:
    text = read_text_file(path)
    return text.replace(str(harness.state_dir), str(EVIDENCE_DIR / f"state-{harness.args.scenario}")).replace(str(harness.run_dir), str(EVIDENCE_DIR))


def replace_file(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f".{target.name}.tmp")
    _ = shutil.copy2(source, tmp)
    os.replace(tmp, target)


def write_canonical_log(harness: Harness, source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f".{target.name}.tmp")
    _ = tmp.write_text(normalized_log_text(harness, source), encoding="utf-8")
    os.replace(tmp, target)


def replace_state_dir(harness: Harness) -> None:
    target = EVIDENCE_DIR / f"state-{harness.args.scenario}"
    tmp = EVIDENCE_DIR / f".state-{harness.args.scenario}.tmp"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True, exist_ok=True)
    for name in STATE_FILES:
        source = harness.state_dir / name
        if source.exists():
            _ = shutil.copy2(source, tmp / name)
    if target.exists():
        shutil.rmtree(target)
    os.replace(tmp, target)


def publish_success(harness: Harness) -> None:
    write_canonical_log(harness, harness.action_log, EVIDENCE_DIR / "action-log.jsonl")
    write_canonical_log(harness, harness.scenario_log, EVIDENCE_DIR / f"{harness.args.scenario}-action-log.jsonl")
    replace_file(harness.app_stdout, EVIDENCE_DIR / "app.stdout")
    replace_file(harness.app_stderr, EVIDENCE_DIR / "app.stderr")
    for name in scenario_screenshots(harness.args.scenario):
        replace_file(harness.run_dir / name, EVIDENCE_DIR / name)
    replace_state_dir(harness)
    harness.log({"event": "publish-success", "outcome": "PASS", "path": str(EVIDENCE_DIR), "detail": "canonical acceptance evidence refreshed after successful scenario"})


def retain_negative_run(harness: Harness, detail: str) -> None:
    receipt = harness.run_dir / "negative-run-retained.txt"
    _ = receipt.write_text(f"canonical acceptance artifacts not modified\nscenario={harness.args.scenario}\ndetail={detail}\n", encoding="utf-8")


def run_scenario(harness: Harness) -> int:
    harness.launch()
    window_id = wait_for_window(harness)
    if window_id is None:
        return harness.fail("desktop executable did not expose a real X11 window before timeout")
    harness.log({"event": "window-found", "window_id": window_id, "actual": window_title(window_id)})
    match harness.args.scenario:
        case "smoke":
            return smoke(harness, window_id)
        case "duplicate-stale":
            return duplicate_stale(harness, window_id)
        case "full":
            if smoke(harness, window_id) != 0:
                return 1
            return duplicate_stale(harness, window_id)
        case unreachable:
            assert_never(unreachable)


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        if isinstance(exc.code, int):
            return exc.code
        return 1
    harness = create_harness(args)
    rc = 1
    accepted = False
    try:
        if not args.app.exists():
            rc = harness.fail(f"desktop app does not exist: {args.app}")
        else:
            missing = require_tools()
            if missing:
                rc = harness.skip("missing OS automation dependencies", missing)
            elif args.fake_daemon and not FAKE_DAEMON.exists():
                rc = harness.fail(f"reviewed fake daemon helper missing: {FAKE_DAEMON}")
            else:
                rc = run_scenario(harness)
                accepted = rc == 0
    except (OSError, subprocess.SubprocessError, RuntimeError, DesktopQaError) as exc:
        rc = harness.fail(f"automation error: {exc}")
    finally:
        harness.cleanup()
    if accepted:
        publish_success(harness)
    else:
        retain_negative_run(harness, f"rc={rc}")
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
