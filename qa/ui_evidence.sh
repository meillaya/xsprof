#!/bin/sh
# Developer-only headless evidence: screenshots, parity report, and a short
# boot/use recording of the WebGL2 console. Never opens a real window.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
BIN=${XSPROF_BIN:-./zig-out/bin/xsprof}
[ -x "$BIN" ] || { echo "ui_evidence: build first (zig build)" >&2; exit 1; }
[ -f zig-out/web/assets/xsprof-web.wasm ] || { echo "ui_evidence: build web first (zig build web)" >&2; exit 1; }
[ -f fixtures/ui/design/demo.json ] || { echo "ui_evidence: demo model missing" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ui_evidence: ffmpeg required" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ui_evidence: node required" >&2; exit 1; }
if [ -z "${NODE_PATH:-}" ]; then
  NODE_PATH="$HOME/.npm/_npx/e41f203b7505f1fb/node_modules"
  export NODE_PATH
fi
echo "ui_evidence: NODE_PATH=$NODE_PATH"
TMP=$(mktemp -d)
PID=0
cleanup() {
  if [ "$PID" != 0 ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM
PORT=${XSPROF_EVIDENCE_PORT:-8795}
"$BIN" serve --port "$PORT" --journal fixtures/real/macos-vm-sched.ndjson \
  --assets-dir zig-out/web >"$TMP/serve.log" 2>"$TMP/serve.err" &
PID=$!
i=0
while [ "$i" -lt 30 ]; do
  if grep -q token "$TMP/serve.log" 2>/dev/null; then break; fi
  sleep 0.1; i=$((i + 1))
done
URL=$(head -1 "$TMP/serve.log")
TOKEN=$(printf '%s' "$URL" | sed 's/.*token=//')
[ -n "$TOKEN" ] || { echo "ui_evidence: server did not print a token" >&2; cat "$TMP/serve.err" >&2 || true; exit 1; }
export XSPROF_EVIDENCE_URL="http://127.0.0.1:$PORT/"
export XSPROF_EVIDENCE_TOKEN="$TOKEN"
export XSPROF_EVIDENCE_OUT="design/screenshots/xsprof"
export XSPROF_EVIDENCE_VIDEO="$TMP/console.webm"
XSPROF_EVIDENCE_DEMO=1 node qa/ui_capture.cjs
XSPROF_EVIDENCE_DEMO=0 XSPROF_EVIDENCE_OUT=design/screenshots/live node qa/ui_capture.cjs
XSPROF_EVIDENCE_DEMO=0 node qa/ui_record.cjs
mkdir -p design/media
ffmpeg -v error -y -i "$TMP/console.webm" -c:v libx264 -preset slow -crf 23 \
  -pix_fmt yuv420p -movflags +faststart design/media/xsprof-ui-demo.mp4
XSPROF_EVIDENCE_DEMO=1 node qa/ui_breakpoints.cjs
node qa/ui_interactions.cjs
python3 qa/ui_parity.py
# Formal gate: CPU is canonical; WebGL2 must consume the same draw list and
# atlas within the ui-spec tolerance. Reference diffs above remain advisory.
mkdir -p "$TMP/cpu"
for view in overview timeline advisor events capture; do
  "$BIN" snapshot --demo-model fixtures/ui/design/demo.json --view "$view" \
    --theme dark --width 1440 --height 900 --out "$TMP/cpu/$view-graphite.png" >/dev/null
done
for theme in dark paper latte frappe macchiato mocha; do
  "$BIN" snapshot --demo-model fixtures/ui/design/demo.json --view overview \
    --theme "$theme" --width 1440 --height 900 --out "$TMP/cpu/overview-$theme.png" >/dev/null
done
mkdir -p "$TMP/metal"
METAL_ARG=
if "$BIN" snapshot --demo-model fixtures/ui/design/demo.json --view overview \
    --theme dark --width 1440 --height 900 --backend metal --out "$TMP/metal/overview-graphite.png" >/dev/null 2>&1; then
  for view in timeline advisor events capture; do
    "$BIN" snapshot --demo-model fixtures/ui/design/demo.json --view "$view" \
      --theme dark --width 1440 --height 900 --backend metal --out "$TMP/metal/$view-graphite.png" >/dev/null
  done
  METAL_ARG="--metal $TMP/metal"
fi
python3 qa/ui_cross_surface.py --cpu "$TMP/cpu" --web design/screenshots/xsprof $METAL_ARG \
  --out design/evidence/cross_surface.json
echo "ui_evidence: PASS (cross-surface gate + screenshots + video + advisory reference report)"
