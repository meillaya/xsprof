#!/bin/sh
# Privileged Linux gate for the real capture/recorder paths. Run as root in a
# disposable VM: it needs perf_event_open, tracefs, and systemd is not required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
[ -x "$BIN" ] || { echo "live_smoke: build first" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || { echo "live_smoke: Linux VM only" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "live_smoke: run as root" >&2; exit 1; }
TMP=$(mktemp -d)
cleanup() {
    if [ -n "${DAEMON_PID:-}" ]; then kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; fi
    rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

say() { printf '%s\n' "live_smoke: $*"; }
fail() { say "FAIL: $*" >&2; exit 1; }

say "capture 1s"
"$BIN" record --duration 1s --output "$TMP/rec.ndjson" >"$TMP/record.out" 2>"$TMP/record.summary" ||
    fail "record failed"
grep -q '"capability":"READY"' "$TMP/record.summary" || fail "record summary missing READY"
grep -q '"host_mutation":false' "$TMP/record.summary" || fail "record summary missing host_mutation=false"
LINES=$(wc -l <"$TMP/rec.ndjson" | tr -d ' ')
[ "$LINES" -gt 100 ] || fail "record produced only $LINES lines"
grep -v '"host_mutation":false' "$TMP/rec.ndjson" >/dev/null && fail "record emitted mutation rows"
grep -q '"event":"sched_switch"' "$TMP/rec.ndjson" || fail "record has no switches"
grep -q '"event":"page_fault"' "$TMP/rec.ndjson" || fail "record has no page faults"
MAJOR=$(grep '"event":"page_fault"' "$TMP/rec.ndjson" | grep -c '"b":1' || true)
MINOR=$(grep '"event":"page_fault"' "$TMP/rec.ndjson" | grep -c '"b":0' || true)
[ "$MINOR" -gt 0 ] || fail "no minor page faults observed"
say "record: $LINES lines, faults minor=$MINOR major=$MAJOR"

say "top"
"$BIN" top --duration 1s --interval 200ms --json --top 4 >"$TMP/top.json" 2>"$TMP/top.err" ||
    fail "top failed: $(cat "$TMP/top.err")"
grep -q '"schema":"xsprof/metrics/v1"' "$TMP/top.json" || fail "top JSON schema missing"
grep -q '"host_mutation":false' "$TMP/top.json" || fail "top JSON mutation flag missing"

say "why"
"$BIN" why --input "$TMP/rec.ndjson" --json >"$TMP/why.json" 2>"$TMP/why.err" ||
    fail "why failed: $(cat "$TMP/why.err")"
grep -q '"schema":"xsprof/why/v1"' "$TMP/why.json" || fail "why schema missing"
grep -q '"host_mutation":false' "$TMP/why.json" || fail "why mutation flag missing"

say "daemon + history"
STATE="$TMP/state"
"$BIN" daemon --foreground --dir "$STATE" --duration 3s --history-interval 1s --history-retain 1h \
    >"$TMP/daemon.json" 2>"$TMP/daemon.err" || fail "daemon failed: $(cat "$TMP/daemon.err")"
grep -q '"state":"stopped"' "$STATE/manifest.json" || fail "manifest not stopped"
grep -q '"capture_stop"' "$STATE"/segments/*.ndjson || fail "capture_stop missing"
SIDECARS=$(find "$STATE/metrics" -name '*.json' | wc -l | tr -d ' ')
[ "$SIDECARS" -ge 1 ] || fail "no history sidecars"
"$BIN" history --last 10m --dir "$STATE" >"$TMP/history.json" ||
    fail "history failed"
grep -q '"schema":"xsprof/history/v1"' "$TMP/history.json" || fail "history schema missing"
"$BIN" capture --last 1m --dir "$STATE" --out "$TMP/window.ndjson" ||
    fail "capture --last failed"
[ "$(wc -l <"$TMP/window.ndjson")" -gt 100 ] || fail "capture window too small"
say "daemon: sidecars=$SIDECARS"

say "SIGTERM"
SIG_STATE="$TMP/sigterm-state"
"$BIN" daemon --foreground --dir "$SIG_STATE" >"$TMP/sigterm.out" 2>&1 &
DAEMON_PID=$!
i=0
while [ "$i" -lt 100 ]; do
    [ -f "$SIG_STATE/manifest.json" ] && grep -q '"state":"recording"' "$SIG_STATE/manifest.json" && break
    sleep 0.1; i=$((i + 1))
done
[ -f "$SIG_STATE/manifest.json" ] || fail "SIGTERM daemon did not start"
kill -TERM "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=
grep -q '"state":"stopped"' "$SIG_STATE/manifest.json" || fail "SIGTERM did not stop manifest"
grep -q '"capture_stop signal=terminated"' "$SIG_STATE"/segments/*.ndjson ||
    fail "SIGTERM marker missing"
say "SIGTERM: clean"

if "$BIN" bpf-gate --json >"$TMP/bpf.json" 2>/dev/null; then
    grep -q '"host_mutation":false' "$TMP/bpf.json" || fail "bpf gate mutation flag"
    say "bpf-gate: READY (VM marker)"
else
    say "bpf-gate: SKIP/REFUSE (acceptable if libbpf/VM marker is unavailable)"
fi

say "PASS"
