#!/bin/sh
# User-first quickstart smoke: the documented headless path must work from a
# clean checkout without root, perf permissions, or a display.
#
# Covers: version/help, why/metrics on a committed capture, schema validation,
# offscreen snapshot, and an incident bundle from a compact recorder state.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
[ -x "$BIN" ] || { echo "quickstart_smoke: binary not found: $BIN" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "quickstart_smoke: FAIL: $*" >&2; exit 1; }
note() { echo "quickstart_smoke: $*"; }

"$BIN" version | grep -q '^xsprof [0-9]' || fail "version line"
"$BIN" help >/dev/null || fail "help exits non-zero"

"$BIN" why --input "$ROOT/fixtures/real/scheduler-mix.ndjson" --json >"$TMP/why.json"
grep -q '"schema":"xsprof/why/v1"' "$TMP/why.json" || fail "why wire schema"
grep -q '"host_mutation":false' "$TMP/why.json" || fail "why host_mutation"

"$BIN" metrics --input "$ROOT/fixtures/real/scheduler-mix.ndjson" --json >"$TMP/metrics.json"
grep -q '"schema":"xsprof/metrics/v1"' "$TMP/metrics.json" || fail "metrics wire schema"

"$BIN" validate --schema event.v1 --file "$ROOT/fixtures/ui/healthy.ndjson" --json >"$TMP/validate.json"
grep -q '"ok":true' "$TMP/validate.json" || fail "validate rejected canonical evidence"
grep -q '"host_mutation":false' "$TMP/validate.json" || fail "validate host_mutation"

"$BIN" snapshot --demo-model "$ROOT/fixtures/ui/design/demo.json" --view home \
    --width 640 --height 360 --out "$TMP/home.png" >/dev/null
sig=$(od -An -tx1 -N8 "$TMP/home.png" | tr -d ' \n')
[ "$sig" = "89504e470d0a1a0a" ] || fail "snapshot is not a PNG"

# Recorder state: the incident workflow is the product's central user action.
# A tiny legacy NDJSON segment keeps this privilege-free and wall-aligned.
STATE="$TMP/state"
OUT="$TMP/incident"
mkdir -p "$STATE/segments"
cat >"$STATE/segments/0-0.ndjson" <<'EOF'
{"schema":"xsprof/event/v1","event":"marker","ts_ns":0,"cpu":-1,"pid":7,"tid":7,"comm":"xsprof","detail":"capture_owner","host_mutation":false}
{"schema":"xsprof/event/v1","event":"marker","ts_ns":0,"cpu":-1,"detail":"host_memory buddy_fragmentation=0.75","host_mutation":false}
{"schema":"xsprof/event/v1","event":"sched_switch","ts_ns":61000000000,"cpu":0,"pid":7,"tid":7,"a":9,"b":0,"c":0,"comm":"worker","host_mutation":false}
{"schema":"xsprof/event/v1","event":"sched_wakeup","ts_ns":61100000000,"cpu":0,"pid":7,"tid":7,"a":9,"comm":"worker","host_mutation":false}
{"schema":"xsprof/event/v1","event":"sched_wakeup","ts_ns":61200000000,"cpu":0,"pid":7,"tid":7,"a":9,"comm":"worker","host_mutation":false}
EOF
BODY_BYTES=$(wc -c <"$STATE/segments/0-0.ndjson" | tr -d ' ')
NOW_S=$(date +%s)
START_NS="$((NOW_S - 120))000000000"
END_NS="${NOW_S}000000000"
cat >"$STATE/manifest.json" <<EOF
{"host_mutation":false,"max_age_ms":600000,"max_bytes":2147483648,"schema":"xsprof/recorder-manifest/v1","segments":[{"bytes":$BODY_BYTES,"closed":true,"codec":"ndjson","end_mono_ns":70000000000,"end_wall_ns":$END_NS,"events":5,"path":"segments/0-0.ndjson","start_mono_ns":0,"start_wall_ns":$START_NS}],"session_id":"quickstart-smoke","started_mono_ns":0,"started_wall_ns":$START_NS,"state":"stopped","updated_wall_ns":$END_NS}
EOF
"$BIN" incident --last 60s --dir "$STATE" --out "$OUT" --max-window-bytes 1M >/dev/null
for artifact in window.ndjson summary.json report.html trace.json; do
    [ -s "$OUT/$artifact" ] || fail "incident missing $artifact"
done
grep -q '"schema":"xsprof/incident-summary/v1"' "$OUT/summary.json" || fail "incident summary schema"
grep -q '"host_mutation":false' "$OUT/summary.json" || fail "incident host_mutation"
if grep -Eq 'https?://' "$OUT/report.html"; then
    fail "incident report contains an external URL"
fi

"$BIN" doctor --json >"$TMP/doctor.json" 2>/dev/null || true
[ -s "$TMP/doctor.json" ] || fail "doctor produced no JSON"
grep -q '"host_mutation":false' "$TMP/doctor.json" || fail "doctor host_mutation"

note "PASS (headless quickstart: why, metrics, validate, snapshot, incident, doctor)"
