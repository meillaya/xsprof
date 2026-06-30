#!/usr/bin/env python3
"""Parse raw benchmark tool output into benchmark-output/v1 records."""
from __future__ import annotations

import math
from pathlib import Path
from typing import Literal

from qa.benchmark_output_io import load_json, read_text, sha256_file
from qa.benchmark_output_model import (
    CYCLIC_LINE_RE,
    PERF_GROUPS_RE,
    PERF_PROCS_RE,
    PERF_TIME_RE,
    SCHEMA,
    BenchmarkOutputError,
    CommandFamily,
    JsonObject,
    JsonValue,
    Status,
)
from qa.benchmark_output_privacy import safe_relative


def num(value: JsonValue, context: str) -> float:
    if isinstance(value, int | float) and not isinstance(value, bool) and math.isfinite(value) and value >= 0:
        return float(value)
    raise BenchmarkOutputError(f"{context} must be nonnegative number")


def tool_for(command_family: CommandFamily) -> Literal["cyclictest", "fio", "perf", "rtla"]:
    match command_family:  # noqa: MATCH_OK — CommandFamily Literal cases are exhausted; pyright reports assert_never default as unreachable.
        case "cyclictest":
            return "cyclictest"
        case "fio":
            return "fio"
        case "perf_bench_sched_messaging" | "perf_sched":
            return "perf"
        case "rtla":
            return "rtla"


def parse_cyclictest_json(data: JsonObject) -> tuple[JsonObject, JsonObject, int, int]:
    threads = data.get("thread")
    if not isinstance(threads, dict) or not threads:
        raise BenchmarkOutputError("cyclictest JSON missing thread metrics")
    cycles = mins = avgs = maxes = 0.0
    for label, row in threads.items():
        if not isinstance(row, dict):
            raise BenchmarkOutputError(f"cyclictest thread {label} must be object")
        cycles += num(row.get("cycles"), f"thread[{label}].cycles")
        mins += num(row.get("min"), f"thread[{label}].min")
        avgs += num(row.get("avg"), f"thread[{label}].avg")
        maxes = max(maxes, num(row.get("max"), f"thread[{label}].max"))
    count = len(threads)
    metrics: JsonObject = {"threads": count, "cycles": cycles, "latency_min_us_avg": mins / count, "latency_avg_us_avg": avgs / count, "latency_max_us": maxes}
    units: JsonObject = {"threads": "count", "cycles": "count", "latency_min_us_avg": "us", "latency_avg_us_avg": "us", "latency_max_us": "us"}
    return metrics, units, int(cycles), count


def parse_cyclictest_text(text: str) -> tuple[JsonObject, JsonObject, int, int]:
    rows = [match for match in (CYCLIC_LINE_RE.search(line) for line in text.splitlines()) if match is not None]
    if not rows:
        raise BenchmarkOutputError("cyclictest text missing latency rows")
    cycles = sum(float(row.group("cycles")) for row in rows)
    metrics: JsonObject = {"threads": len(rows), "cycles": cycles, "latency_min_us_avg": sum(float(row.group("min")) for row in rows) / len(rows), "latency_avg_us_avg": sum(float(row.group("avg")) for row in rows) / len(rows), "latency_max_us": max(float(row.group("max")) for row in rows)}
    units: JsonObject = {"threads": "count", "cycles": "count", "latency_min_us_avg": "us", "latency_avg_us_avg": "us", "latency_max_us": "us"}
    return metrics, units, int(cycles), len(rows)


def parse_fio(data: JsonObject) -> tuple[JsonObject, JsonObject, int, int]:
    jobs = data.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        raise BenchmarkOutputError("fio JSON missing jobs")
    metrics: JsonObject = {"jobs": len(jobs)}
    units: JsonObject = {"jobs": "count"}
    for op in ("read", "write"):
        iops = bw = lat = 0.0
        for index, job in enumerate(jobs):
            if not isinstance(job, dict):
                raise BenchmarkOutputError(f"fio job[{index}] missing")
            section_value = job.get(op)
            if not isinstance(section_value, dict):
                raise BenchmarkOutputError(f"fio job[{index}].{op} missing")
            iops += num(section_value.get("iops"), f"job[{index}].{op}.iops")
            bw += num(section_value.get("bw_bytes"), f"job[{index}].{op}.bw_bytes")
            lat_ns = section_value.get("lat_ns")
            if isinstance(lat_ns, dict):
                lat += num(lat_ns.get("mean"), f"job[{index}].{op}.lat_ns.mean")
        metrics[f"{op}_iops"] = iops
        metrics[f"{op}_bw_bytes"] = bw
        metrics[f"{op}_lat_ns_mean_avg"] = lat / len(jobs)
        units[f"{op}_iops"] = "iops"
        units[f"{op}_bw_bytes"] = "bytes_per_second"
        units[f"{op}_lat_ns_mean_avg"] = "ns"
    return metrics, units, len(jobs), len(jobs)


def parse_perf_messaging(text: str) -> tuple[JsonObject, JsonObject, int, int]:
    found = PERF_TIME_RE.search(text)
    if found is None:
        raise BenchmarkOutputError("perf bench sched messaging output missing total time")
    metrics: JsonObject = {"total_time_seconds": float(found.group("seconds"))}
    units: JsonObject = {"total_time_seconds": "seconds"}
    groups = PERF_GROUPS_RE.search(text)
    processes = PERF_PROCS_RE.search(text)
    if groups is not None:
        metrics["groups"] = float(groups.group("groups"))
        units["groups"] = "count"
    if processes is not None:
        metrics["processes"] = float(processes.group("processes"))
        units["processes"] = "count"
    return metrics, units, 1, 1


def parse_metrics(command_family: CommandFamily, input_path: Path) -> tuple[Status, JsonObject, JsonObject, int, int]:
    match command_family:  # noqa: MATCH_OK — CommandFamily Literal cases are exhausted; pyright reports assert_never default as unreachable.
        case "cyclictest":
            if input_path.suffix == ".json":
                metrics, units, samples, runs = parse_cyclictest_json(load_json(input_path))
            else:
                metrics, units, samples, runs = parse_cyclictest_text(read_text(input_path))
            return "RECORDED", metrics, units, samples, runs
        case "fio":
            metrics, units, samples, runs = parse_fio(load_json(input_path))
            return "RECORDED", metrics, units, samples, runs
        case "perf_bench_sched_messaging":
            metrics, units, samples, runs = parse_perf_messaging(read_text(input_path))
            return "RECORDED", metrics, units, samples, runs
        case "rtla" | "perf_sched":
            _ = read_text(input_path)
            return "UNSUPPORTED_DEFERRED", {}, {}, 0, 0


def build_record(command_family: CommandFamily, input_path: Path, output_path: str, vm_evidence: str) -> JsonObject:
    status, metrics, units, samples, runs = parse_metrics(command_family, input_path)
    return {"schema": SCHEMA, "status": status, "tool": tool_for(command_family), "command_family": command_family, "output_path": safe_relative(output_path, "output_path"), "output_sha256": sha256_file(input_path), "vm_evidence": safe_relative(vm_evidence, "vm_evidence"), "metrics": metrics, "units": units, "sample_count": samples, "run_count": runs, "host_mutation": False, "release_eligible": False, "production_capacity_claim": False, "hard_thresholds_enforced": False, "threshold_status": "record_only", "privacy_sanitized": True}
