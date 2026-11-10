#!/bin/sh
# Native live/recorder-tail smoke under Xvfb. Never maps a window; perf may be
# unavailable, in which case the command must print an explicit SKIP/REFUSE and
# still exercise the bounded controller state.
#
# Tool policy: Xvfb and a built binary are required. Without --require-tools /
# XSPROF_REQUIRE_TOOLS=1 a missing prerequisite downgrades the gate to SKIP
# (exit 0) for developer hosts; CI sets XSPROF_REQUIRE_TOOLS=1 through
# `zig build check-ci`, where a SKIP is a hard failure.
#
# Usage: sh qa/native_live_smoke.sh [--require-tools] [BINARY]
# Exit:  0 PASS (or SKIP without --require-tools), 1 FAIL.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REQUIRE_TOOLS=0
case "${XSPROF_REQUIRE_TOOLS:-0}" in
    1 | true | TRUE | yes | YES) REQUIRE_TOOLS=1 ;;
esac
BIN=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --require-tools) REQUIRE_TOOLS=1 ;;
        -h | --help)
            echo "usage: sh qa/native_live_smoke.sh [--require-tools] [BINARY]"
            exit 0
            ;;
        -*)
            echo "native_live_smoke: unknown argument: $1" >&2
            exit 2
            ;;
        *) BIN=$1 ;;
    esac
    shift
done
[ -n "$BIN" ] || BIN="$ROOT/zig-out/bin/xsprof"

unavailable() { # reason
    if [ "$REQUIRE_TOOLS" = 1 ]; then
        echo "native_live_smoke: FAIL ($1)" >&2
        exit 1
    fi
    echo "native_live_smoke: SKIP ($1)"
    exit 0
}

command -v xvfb-run >/dev/null 2>&1 || unavailable "required tool unavailable: xvfb-run"
[ -x "$BIN" ] || unavailable "binary missing: $BIN (run ./tools/zig build)"

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
