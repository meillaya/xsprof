from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Final

from microvm_report_types import JsonObject, JsonValue, ReportEnv, ReportIds, ReportRows, SerialLines, TimeoutEnv
from workload_execution_check import WorkloadExecutionError, require_workload_pass, workload_execution_events

JSON_MARKER: Final[str] = "ZIGSCHED_JSON "
SHA256_RE: Final[re.Pattern[str]] = re.compile(r"^[0-9a-f]{64}$")
UNAVAILABLE_DIGESTS: Final[frozenset[str]] = frozenset({"", "missing", "none", "null", "unavailable", "unknown"})
REQUIRED_EVENTS: Final[tuple[str, ...]] = (
    "boot",
    "tuple",
    "workload",
    "before",
    "register",
    "unregister",
    "stale_target_refusal",
    "duplicate_rollback_refusal",
)
MUTATION_FAMILIES: Final[tuple[str, ...]] = ("cgroup.weight", "cpu.max", "uclamp", "topology.offline_cpu")


def load_timeout_env() -> TimeoutEnv:
    return TimeoutEnv(
        out=Path(os.environ["OUT_DIR"]),
        git_sha=os.environ["GIT_SHA"],
        git_dirty=os.environ["GIT_DIRTY"] == "true",
        started_at=os.environ["STARTED_AT"],
        kernel_image=os.environ["KERNEL_IMAGE"],
        qemu_bin=os.environ["QEMU_BIN"],
        qemu_scan_before=os.environ["QEMU_SCAN_BEFORE"],
        qemu_scan_after=os.environ["QEMU_SCAN_AFTER"],
        qemu_rc=int(os.environ["QEMU_RC"]),
    )


def load_report_env() -> ReportEnv:
    return ReportEnv(
        out=Path(os.environ["OUT_DIR"]),
        serial=Path(os.environ["SERIAL"]),
        object_sha=os.environ["OBJECT_SHA"],
        object_file=os.environ["OBJECT_FILE"],
        meta_file=os.environ["META_FILE"],
        git_sha=os.environ["GIT_SHA"],
        git_dirty=os.environ["GIT_DIRTY"] == "true",
        started_at=os.environ["STARTED_AT"],
        kernel_image=os.environ["KERNEL_IMAGE"],
        qemu_bin=os.environ["QEMU_BIN"],
        qemu_scan_before=os.environ["QEMU_SCAN_BEFORE"],
        qemu_scan_after=os.environ["QEMU_SCAN_AFTER"],
        qemu_rc=int(os.environ["QEMU_RC"]),
        dirty_snapshot_sha=os.environ.get("ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA", ""),
    )


def parse_serial(text: str) -> tuple[ReportRows, SerialLines]:
    rows: list[JsonObject] = []
    register_lines: list[str] = []
    bpftool_lines: list[str] = []
    duplicate_lines: list[str] = []
    for line in text.splitlines():
        idx = line.find(JSON_MARKER)
        if idx >= 0:
            raw = json.loads(line[idx + len(JSON_MARKER) :])
            if not isinstance(raw, dict):
                raise SystemExit("microVM JSON event root is not object")
            rows.append(raw)
        if "REGISTER_OUT " in line:
            register_lines.append(line.split("REGISTER_OUT ", 1)[1])
        if "BPFT_VER " in line:
            bpftool_lines.append(line.split("BPFT_VER ", 1)[1])
        if "DUPLICATE_UNREGISTER_OUT " in line:
            duplicate_lines.append(line.split("DUPLICATE_UNREGISTER_OUT ", 1)[1])
    return require_rows(rows), SerialLines(register=register_lines, bpftool=bpftool_lines, duplicate=duplicate_lines)


def require_rows(rows: list[JsonObject]) -> ReportRows:
    by_event = {str(row.get("event")): row for row in rows}
    for required in REQUIRED_EVENTS:
        if required not in by_event:
            raise SystemExit(f"missing microVM event: {required}")
    workload_execution_rows = tuple(row for row in rows if row.get("event") == "workload_execution")
    mutation_rows = tuple(row for row in rows if row.get("event") == "mutation_family")
    observed_families = {str(row.get("family")) for row in mutation_rows}
    missing_families = sorted(set(MUTATION_FAMILIES) - observed_families)
    if missing_families:
        raise SystemExit("missing microVM mutation family evidence: " + ", ".join(missing_families))
    result = ReportRows(
        boot=by_event["boot"],
        tuple_row=by_event["tuple"],
        workload=by_event["workload"],
        workload_executions=workload_execution_rows,
        mutation_rows=mutation_rows,
        before=by_event["before"],
        register=by_event["register"],
        unregister=by_event["unregister"],
        stale_refusal=by_event["stale_target_refusal"],
        duplicate_refusal=by_event["duplicate_rollback_refusal"],
    )
    validate_rows(result)
    return result


