#!/bin/sh
# Unprivileged compact-segment gate: decode, verify, corrupt, truncate, and mix
# legacy NDJSON state without perf. No window, no host mutation.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
GOLD="$ROOT/tests/golden/recorder"
GOLD_SEG="$GOLD/segments/segment_v1_golden.xsraw"
GOLD_OUT="$GOLD/segment_v1_golden.ndjson"
[ -x "$BIN" ] || { echo "compact_roundtrip: build first (zig build)" >&2; exit 1; }
[ -f "$GOLD_SEG" ] || { echo "compact_roundtrip: missing golden $GOLD_SEG" >&2; exit 1; }
[ -f "$GOLD_OUT" ] || { echo "compact_roundtrip: missing golden $GOLD_OUT" >&2; exit 1; }
TMP=$(mktemp -d)
SRV=""
trap 'if [ -n "$SRV" ]; then kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT HUP INT TERM
fail=0
say() { printf '%s\n' "compact_roundtrip: $*"; }
bad() { say "FAIL: $*" >&2; fail=1; }

NOW_S=$(date +%s)
START_S=$((NOW_S - 120))
START_NS="${START_S}000000000"
END_NS="${NOW_S}000000000"
GEVENTS=$(wc -l <"$GOLD_OUT" | tr -d ' ')

write_manifest() { # dir bytes events path codec
    cat >"$1/manifest.json" <<EOF
{"host_mutation":false,"max_age_ms":600000,"max_bytes":2147483648,"raw_codec":"$5","schema":"xsprof/recorder-manifest/v1","segments":[{"bytes":$2,"closed":true,"codec":"$5","end_mono_ns":70000000000,"end_wall_ns":$END_NS,"events":$3,"path":"$4","start_mono_ns":0,"start_wall_ns":$START_NS}],"session_id":"compact-roundtrip","started_mono_ns":0,"started_wall_ns":$START_NS,"state":"stopped","updated_wall_ns":$END_NS}
EOF
}

# 1. Clean golden segment: capture must be byte-identical to the canonical extract.
CLEAN="$TMP/clean"
mkdir -p "$CLEAN/segments"
cp "$GOLD_SEG" "$CLEAN/segments/segment_v1_golden.xsraw"
GBYTES=$(wc -c <"$CLEAN/segments/segment_v1_golden.xsraw" | tr -d ' ')
write_manifest "$CLEAN" "$GBYTES" "$GEVENTS" "segments/segment_v1_golden.xsraw" "compact_v1"
"$BIN" capture --last 1h --dir "$CLEAN" --out "$TMP/clean.ndjson" || bad "capture failed on clean state"
if ! cmp -s "$TMP/clean.ndjson" "$GOLD_OUT"; then
    bad "clean extraction differs from the committed canonical extract"
fi
if ! "$BIN" verify --dir "$CLEAN" --json >"$TMP/verify-clean"; then
    bad "verify did not exit zero on the clean state"
fi
grep -q '"state":"READY"' "$TMP/verify-clean" || bad "clean verify state is not READY"
grep -q '"host_mutation":false' "$TMP/verify-clean" || bad "clean verify omitted host_mutation=false"
"$BIN" capture --last 1h --dir "$CLEAN" --markers-only --out "$TMP/markers.ndjson" ||
    bad "markers-only capture failed"
if grep -v '"event":"marker"' "$TMP/markers.ndjson" | grep -q .; then
    bad "markers-only capture emitted a non-marker row"
fi

# 2. A payload bit flip is corrupt: REFUSE plus an explicit extraction marker.
CORRUPT="$TMP/corrupt"
cp -R "$CLEAN" "$CORRUPT"
python3 - "$CORRUPT/segments/segment_v1_golden.xsraw" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
data[80] ^= 0xFF
open(path, "wb").write(data)
PY
if "$BIN" verify --dir "$CORRUPT" --json >"$TMP/verify-corrupt" 2>/dev/null; then
    bad "verify accepted a corrupted segment"
fi
grep -q '"state":"REFUSE"' "$TMP/verify-corrupt" || bad "corrupt verify state is not REFUSE"
"$BIN" capture --last 1h --dir "$CORRUPT" --out "$TMP/corrupt.ndjson" ||
    bad "capture refused to mark a corrupt segment"
grep -q 'capture_corrupt_segment' "$TMP/corrupt.ndjson" || bad "corrupt extraction has no marker"

# 3. A torn tail is dirty: DEGRADED plus a truncated-tail marker with a prefix.
TORN="$TMP/torn"
cp -R "$CLEAN" "$TORN"
python3 - "$TORN/segments/segment_v1_golden.xsraw" <<'PY'
import sys
path = sys.argv[1]
data = open(path, "rb").read()
open(path, "wb").write(data[:-5])
PY
if "$BIN" verify --dir "$TORN" --json >"$TMP/verify-torn" 2>/dev/null; then
    bad "verify accepted a torn segment"
fi
grep -q '"state":"DEGRADED"' "$TMP/verify-torn" || bad "torn verify state is not DEGRADED"
"$BIN" capture --last 1h --dir "$TORN" --out "$TMP/torn.ndjson" ||
    bad "capture failed on a torn segment"
