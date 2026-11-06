#!/bin/sh
# Service-level smoke for the packaged recorder shape. Run this as root on a
# disposable Linux VM with systemd and a readable tracefs. It creates a
# transient unit with the same properties as packaging/systemd/xsprof-recorder.service,
# records for a bounded time, kills a session, and checks recovery.
#
# The script never changes perf_event_paranoid or tracefs policy. CAP_PERFMON
# must already work (checked through `xsprof doctor --json`).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
UNIT=xsprof-service-smoke
STATE_NAME=xsprof-service-smoke
STATE_DIR=/var/lib/$STATE_NAME
BIN_DIR=/usr/local/libexec/xsprof-service-smoke
SERVICE_USER=${XSPROF_SERVICE_USER:-xsprof}
CREATED_USER=0
SEGMENTS=0

say() { printf '%s\n' "service_smoke: $*"; }
fail() { say "FAIL: $*" >&2; exit 1; }

cleanup() {
    systemctl stop "$UNIT" >/dev/null 2>&1 || true
    systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR" "$BIN_DIR"
    if [ "$CREATED_USER" = 1 ]; then
        userdel "$SERVICE_USER" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT HUP INT TERM

[ "$(uname -s)" = Linux ] || fail "Linux only"
[ "$(id -u)" = 0 ] || fail "run as root on a disposable VM"
command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
[ "$(cat /proc/1/comm)" = systemd ] || fail "PID 1 is not systemd"
[ -x "$BIN" ] || fail "missing binary: $BIN (build first)"
"$BIN" doctor --json >/dev/null 2>&1 || fail "doctor did not exit zero"
if ! "$BIN" doctor --json 2>/dev/null | grep -q '"name":"perf","reason":"[^"]*","state":"READY"'; then
    fail "perf is not READY; CAP_PERFMON and readable tracefs are required"
fi

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    CREATED_USER=1
fi
install -d -m 0755 "$BIN_DIR"
install -m 0755 "$BIN" "$BIN_DIR/xsprof"
rm -rf "$STATE_DIR"
systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true

wait_state() { # state timeout-tenths
    i=0
    while [ "$i" -lt "$2" ]; do
        if [ -f "$STATE_DIR/manifest.json" ] &&
            grep -q "\"state\":\"$1\"" "$STATE_DIR/manifest.json"; then
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

wait_events() { # timeout-tenths
    i=0
    while [ "$i" -lt "$1" ]; do
        if [ -s "$STATE_DIR/manifest.json" ] &&
            grep -q '"events":[1-9]' "$STATE_DIR/manifest.json"; then
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

wait_inactive() {
    i=0
    while [ "$i" -lt "$1" ]; do
        if ! systemctl is-active --quiet "$UNIT"; then return 0; fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

start_unit() { # duration-ms
    systemd-run --unit="$UNIT" \
        --property=Type=simple \
        --property="User=$SERVICE_USER" \
        --property="Group=$SERVICE_USER" \
        --property=AmbientCapabilities="CAP_PERFMON CAP_DAC_READ_SEARCH" \
        --property=CapabilityBoundingSet="CAP_PERFMON CAP_DAC_READ_SEARCH" \
        --property=NoNewPrivileges=yes \
        --property=ProtectSystem=strict \
        --property=ProtectHome=yes \
        --property=PrivateTmp=yes \
        --property=ReadOnlyPaths="/sys/kernel/tracing /sys/kernel/debug/tracing" \
        --property="StateDirectory=$STATE_NAME" \
        "$BIN_DIR/xsprof" daemon --foreground --dir "$STATE_DIR" \
        --retain 10m --max-bytes 64M --duration "$1" >/dev/null
}

# Phase 1: packaged service shape records, holds the lock, stops cleanly.
start_unit 4000
wait_state recording 100 || fail "service did not enter recording state"
if ! systemctl is-active --quiet "$UNIT"; then fail "service was not active"; fi
wait_events 100 || fail "manifest records no events"
if TMP_OUT=$(mktemp); then
    if "$BIN_DIR/xsprof" daemon --foreground --dir "$STATE_DIR" --duration 200 \
        >"$TMP_OUT" 2>&1; then
        rm -f "$TMP_OUT"
        fail "second recorder acquired the state lock"
    fi
    grep -q 'another recorder holds the state lock' "$TMP_OUT" ||
        fail "concurrent daemon did not report the lock refusal"
    rm -f "$TMP_OUT"
else
    fail "mktemp failed"
fi

wait_inactive 120 || fail "service did not stop after --duration"
wait_state stopped 40 || fail "manifest did not reach stopped"
grep -q '"raw_codec":"compact_v1"' "$STATE_DIR/manifest.json" || fail "manifest raw_codec missing"
"$BIN" capture --last 10m --dir "$STATE_DIR" --out "$STATE_DIR/phase1.ndjson" ||
    fail "capture failed after the service stopped"
grep -q 'capture_stop' "$STATE_DIR/phase1.ndjson" || fail "capture_stop marker missing"
if grep -q 'capture_corrupt\|capture_truncated_tail' "$STATE_DIR/phase1.ndjson"; then
    fail "clean service extraction emitted a gap marker"
fi
"$BIN" verify --dir "$STATE_DIR" --json >"$STATE_DIR/verify.json" ||
    fail "verify failed on the clean service state"
grep -q '"state":"READY"' "$STATE_DIR/verify.json" || fail "verify state is not READY"
ls "$STATE_DIR"/metrics/*.json >/dev/null 2>&1 || fail "metrics sidecar missing"
SEGMENTS=$(ls "$STATE_DIR"/segments/*.xsraw | wc -l)
[ "$SEGMENTS" -ge 1 ] || fail "no segments written"

# Extraction stays canonical and read-only.
OUT=$STATE_DIR/extract.ndjson
"$BIN" capture --last 1m --dir "$STATE_DIR" --out "$OUT"
LINES=$(wc -l <"$OUT" | tr -d ' ')
[ "$LINES" -ge 100 ] || fail "capture --last returned only $LINES lines"
grep -v '"host_mutation":false' "$OUT" >/dev/null && fail "extract omitted host_mutation=false"
grep -q '"event":"sched_switch"' "$OUT" || fail "extract has no sched_switch rows"
"$BIN" watch --once --dir "$STATE_DIR" --window 1m >"$STATE_DIR/watch.txt" ||
    fail "watch --once failed"
grep -q 'CPU' "$STATE_DIR/watch.txt" || fail "watch output has no CPU rows"

# Phase 2: SIGKILL leaves a stale manifest; the next service start recovers it
# without discarding the earlier segment history.
systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
start_unit 10000
wait_state recording 100 || fail "restart phase did not reach recording"
systemctl kill -s KILL "$UNIT"
wait_inactive 40 || fail "killed unit did not stop"
systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
start_unit 1200
wait_state recording 100 || fail "recovery start did not record"
wait_inactive 120 || fail "recovery service did not stop"
wait_state stopped 40 || fail "recovery manifest did not reach stopped"
RECOVERED=$STATE_DIR/recovered.ndjson
"$BIN" capture --last 10m --dir "$STATE_DIR" --out "$RECOVERED"
grep -q 'capture_interrupted previous_session=' "$RECOVERED" ||
    fail "recovery marker missing after SIGKILL"
SEGMENTS=$(ls "$STATE_DIR"/segments/*.xsraw | wc -l)
[ "$SEGMENTS" -ge 2 ] || fail "recovery discarded earlier segments"
grep -q 'capture_interrupted\|capture_truncated_tail' "$RECOVERED" ||
    fail "recovery gap marker missing"
say "PASS (${SEGMENTS} segments, ${LINES} extracted lines)"