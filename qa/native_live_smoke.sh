#!/bin/sh
# Native live/recorder-tail smoke under Xvfb. Never maps a window; perf may be
# unavailable, in which case the command must print an explicit SKIP/REFUSE and
# still exercise the bounded controller state.
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=$1
[ -n "$BIN" ] || BIN="$ROOT/zig-out/bin/xsprof"
if ! command -v xvfb-run >/dev/null 2>&1; then
    echo "native_live_smoke: SKIP (xvfb-run unavailable)"
    exit 0
fi
if [ ! -x "$BIN" ]; then
    echo "native_live_smoke: SKIP (binary missing: $BIN)"
    exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
export XSPROF_STATE_DIR="$TMP/state"
out=$(xvfb-run -a -s "-screen 0 1280x720x24 +extension GLX +render" \
    "$BIN" ui --live --smoke --duration 250 2>&1)
printf '%s\n' "$out"
printf '%s' "$out" | grep -q "live smoke:" || {
    echo "native_live_smoke: FAIL (no live controller status line)" >&2
    exit 1
}
tail=$(xvfb-run -a -s "-screen 0 1280x720x24 +extension GLX +render" \
    "$BIN" ui --follow-recorder "$ROOT/fixtures/ui/design/recorder" --smoke --duration 400 2>&1)
printf '%s\n' "$tail"
printf '%s' "$tail" | grep -q "live smoke:" || {
    echo "native_live_smoke: FAIL (no recorder-tail status line)" >&2
    exit 1
}
if ! printf '%s' "$tail" | grep -Eq 'source_events=[1-9]|indexed=[1-9]|rebuilt=[1-9]'; then
    echo "native_live_smoke: FAIL (recorder tail produced no events)" >&2
    exit 1
fi
echo "native_live_smoke: PASS"