grep -q 'capture_truncated_tail' "$TMP/torn.ndjson" || bad "torn extraction has no tail marker"
if [ "$(wc -l <"$TMP/torn.ndjson")" -lt 2 ]; then
    bad "torn extraction lost the complete prefix"
fi

# 4. A legacy NDJSON segment and a compact segment decode into one window.
MIXED="$TMP/mixed"
mkdir -p "$MIXED/segments"
cp "$GOLD_SEG" "$MIXED/segments/segment_v1_golden.xsraw"
cat >"$MIXED/segments/legacy-0.ndjson" <<'EOF'
{"schema":"xsprof/event/v1","event":"marker","ts_ns":0,"cpu":-1,"pid":7,"tid":7,"comm":"xsprof","detail":"capture_owner","host_mutation":false}
{"schema":"xsprof/event/v1","event":"sched_switch","ts_ns":61000000000,"cpu":0,"pid":7,"tid":7,"a":9,"b":0,"c":0,"comm":"legacy-worker","host_mutation":false}
EOF
LBODY=$(wc -c <"$MIXED/segments/legacy-0.ndjson" | tr -d ' ')
cat >"$MIXED/manifest.json" <<EOF
{"host_mutation":false,"max_age_ms":600000,"max_bytes":2147483648,"raw_codec":"compact_v1","schema":"xsprof/recorder-manifest/v1","segments":[{"bytes":$GBYTES,"closed":true,"codec":"compact_v1","end_mono_ns":70000000000,"end_wall_ns":$END_NS,"events":$GEVENTS,"path":"segments/segment_v1_golden.xsraw","start_mono_ns":0,"start_wall_ns":$START_NS},{"bytes":$LBODY,"closed":true,"codec":"ndjson","end_mono_ns":70000000000,"end_wall_ns":$END_NS,"events":2,"path":"segments/legacy-0.ndjson","start_mono_ns":0,"start_wall_ns":$START_NS}],"session_id":"compact-mixed","started_mono_ns":0,"started_wall_ns":$START_NS,"state":"stopped","updated_wall_ns":$END_NS}
EOF
"$BIN" capture --last 1h --dir "$MIXED" --out "$TMP/mixed.ndjson" ||
    bad "capture failed on a mixed state"
grep -q '"comm":"legacy-worker"' "$TMP/mixed.ndjson" || bad "legacy segment missing from mixed extraction"
grep -q '"event":"sched_switch"' "$TMP/mixed.ndjson" || bad "compact segment missing from mixed extraction"
if grep -q 'capture_corrupt\|capture_unknown' "$TMP/mixed.ndjson"; then
    bad "mixed extraction emitted a corruption marker"
fi
if ! "$BIN" verify --dir "$MIXED" --json >"$TMP/verify-mixed"; then
    bad "verify did not exit zero on the mixed state"
fi

# 5. An unknown/unsupported version is refused loudly, never decoded.
UNSUP="$TMP/unsupported"
cp -R "$CLEAN" "$UNSUP"
python3 - "$UNSUP/segments/segment_v1_golden.xsraw" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
data[8] = 2
open(path, "wb").write(data)
PY
if "$BIN" verify --dir "$UNSUP" --json >"$TMP/verify-unsup" 2>/dev/null; then
    bad "verify accepted an unsupported segment version"
fi
"$BIN" capture --last 1h --dir "$UNSUP" --out "$TMP/unsup.ndjson" ||
    bad "capture failed on an unsupported segment"
grep -q 'capture_unsupported_segment' "$TMP/unsup.ndjson" || bad "unsupported extraction has no marker"

# 6. GET /api/window serves the bounded canonical window with the token gate.
if command -v curl >/dev/null 2>&1; then
    PORT=38993
    "$BIN" serve --port "$PORT" --journal "$ROOT/fixtures/ui/healthy.ndjson" \
        --recorder-dir "$CLEAN" >"$TMP/serve.log" 2>"$TMP/serve.err" &
    SRV=$!
    i=0
    while [ "$i" -lt 50 ]; do
        if grep -q "token=" "$TMP/serve.log" 2>/dev/null; then break; fi
        sleep 0.1
        i=$((i + 1))
    done
    URL=$(head -1 "$TMP/serve.log")
    TOKEN=$(printf '%s' "$URL" | sed 's/.*token=//')
    [ -n "$TOKEN" ] || bad "no serve token for /api/window"
    CODE=$(curl -s -o "$TMP/api-window.ndjson" -w '%{http_code}' \
        "http://127.0.0.1:$PORT/api/window?token=$TOKEN&last=1h")
    [ "$CODE" = 200 ] || bad "/api/window returned HTTP $CODE"
    if ! cmp -s "$TMP/api-window.ndjson" "$GOLD_OUT"; then
        bad "/api/window body differs from the canonical golden extract"
    fi
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/window?last=1h")
    [ "$CODE" = 401 ] || bad "/api/window accepted a missing token"
    kill "$SRV" 2>/dev/null || true
    wait "$SRV" 2>/dev/null || true
    SRV=""
else
    say "SKIP /api/window (curl missing)"
fi

[ "$fail" -eq 0 ] || exit 1
say "PASS"