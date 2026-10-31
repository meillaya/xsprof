#!/bin/sh
# Optional web bridge smoke: loopback, token, wasm/static assets, no mutation.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$ROOT/zig-out/bin/xsprof"
WASM="$ROOT/zig-out/web/assets/xsprof-web.wasm"
[ -x "$BIN" ] || { echo "web_smoke: build first (zig build)" >&2; exit 1; }
[ -f "$WASM" ] || { echo "web_smoke: build web first (zig build web)" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'if [ -n "${PID:-}" ] && [ "$PID" != 0 ]; then kill "$PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT HUP INT TERM
PORT=8791
"$BIN" serve --port "$PORT" --journal "$ROOT/fixtures/ui/healthy.ndjson" \
    --assets-dir "$ROOT/zig-out/web" >"$TMP/serve.log" 2>"$TMP/serve.err" &
PID=$!
i=0
while [ "$i" -lt 20 ]; do
    if grep -q token "$TMP/serve.log" 2>/dev/null; then break; fi
    sleep 0.1; i=$((i + 1))
done
URL=$(head -1 "$TMP/serve.log")
TOKEN=$(printf '%s' "$URL" | sed 's/.*token=//')
[ -n "$TOKEN" ] || { echo "web_smoke: no token" >&2; exit 1; }
fail=0
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
[ "$(code "http://127.0.0.1:$PORT/")" = 200 ] || { echo "web_smoke: index failed" >&2; fail=1; }
[ "$(code "http://127.0.0.1:$PORT/assets/xsprof-web.wasm")" = 200 ] || { echo "web_smoke: wasm failed" >&2; fail=1; }
for sym in web_ui_pointer_down web_ui_pointer_move web_ui_pointer_up web_ui_copy_ptr web_ui_copy_len web_ui_copy_clear; do
    strings "$WASM" | grep -q "$sym" || { echo "web_smoke: missing $sym" >&2; fail=1; }
done
[ "$(code "http://127.0.0.1:$PORT/scenarios/healthy.json")" = 200 ] || { echo "web_smoke: scenario failed" >&2; fail=1; }
[ "$(code "http://127.0.0.1:$PORT/api/meta?token=$TOKEN")" = 200 ] || { echo "web_smoke: meta failed" >&2; fail=1; }
[ "$(code "http://127.0.0.1:$PORT/api/meta")" = 401 ] || { echo "web_smoke: missing token accepted" >&2; fail=1; }
[ "$(code "http://127.0.0.1:$PORT/api/meta?token=deadbeef")" = 401 ] || { echo "web_smoke: bad token accepted" >&2; fail=1; }
[ "$(code -X POST "http://127.0.0.1:$PORT/")" = 405 ] || { echo "web_smoke: POST accepted" >&2; fail=1; }
META=$(curl -s "http://127.0.0.1:$PORT/api/meta?token=$TOKEN")
printf '%s' "$META" | grep -q '"host_mutation":false' || { echo "web_smoke: meta lacks host_mutation=false" >&2; fail=1; }
kill "$PID"; wait "$PID" 2>/dev/null || true; PID=
[ "$fail" -eq 0 ] || exit 1
echo "web_smoke: PASS"
