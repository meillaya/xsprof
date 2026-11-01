#!/bin/sh
# Measure the recorder's real retention behavior on a disposable Linux VM.
# This is a developer/VM gate: it starts a recorder as root, runs a positive
# workload, and reports events/s, bytes/event, RSS, loss, and the window that
# the configured byte budget actually retains.
#
# Usage: qa/retention_bench.sh [duration_ms] [workers] [max_bytes] [yes|sleep]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
DURATION_MS=${1:-60000}
WORKERS=${2:-2}
MAX_BYTES=${3:-2G}
WORKLOAD=${4:-yes}
BASE=${XSPROF_BENCH_DIR:-/var/tmp}
STATE=$(mktemp -d "$BASE/xsprof-retention.XXXXXX")
WORK_PIDS=""

say() { printf '%s\n' "retention_bench: $*"; }
fail() { say "FAIL: $*" >&2; exit 1; }
cleanup() {
    for pid in $WORK_PIDS; do kill "$pid" >/dev/null 2>&1 || true; done
    wait >/dev/null 2>&1 || true
    if [ "${KEEP:-0}" = 1 ]; then
        say "kept state $STATE"
    else
        rm -rf "$STATE"
    fi
}
trap cleanup EXIT HUP INT TERM

[ "$(uname -s)" = Linux ] || fail "Linux only"
[ "$(id -u)" = 0 ] || fail "run as root on a disposable VM"
[ -x "$BIN" ] || fail "missing binary: $BIN"
"$BIN" doctor --json >/dev/null 2>&1 || fail "doctor did not exit zero"
if ! "$BIN" doctor --json 2>/dev/null | grep -q '"name":"perf","reason":"[^"]*","state":"READY"'; then
    fail "perf is not READY; CAP_PERFMON and readable tracefs are required"
fi

mkdir -p "$STATE"
case "$WORKLOAD" in
    yes) ;;
    sleep) ;;
    *) fail "workload must be yes or sleep" ;;
esac
i=0
while [ "$i" -lt "$WORKERS" ]; do
    if [ "$WORKLOAD" = yes ]; then
        yes >/dev/null &
    else
        (while :; do sleep 0.001; done) >/dev/null &
    fi
    WORK_PIDS="$WORK_PIDS $!"
    i=$((i + 1))
done

say "duration=${DURATION_MS}ms workers=$WORKERS workload=$WORKLOAD max_bytes=$MAX_BYTES state=$STATE"
"$BIN" daemon --foreground --dir "$STATE" --retain 10m --max-bytes "$MAX_BYTES" \
    --duration "$DURATION_MS" >"$STATE/daemon-result.json" 2>"$STATE/daemon.err" || {
    cat "$STATE/daemon.err" >&2
    fail "daemon failed"
}
"$BIN" history --last "${DURATION_MS}ms" --dir "$STATE" >"$STATE/history-result.json" 2>/dev/null || true

python3 - "$STATE" "$DURATION_MS" "$WORKERS" "$WORKLOAD" <<'PY'
import json, pathlib, re, sys

state = pathlib.Path(sys.argv[1])
duration_ms = int(sys.argv[2])
workers = int(sys.argv[3])
workload = sys.argv[4]
result = json.loads((state / "daemon-result.json").read_text())
manifest = json.loads((state / "manifest.json").read_text())
history = None
history_path = state / "history-result.json"
if history_path.exists():
    try:
        history = json.loads(history_path.read_text())
    except Exception:
        history = None

retained_bytes = 0
retained_events = 0
oldest = None
newest = 0
sample_loss = 0
lost_events = 0
retention_loss = 0
for segment in manifest.get("segments", []):
    retained_bytes += int(segment.get("bytes", 0))
    retained_events += int(segment.get("events", 0))
    start = int(segment.get("start_wall_ns", 0))
    end = int(segment.get("end_wall_ns", 0)) or int(manifest.get("updated_wall_ns", 0))
    if start:
        oldest = start if oldest is None else min(oldest, start)
    newest = max(newest, end)
    path = state / segment.get("path", "")
    try:
        for line in path.read_text(errors="replace").splitlines():
            if '"sample_loss' in line:
                sample_loss += 1
                match = re.search(r'(?:lost|dropped)=(\d+)', line)
                if match:
                    lost_events += int(match.group(1))
            if '"retention_loss' in line:
                retention_loss += 1
    except OSError:
        pass

covered_s = 0.0
if oldest is not None and newest > oldest:
    covered_s = (newest - oldest) / 1e9
events_per_s = float(result.get("events_per_sec", 0) or 0)
bytes_per_event = retained_bytes / retained_events if retained_events else 0.0
budget = int(manifest.get("max_bytes", 0))
projected_s = (budget / (bytes_per_event * events_per_s)) if bytes_per_event and events_per_s else 0.0
print(json.dumps({
    "bytes_per_event": round(bytes_per_event, 2),
    "covered_s": round(covered_s, 2),
    "duration_ms": duration_ms,
    "events": result.get("events", 0),
    "events_per_sec": result.get("events_per_sec", 0),
    "history_events": history["totals"]["events"] if history else 0,
    "history_lost_events": history["totals"]["lost"] if history else 0,
    "history_sidecars": history["sidecars"] if history else 0,
    "loss_markers_retained": sample_loss,
    "lost_events_retained": lost_events,
    "max_bytes": budget,
    "overhead_bp": result.get("overhead_bp", 0),
    "projected_budget_window_s": round(projected_s, 2),
    "retained_bytes": retained_bytes,
    "retained_events": retained_events,
    "retention_loss_markers": retention_loss,
    "rss_kb": result.get("rss_kb", 0),
    "schema": "xsprof/retention-bench/v1",
    "state": result.get("state", ""),
    "workers": workers,
    "workload": workload,
}, sort_keys=True))
PY
