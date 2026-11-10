#!/bin/sh
# Bounded performance smoke: catches catastrophic regressions in the hot
# canonical paths (journal/metrics parse, why analysis, wire validation).
# This is a floor, not a micro-benchmark; thresholds are intentionally loose
# so shared runners do not flake. Root retention throughput stays in
# `qa/retention_bench.sh` (disposable KVM VM only).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}

require() {
    command -v "$1" >/dev/null 2>&1 || {
        if [ "${XSPROF_REQUIRE_TOOLS:-0}" = "1" ]; then
            echo "perf_smoke: required tool unavailable: $1" >&2
            exit 1
        fi
        echo "perf_smoke: SKIP ($1 unavailable)"
        exit 0
    }
}

require python3
[ -x "$BIN" ] || {
    echo "perf_smoke: binary not found: $BIN" >&2
    exit 1
}

python3 - "$BIN" "$ROOT" <<'PY'
import json
import os
import statistics
import subprocess
import sys
import time

binary, root = sys.argv[1], sys.argv[2]
fixture = os.path.join(root, "fixtures/real/scheduler-mix.ndjson")
healthy = os.path.join(root, "fixtures/ui/healthy.ndjson")

cases = [
    ("metrics", [binary, "metrics", "--input", fixture, "--json"], 1000.0),
    ("why", [binary, "why", "--input", fixture, "--json"], 1500.0),
    ("validate", [binary, "validate", "--schema", "event.v1", "--file", healthy, "--json"], 1000.0),
]

report = {}
failed = False
for name, command, limit_ms in cases:
    samples = []
    for _ in range(5):
        started = time.perf_counter()
        proc = subprocess.run(command, capture_output=True, text=True)
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        if proc.returncode != 0:
            print(f"perf_smoke: {name} exited {proc.returncode}: {proc.stderr[:300]}", file=sys.stderr)
            sys.exit(1)
        samples.append(elapsed_ms)
    median_ms = round(statistics.median(samples), 1)
    ok = median_ms <= limit_ms
    failed = failed or not ok
    report[name] = {"median_ms": median_ms, "limit_ms": limit_ms, "pass": ok}

print(json.dumps({"host_mutation": False, "schema": "xsprof/perf-smoke/v1", "cases": report}, separators=(",", ":"), sort_keys=True))
sys.exit(1 if failed else 0)
PY