def validate_rows(rows: ReportRows) -> None:
    if not rows.workload_executions:
        raise SystemExit("missing microVM workload_execution evidence")
    serial_text = "".join("ZIGSCHED_JSON " + json.dumps(row, sort_keys=True) + "\n" for row in rows.workload_executions)
    try:
        for scenario in {event.scenario for event in workload_execution_events(serial_text)}:
            require_workload_pass(serial_text, scenario)
    except WorkloadExecutionError as exc:
        raise SystemExit(f"microVM workload execution did not pass: {exc}") from exc
    if rows.register.get("rc") != 0 or rows.register.get("ops") != "zigsched_minimal":
        raise SystemExit("microVM attach did not enable zigsched_minimal")
    if rows.unregister.get("rc") != 0 or rows.unregister.get("state") != "disabled":
        raise SystemExit("microVM rollback did not restore disabled state")
    if rows.stale_refusal.get("status") != "REFUSE" or int(rows.stale_refusal.get("rc", 0)) == 0:
        raise SystemExit("microVM stale target refusal did not refuse")
    if rows.stale_refusal.get("refusal_path") != "refuse_stale_rollback_target":
        raise SystemExit("microVM stale target refusal did not use the VM refusal path")
    if rows.duplicate_refusal.get("status") != "REFUSE" or int(rows.duplicate_refusal.get("rc", 0)) == 0:
        raise SystemExit("microVM duplicate rollback refusal did not refuse")
    if not rows.tuple_row.get("btf"):
        raise SystemExit("microVM kernel BTF missing")
    for mutation in rows.mutation_rows:
        if mutation.get("status") != "PASS":
            raise SystemExit(f"microVM mutation family did not pass: {mutation.get('family')}")
        if mutation.get("target_allowlisted") is not True:
            raise SystemExit(f"microVM mutation target not allowlisted: {mutation.get('family')}")
        if mutation.get("rollback_restored") is not True:
            raise SystemExit(f"microVM mutation rollback did not restore: {mutation.get('family')}")


def report_ids(env: ReportEnv, rows: ReportRows) -> ReportIds:
    import hashlib

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    suffix = hashlib.sha256((env.git_sha + env.object_sha + str(rows.register.get("id"))).encode()).hexdigest()[:6]
    active = str(rows.stale_refusal.get("active_target") or "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope")
    refused = str(rows.stale_refusal.get("refused_target") or "/sys/fs/cgroup/zig-scheduler-lab.slice/stale.scope")
    return ReportIds(
        audit_id=f"AUD-{stamp}-{env.git_sha[:7]}-{suffix}",
        audit_suffix=suffix,
        rollback_id=f"RB-microvm-live-{rows.register.get('id')}",
        active_target=active,
        refused_target=refused,
    )


def fact(value: JsonValue, default: str = "unavailable") -> JsonObject:
    text_value = str(value if value not in (None, "") else default)
    return {"status": "unknown" if text_value == "unavailable" else "present", "value": text_value}


def observed_bool(row: JsonObject, field: str, source: str) -> bool:
    value = row.get(field)
    if not isinstance(value, bool):
        raise SystemExit(f"microVM sample {source} missing observed boolean {field}")
    return value


def observed_digest(row: JsonObject, source: str) -> str:
    value = row.get("cgroup_membership_digest")
    if not isinstance(value, str) or not SHA256_RE.match(value) or value == "0" * 64 or value.lower() in UNAVAILABLE_DIGESTS:
        raise SystemExit(f"microVM sample {source} missing observed sha256 cgroup digest")
    return value


def observed_cgroup_status(row: JsonObject, source: str) -> str:
    value = row.get("cgroup_membership_status")
    if value != "present":
        raise SystemExit(f"microVM sample {source} did not observe cgroup membership")
    return "present"


def counter_fact(events_text: str, name: str) -> JsonObject:
    match = re.search(rf"(?:^|[^A-Za-z0-9_]){re.escape(name)}\s*[:=]\s*([0-9]+)", events_text)
    if match is None:
        return {"status": "unknown", "value": "unavailable"}
    return {"status": "present", "value": match.group(1)}
