#!/usr/bin/env python3
"""Self-tests for benchmark-output/v1 parser and validator behavior."""
from __future__ import annotations

import json
from pathlib import Path
from tempfile import TemporaryDirectory

from qa.benchmark_output_model import BenchmarkOutputError, JsonObject, JsonValue
from qa.benchmark_output_parse import build_record
from qa.benchmark_output_validate import validate_record


def expect_reject_record(label: str, record: JsonObject, key: str, value: JsonValue) -> None:
    bad = dict(record)
    bad[key] = value
    try:
        validate_record(bad)
    except BenchmarkOutputError as exc:
        print(f"PASS reject {label}: {exc}")
    else:
        raise BenchmarkOutputError(f"expected rejection did not occur: {label}")


def expect_reject_text(root: Path, label: str, text: str) -> None:
    claim = root / f"{label}.txt"
    _ = claim.write_text(f"Total time: 0.1 [sec]\nclaim: {text}\n")
    try:
        _ = build_record("perf_bench_sched_messaging", claim, "evidence/lab/run/bench/claim.txt", "evidence/lab/run/summary.json")
    except BenchmarkOutputError as exc:
        print(f"PASS reject {label}: {exc}")
    else:
        raise BenchmarkOutputError(f"expected claim rejection: {label}")


def expect_reject_raw_fio(root: Path, label: str, data: JsonObject) -> None:
    raw = root / f"{label}.json"
    _ = raw.write_text(json.dumps(data) + "\n")
    try:
        _ = build_record("fio", raw, "evidence/lab/run/bench/fio.json", "evidence/lab/run/summary.json")
    except BenchmarkOutputError as exc:
        print(f"PASS reject raw {label}: {exc}")
    else:
        raise BenchmarkOutputError(f"expected raw rejection: {label}")


