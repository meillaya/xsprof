#!/usr/bin/env python3
# noqa: SIZE_OK - shared JSON helpers are extracted; remaining code is one end-to-end desktop/live-VM evidence harness.
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Final, assert_never

from live_vm_json_helpers import (
    JsonBoundaryError,
    JsonObject,
    JsonValue,
    json_artifact_suffix,
    load_json_object,
    load_json_value,
    parse_json_value_text,
    read_jsonl_objects,
    rewrite_json_strings,
)

REAL_ROOT: Final = Path(".omo/evidence/task-09-real-vm")
QEMU_MISSING_ROOT: Final = Path(".omo/evidence/task-09-qemu-missing")
REQUIRED_EVENTS: Final = {
    "stage_started": "queued",
    "microvm_boot": "PASS",
    "bpf_register": "PASS",
    "runtime_sample": "PASS",
    "rollback": "PASS",
    "cleanup": "PASS",
    "validation": "PASS",
}

@dataclass(frozen=True, slots=True)
class Args:
    app: Path
    real_vm: bool
    state_dir: Path
    force_qemu_missing: bool
    timeout_seconds: int


def parse_args(argv: list[str]) -> Args:
    parser = argparse.ArgumentParser(description="Task 9 real-VM desktop bridge/e2e evidence harness")
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--real-vm", action="store_true", help="run actual zig-scheduler-daemon VM-lab bridge")
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=REAL_ROOT / "state",
        help=f"state directory for the desktop executable (default: {REAL_ROOT / 'state'})",
    )
    parser.add_argument("--force-qemu-missing", action="store_true")
    parser.add_argument("--timeout-seconds", type=int, default=240)
    ns = parser.parse_args(argv)
    if not ns.real_vm and not ns.force_qemu_missing:
        parser.error("--real-vm is required unless --force-qemu-missing is used")
    return Args(
        app=ns.app,
        real_vm=bool(ns.real_vm),
        state_dir=ns.state_dir,
        force_qemu_missing=bool(ns.force_qemu_missing),
        timeout_seconds=int(ns.timeout_seconds),
    )


class HarnessError(Exception):
    pass