def self_test() -> None:
    with TemporaryDirectory(prefix="zigsched-benchmark-output-") as tmp:
        root = Path(tmp)
        cyclic = root / "cyclictest.txt"
        _ = cyclic.write_text("T: 0 C: 10 Min: 1 Avg: 2 Max: 3\n")
        validate_record(build_record("cyclictest", cyclic, "evidence/lab/run/bench/cyclictest.txt", "evidence/lab/run/summary.json"))
        fio = root / "fio.json"
        _ = fio.write_text(json.dumps({"jobs": [{"read": {"iops": 1, "bw_bytes": 2, "lat_ns": {"mean": 3}}, "write": {"iops": 4, "bw_bytes": 5, "lat_ns": {"mean": 6}}}]}) + "\n")
        validate_record(build_record("fio", fio, "evidence/lab/run/bench/fio.json", "evidence/lab/run/summary.json"))
        raw = root / "perf.txt"
        _ = raw.write_text("# 2 groups == 80 processes run\nTotal time: 0.321 [sec]\n")
        record = build_record("perf_bench_sched_messaging", raw, "evidence/lab/run/bench/perf.txt", "evidence/lab/run/summary.json")
        validate_record(record)
        stress_ng = root / "stress-ng.txt"
        _ = stress_ng.write_text(
            "stress-ng: metrc: [123] stressor       bogo ops real time  usr time  sys time   bogo ops/s     bogo ops/s   bogo ops/s\n"
            "stress-ng: metrc: [123]                           (secs)    (secs)    (secs)   (real time) (usr+sys time)\n"
            "stress-ng: metrc: [123] cpu              2400      10.00     19.50      0.25       240.00        121.52\n"
        )
        validate_record(build_record("stress_ng", stress_ng, "evidence/lab/run/bench/stress-ng.txt", "evidence/lab/run/summary.json"))
        print("PASS accept supported parsers: cyclictest fio perf_bench_sched_messaging stress_ng")
        for label, key, value in (("host-mutation", "host_mutation", True), ("release", "release_eligible", True), ("production", "production_capacity_claim", True), ("threshold", "hard_thresholds_enforced", True), ("unsafe-path", "output_path", "/tmp/raw.txt")):
            expect_reject_record(label, record, key, value)
        metrics_value = record["metrics"]
        units_value = record["units"]
        if not isinstance(metrics_value, dict) or not isinstance(units_value, dict):
            raise BenchmarkOutputError("self-test record metrics/units must be objects")
        for label, key in (
            ("nested-access-token", "access_token"),
            ("nested-github-access-token", "github_access_token"),
            ("nested-camel-access-token", "accessToken"),
            ("nested-api-key", "apiKey"),
            ("nested-command-line", "commandLine"),
            ("nested-raw-debug", "rawDebug"),
            ("nested-release-eligible-score", "release_eligible_score"),
            ("nested-release-ready-score", "releaseReadyScore"),
            ("nested-production-ready", "production_ready"),
            ("nested-production-ready-score", "production_ready_score"),
            ("nested-threshold-pass-rate", "threshold_pass_rate"),
            ("compact-accesstoken", "accesstoken"),
            ("compact-githubaccesstoken", "githubaccesstoken"),
            ("compact-apikey", "apikey"),
            ("compact-commandline", "commandline"),
            ("compact-rawdebug", "rawdebug"),
            ("compact-productionready", "productionready"),
            ("compact-productionreadyscore", "productionreadyscore"),
            ("compact-releaseeligible", "releaseeligible"),
            ("compact-releaseeligiblescore", "releaseeligiblescore"),
            ("compact-thresholdpassrate", "thresholdpassrate"),
        ):
            bad = dict(record)
            metrics = dict(metrics_value)
            units = dict(units_value)
            metrics[key] = 1
            units[key] = "count"
            bad["metrics"] = metrics
            bad["units"] = units
            expect_reject_record(label, bad, "privacy_sanitized", True)
        nonfinite = dict(record)
        metrics = dict(metrics_value)
        metrics["total_time_seconds"] = float("inf")
        nonfinite["metrics"] = metrics
        try:
            validate_record(nonfinite)
        except BenchmarkOutputError as exc:
            print(f"PASS reject nonfinite metric: {exc}")
        else:
            raise BenchmarkOutputError("expected nonfinite metric rejection")
        for label, key in (
            ("raw-nested-access-token", "accessToken"),
            ("raw-nested-release-eligible-score", "release_eligible_score"),
            ("raw-nested-production-ready", "production_ready_score"),
            ("raw-nested-threshold-pass-rate", "threshold_pass_rate"),
            ("raw-compact-accesstoken", "accesstoken"),
            ("raw-compact-githubaccesstoken", "githubaccesstoken"),
            ("raw-compact-apikey", "apikey"),
            ("raw-compact-commandline", "commandline"),
            ("raw-compact-rawdebug", "rawdebug"),
            ("raw-compact-productionready", "productionready"),
            ("raw-compact-productionreadyscore", "productionreadyscore"),
            ("raw-compact-releaseeligible", "releaseeligible"),
            ("raw-compact-releaseeligiblescore", "releaseeligiblescore"),
            ("raw-compact-thresholdpassrate", "thresholdpassrate"),
        ):
            expect_reject_raw_fio(root, label, {"jobs": [{"read": {"iops": 1, "bw_bytes": 2, "lat_ns": {"mean": 3}}, "write": {"iops": 4, "bw_bytes": 5, "lat_ns": {"mean": 6}}, "provenance": {key: "redacted"}}]})
        expect_reject_raw_fio(root, "raw-infinity", {"jobs": [{"read": {"iops": float("inf"), "bw_bytes": 2, "lat_ns": {"mean": 3}}, "write": {"iops": 4, "bw_bytes": 5, "lat_ns": {"mean": 6}}}]})
        leak = root / "leak.txt"
        _ = leak.write_text("Total time: 0.1 [sec]\npassword=secret\n")
        try:
            _ = build_record("perf_bench_sched_messaging", leak, "evidence/lab/run/bench/leak.txt", "evidence/lab/run/summary.json")
        except BenchmarkOutputError as exc:
            print(f"PASS reject privacy: {exc}")
        else:
            raise BenchmarkOutputError("expected privacy rejection")
        for label, text in (
            ("release-hyphen", "release-eligible"), ("release-space-case", "Release Eligible"), ("release-underscore", "release_eligible"),
            ("production-hyphen", "production-capacity"), ("production-space-case", "Production Capacity"), ("production-underscore", "production_capacity"),
        ):
            expect_reject_text(root, label, text)
        deferred = root / "rtla.txt"
        _ = deferred.write_text("rtla timerlat summary redacted\n")
        validate_record(build_record("rtla", deferred, "evidence/lab/run/bench/rtla.txt", "evidence/lab/run/summary.json"))
        perf_sched = root / "perf-sched.txt"
        _ = perf_sched.write_text("perf sched summary redacted\n")
        validate_record(build_record("perf_sched", perf_sched, "evidence/lab/run/bench/perf-sched.txt", "evidence/lab/run/summary.json"))
        print("PASS accept deferred parsers: rtla perf_sched")
    print("PASS benchmark output self-test")