class Harness:
    def __init__(self, args: Args) -> None:
        self.args = args
        self.root = QEMU_MISSING_ROOT if args.force_qemu_missing else REAL_ROOT
        self.root.mkdir(parents=True, exist_ok=True)
        args.state_dir.mkdir(parents=True, exist_ok=True)
        self.action_log = self.root / "action-log.jsonl"
        self.action_log.write_text("")

    def log(self, event: str, **fields: JsonValue) -> None:
        row: JsonObject = {"ts": utc_now(), "event": event, "host_mutation": False, **fields}
        with self.action_log.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")

    def command(self, label: str, extra: list[str], timeout: int | None = None) -> subprocess.CompletedProcess[str]:
        cmd = [str(self.args.app), "--state-dir", self.args.state_dir.as_posix(), *extra]
        self.log("command_start", label=label, command=cmd, timeout_seconds=timeout or self.args.timeout_seconds)
        started = time.monotonic()
        env = os.environ.copy()
        env["ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA"] = dirty_snapshot_hash()
        result = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout or self.args.timeout_seconds, check=False, env=env)
        elapsed_ms = int((time.monotonic() - started) * 1000)
        (self.root / f"{label}.stdout.txt").write_text(result.stdout, encoding="utf-8")
        (self.root / f"{label}.stderr.txt").write_text(result.stderr, encoding="utf-8")
        self.log("command_end", label=label, exit_code=result.returncode, elapsed_ms=elapsed_ms)
        return result

    def run(self) -> int:
        if not self.args.app.exists():
            raise HarnessError(f"missing app: {self.args.app}")
        if self.args.force_qemu_missing:
            return self.run_forced_missing()
        return self.run_real_vm()

    def run_forced_missing(self) -> int:
        result = self.command("forced-qemu-missing-preflight", ["--bridge-test", "real-lab-preflight", "--force-qemu-missing"], timeout=30)
        skip = QEMU_MISSING_ROOT / "skip.json"
        if result.returncode != 0:
            raise HarnessError(f"forced qemu-missing preflight exited {result.returncode}")
        data = load_json(skip)
        if data.get("status") != "SKIP" or data.get("host_mutation") is not False:
            raise HarnessError("forced qemu-missing skip.json is not fail-closed SKIP host_mutation=false")
        missing = data.get("missing")
        if not isinstance(missing, list) or "trusted_qemu-system-x86_64" not in missing:
            raise HarnessError("forced qemu-missing skip.json lacks exact trusted_qemu-system-x86_64 reason")
        self.write_bridge_evidence("SKIP", "forced qemu missing path wrote implementation-owned skip.json")
        print(f"SKIP forced qemu missing artifact={skip} host_mutation=false")
        return 0

    def run_real_vm(self) -> int:
        preflight = self.command("preflight", ["--bridge-test", "real-lab-preflight"], timeout=45)
        if preflight.returncode != 0:
            raise HarnessError(f"real-lab preflight command failed: {preflight.returncode}")
        reset_state_dir(self.args.state_dir)
        reset_lab_output_dir(Path("evidence/lab/run-all/desktop-run-1"))
        self.log("state_reset", state_dir=self.args.state_dir.as_posix(), lab_output_dir="evidence/lab/run-all/desktop-run-1", reason="avoid stale duplicate action ids and reused lab output before real run")
        preflight_json = load_json(REAL_ROOT / "preflight.json") if (REAL_ROOT / "preflight.json").exists() else None
        if not preflight_json or preflight_json.get("status") != "PASS":
            self.write_bridge_evidence("SKIP", "host missing real VM tuple; Task 9 cannot complete on this host")
            print("SKIP real VM tuple unavailable; host_mutation=false", file=sys.stderr)
            return 77

        run = self.command("run", ["--bridge-test", "real-lab-run"], timeout=self.args.timeout_seconds)
        if run.returncode != 0:
            raise HarnessError(f"real-lab run did not PASS; command exit={run.returncode}")
        self.assert_pass_receipts()
        bundle = self.copy_and_rewrite_bundle()
        self.write_provenance(bundle, {})
        validator_results = self.run_validators(bundle)
        provenance = self.write_provenance(bundle, validator_results)
        self.write_bridge_evidence("PASS", "deterministic desktop bridge e2e drove real-lab preflight/run through desktop executable", bundle, provenance)
        print(f"PASS live-vm-desktop-e2e artifact={REAL_ROOT} bundle={bundle} provenance={provenance} host_mutation=false")
        return 0

    def assert_pass_receipts(self) -> None:
        run_json = load_json(REAL_ROOT / "run.json")
        if run_json.get("status") != "PASS" or run_json.get("host_mutation") is not False:
            raise HarnessError("run.json is not PASS host_mutation=false")
        events = read_jsonl(REAL_ROOT / "events.jsonl")
        for event, status in REQUIRED_EVENTS.items():
            if not any(row.get("event") == event and row.get("status") == status for row in events):
                raise HarnessError(f"missing required event/status: {event} {status}")
        if any(row.get("host_mutation") is not False for row in events):
            raise HarnessError("events.jsonl contains host_mutation not false")
        for name in ("rollback-receipt.json", "cleanup-receipt.json"):
            receipt = load_json(REAL_ROOT / name)
            if receipt.get("host_mutation") is not False:
                raise HarnessError(f"{name} does not assert host_mutation=false")

    def copy_and_rewrite_bundle(self) -> Path:
        source = find_source_bundle(REAL_ROOT / "events.jsonl")
        target = REAL_ROOT / "copied-live-bundle"
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target)
        rewrite_artifact_paths(target, source.as_posix(), target.as_posix())
        refresh_recorded_hashes(target)
        validate_copied_bundle(target / "summary.json", target)
        self.log("bundle_copied", source=source.as_posix(), target=target.as_posix())
        return target / "summary.json"

    def run_validators(self, bundle: Path) -> JsonObject:
        checks = {
            "live_bundle_freshness_check": ["python3", "qa/live_bundle_freshness_check.py", "--bundle", bundle.as_posix()],
            "live_behavior_check": ["python3", "qa/live_behavior_check.py", "--bundle", bundle.as_posix()],
            "lab_summary_observe": ["python3", "qa/lab_summary_observe.py", "--summary", (bundle.parent / "observe-partial" / "summary.json").as_posix()],
            "partial_attach_check": ["python3", "qa/partial_attach_check.py", "--evidence", (bundle.parent / "partial-attach" / "partial-attach-evidence.json").as_posix()],
        }
        results: JsonObject = {}
        for name, cmd in checks.items():
            result = subprocess.run(cmd, text=True, capture_output=True, timeout=60, check=False)
            (REAL_ROOT / f"validator-{name}.stdout.txt").write_text(result.stdout, encoding="utf-8")
            (REAL_ROOT / f"validator-{name}.stderr.txt").write_text(result.stderr, encoding="utf-8")
            results[name] = {"command": cmd, "exit_code": result.returncode, "status": "PASS" if result.returncode == 0 else "FAIL"}
            if result.returncode != 0:
                raise HarnessError(f"validator failed: {name}")
        (REAL_ROOT / "validator-results.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return results

    def write_provenance(self, bundle: Path, validators: JsonObject) -> Path:
        head = git_text(["rev-parse", "HEAD"])
        status = git_text(["status", "--porcelain=v1"])
        snapshot = dirty_snapshot_hash()
        command = [str(self.args.app), "--state-dir", self.args.state_dir.as_posix(), "--bridge-test", "real-lab-run"]
        manifest: JsonObject = {
            "schema": "zig-scheduler/task-09-provenance/v1",
            "status": "PASS",
            "created_at": utc_now(),
            "repo_head": head,
            "git_dirty": bool(status.strip()),
            "git_status_porcelain": status.splitlines(),
            "dirty_tree_snapshot_sha256": snapshot,
            "source_reference": "uncommitted worktree content" if status.strip() else "clean git HEAD",
            "command": command,
            "state_dir": self.args.state_dir.as_posix(),
            "copied_bundle_summary": bundle.as_posix(),
            "copied_bundle_paths_validated": True,
            "validators": validators,
            "host_mutation": False,
            "production_ready": False,
        }
        path = REAL_ROOT / "manifest-provenance.json"
        path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return path

    def write_bridge_evidence(self, status: str, detail: str, bundle: Path | None = None, provenance: Path | None = None) -> None:
        evidence: JsonObject = {
            "schema": "zig-scheduler/task-09-desktop-bridge-e2e/v1",
            "status": status,
            "detail": detail,
            "created_at": utc_now(),
            "desktop_executable": self.args.app.as_posix(),
            "state_dir": self.args.state_dir.as_posix(),
            "action_log": self.action_log.as_posix(),
            "evidence_kind": "deterministic desktop bridge evidence",
            "bridge_methods": ["real-lab-preflight", "real-lab-run"],
            "window_screenshot_replacement": "No raw browser/server fixture is used; this invokes the Zig-owned desktop executable bridge-test surface that the WebView host delegates to for controller actions.",
            "host_mutation": False,
            "production_ready": False,
        }
        if bundle is not None:
            evidence["copied_bundle_summary"] = bundle.as_posix()
        if provenance is not None:
            evidence["provenance"] = provenance.as_posix()
        (self.root / "desktop-bridge-evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def reset_lab_output_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)


def reset_state_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load_json(path: Path) -> JsonObject:
    try:
        return load_json_object(path)
    except JsonBoundaryError as exc:
        raise HarnessError(str(exc)) from exc


def read_jsonl(path: Path) -> list[JsonObject]:
    try:
        return read_jsonl_objects(path)
    except JsonBoundaryError as exc:
        raise HarnessError(str(exc)) from exc


def load_json_artifact(path: Path) -> JsonValue:
    try:
        return load_json_value(path)
    except JsonBoundaryError as exc:
        raise HarnessError(str(exc)) from exc


def load_json_line(path: Path, line: str) -> JsonValue:
    try:
        return parse_json_value_text(line, path.as_posix())
    except JsonBoundaryError as exc:
        raise HarnessError(str(exc)) from exc


def find_source_bundle(events_path: Path) -> Path:
    for row in read_jsonl(events_path):
        artifact = row.get("artifact")
        if isinstance(artifact, str) and artifact.endswith("summary.json") and Path(artifact).exists():
            return Path(artifact).parent
    raise HarnessError("events.jsonl does not reference an existing lab summary bundle")


def rewrite_artifact_paths(root: Path, old_prefix: str, new_prefix: str) -> None:
    for path in sorted(root.rglob("*")):
        match json_artifact_suffix(path):
            case ".json":
                rewritten = rewrite_json_strings(load_json_artifact(path), old_prefix, new_prefix)
                path.write_text(json.dumps(rewritten, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            case ".jsonl":
                rows: list[JsonValue] = []
                for line in path.read_text(encoding="utf-8").splitlines():
                    if not line.strip():
                        continue
                    rows.append(rewrite_json_strings(load_json_line(path, line), old_prefix, new_prefix))
                path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")
            case None:
                continue
            case unreachable:
                assert_never(unreachable)

def refresh_recorded_hashes(bundle_root: Path) -> None:
    for path in sorted(root_json_artifacts(bundle_root)):
        match json_artifact_suffix(path):
            case ".json":
                refreshed = refresh_hashes_in_value(load_json_artifact(path), bundle_root)
                path.write_text(json.dumps(refreshed, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            case ".jsonl":
                rows: list[JsonValue] = []
                for line in path.read_text(encoding="utf-8").splitlines():
                    if not line.strip():
                        continue
                    rows.append(refresh_hashes_in_value(load_json_line(path, line), bundle_root))
                path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")
            case None:
                continue
            case unreachable:
                assert_never(unreachable)


def refresh_hashes_in_value(value: JsonValue, bundle_root: Path) -> JsonValue:
    if isinstance(value, list):
        return [refresh_hashes_in_value(item, bundle_root) for item in value]
    if not isinstance(value, dict):
        return value
    rewritten: JsonObject = {key: refresh_hashes_in_value(child, bundle_root) for key, child in value.items()}
    for key, current in list(rewritten.items()):
        if not key.endswith("_sha256") or not isinstance(current, str):
            continue
        path_key = key.removesuffix("_sha256")
        raw_path = rewritten.get(path_key)
        if isinstance(raw_path, str):
            target = Path(raw_path)
            if is_inside_bundle(target, bundle_root) and target.is_file():
                rewritten[key] = sha256_file(target)
    return rewritten


def validate_copied_bundle(summary_path: Path, bundle_root: Path) -> None:
    validate_summary_paths(summary_path, bundle_root)
    stale_prefix = "evidence/lab/run-all/desktop-run-1"
    for path in root_json_artifacts(bundle_root):
        text = path.read_text(encoding="utf-8")
        if stale_prefix in text:
            raise HarnessError(f"copied bundle artifact still references stale source path: {path}")
        validate_json_artifact(path, bundle_root)


def validate_json_artifact(path: Path, bundle_root: Path) -> None:
    if path.suffix == ".json":
        validate_paths_and_hashes(load_json_artifact(path), bundle_root, path)
        return
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if line.strip():
            validate_paths_and_hashes(load_json_line(path, line), bundle_root, path, line_no=line_no)


def validate_paths_and_hashes(value: JsonValue, bundle_root: Path, source: Path, *, line_no: int | None = None) -> None:
    if isinstance(value, list):
        for item in value:
            validate_paths_and_hashes(item, bundle_root, source, line_no=line_no)
        return
    if not isinstance(value, dict):
        return
    for key, child in value.items():
        if key in {"artifact_paths"} and isinstance(child, list):
            for item in child:
                if isinstance(item, str):
                    require_bundle_file(item, bundle_root, source, key, line_no)
        elif key in {"output_dir"} and isinstance(child, str):
            if Path(child) != bundle_root:
                raise HarnessError(f"{source_ref(source, line_no)} {key} does not point at copied bundle")
        elif key in {"vm_execution_manifest", "transcript_path", "rollback_snapshot", "transcript", "qemu_process_scan_before", "qemu_process_scan_after"} and isinstance(child, str):
            require_bundle_file(child, bundle_root, source, key, line_no)
        validate_paths_and_hashes(child, bundle_root, source, line_no=line_no)
    for key, found in value.items():
        if not key.endswith("_sha256") or not isinstance(found, str):
            continue
        path_key = key.removesuffix("_sha256")
        raw_path = value.get(path_key)
        if isinstance(raw_path, str):
            target = Path(raw_path)
            if is_inside_bundle(target, bundle_root) and target.is_file():
                actual = sha256_file(target)
                if found != actual:
                    raise HarnessError(f"{source_ref(source, line_no)} {key} mismatch for {raw_path}")


def validate_summary_paths(summary_path: Path, bundle_root: Path) -> None:
    summary = load_json(summary_path)
    if summary.get("output_dir") != bundle_root.as_posix():
        raise HarnessError("copied summary output_dir does not match copied bundle directory")
    paths: list[str] = []
    artifact_paths = summary.get("artifact_paths")
    if isinstance(artifact_paths, list):
        paths.extend(path for path in artifact_paths if isinstance(path, str))
    cleanup = summary.get("cleanup")
    if isinstance(cleanup, dict):
        for key in ("qemu_process_scan_before", "qemu_process_scan_after"):
            value = cleanup.get(key)
            if isinstance(value, str):
                paths.append(value)
    manifest = summary.get("vm_execution_manifest")
    if isinstance(manifest, str):
        paths.append(manifest)
    for raw in paths:
        require_bundle_file(raw, bundle_root, summary_path, "summary path", None)


def require_bundle_file(raw: str, bundle_root: Path, source: Path, field: str, line_no: int | None) -> None:
    path = Path(raw)
    if path.is_absolute() or ".." in path.parts or not path.exists():
        raise HarnessError(f"{source_ref(source, line_no)} has unsafe/missing internal path {field}: {raw}")
    if not is_inside_bundle(path, bundle_root):
        raise HarnessError(f"{source_ref(source, line_no)} path is not under copied bundle dir {field}: {raw}")


def is_inside_bundle(path: Path, bundle_root: Path) -> bool:
    return bundle_root in (path, *path.parents)


def root_json_artifacts(bundle_root: Path) -> list[Path]:
    return sorted([*bundle_root.rglob("*.json"), *bundle_root.rglob("*.jsonl")])


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_ref(path: Path, line_no: int | None) -> str:
    if line_no is None:
        return path.as_posix()
    return f"{path.as_posix()}:{line_no}"


def git_text(args: list[str]) -> str:
    result = subprocess.run(["git", *args], check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise HarnessError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def dirty_snapshot_hash() -> str:
    h = hashlib.sha256()
    for cmd in (["git", "status", "--porcelain=v1", "-z"], ["git", "diff", "--binary", "HEAD", "--"]):
        result = subprocess.run(cmd, check=False, capture_output=True)
        if result.returncode != 0:
            raise HarnessError(f"snapshot command failed: {' '.join(cmd)}")
        h.update(b"\0CMD\0" + " ".join(cmd).encode() + b"\0")
        h.update(result.stdout)
    other = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "-z"], check=False, capture_output=True)
    if other.returncode != 0:
        raise HarnessError("git ls-files --others failed")
    for raw in sorted(filter(None, other.stdout.split(b"\0"))):
        path = Path(raw.decode())
        if not path.is_file():
            continue
        h.update(b"\0UNTRACKED\0" + raw + b"\0")
        h.update(hashlib.sha256(path.read_bytes()).hexdigest().encode())
    return h.hexdigest()


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    harness = Harness(args)
    try:
        return harness.run()
    except subprocess.TimeoutExpired as exc:
        harness.log("timeout", command=exc.cmd, timeout_seconds=exc.timeout, outcome="FAIL")
        print(f"FAIL live-vm-desktop-e2e timeout: {exc}", file=sys.stderr)
        return 124
    except HarnessError as exc:
        harness.log("fail", outcome="FAIL", detail=str(exc))
        print(f"FAIL live-vm-desktop-e2e: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
