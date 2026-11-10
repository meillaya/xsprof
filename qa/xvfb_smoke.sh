#!/bin/sh
# Native Linux smoke under Xvfb: connects to X11, creates a GLX context,
# renders one frame, and never maps the window. Requires xvfb-run + Mesa.
#
# Tool policy: Xvfb and a built binary are required for this gate to mean
# anything. Without --require-tools / XSPROF_REQUIRE_TOOLS=1 a missing
# prerequisite downgrades the gate to SKIP (exit 0) so a developer host without
# Xvfb can still run the other gates. CI runs `zig build check-ci`, which sets
# XSPROF_REQUIRE_TOOLS=1 for this script: a SKIP becomes a hard failure.
#
# Usage: sh qa/xvfb_smoke.sh [--require-tools] [BINARY]
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
            echo "usage: sh qa/xvfb_smoke.sh [--require-tools] [BINARY]"
            exit 0
            ;;
        -*)
            echo "xvfb_smoke: unknown argument: $1" >&2
            exit 2
            ;;
        *) BIN=$1 ;;
    esac
    shift
done
[ -n "$BIN" ] || BIN=zig-out/bin/xsprof
case "$BIN" in
    /*) ;;
    *) BIN="$ROOT/$BIN" ;;
esac

unavailable() { # reason
    if [ "$REQUIRE_TOOLS" = 1 ]; then
        echo "xvfb_smoke: FAIL ($1)" >&2
        exit 1
    fi
    echo "xvfb_smoke: SKIP ($1)"
    exit 0
}

XVFB_RUN=${XSPROF_XVFB_RUN:-xvfb-run}
command -v "$XVFB_RUN" >/dev/null 2>&1 || unavailable "required tool unavailable: xvfb-run (XVFB_RUN=${XVFB_RUN:-<unset>})"
[ -x "$BIN" ] || unavailable "binary missing: $BIN (run ./tools/zig build)"

# Keep hidden smokes deterministic: isolated state dir, no user ui-settings.json.
XSPROF_STATE_DIR=${XSPROF_STATE_DIR:-${TMPDIR:-/tmp}/xsprof-smoke-state}
export XSPROF_STATE_DIR
cd "$ROOT" 2>/dev/null || true
smoke_log=$("$XVFB_RUN" -a -s "-screen 0 1280x720x24 +extension GLX +render" \
    "$BIN" ui --smoke --resize 900x600 --a11y 2>&1) && smoke_rc=0 || smoke_rc=$?
printf '%s\n' "$smoke_log"
if [ "$smoke_rc" != 0 ]; then
    case "$smoke_log" in
        *NoDisplay* | *NoGLXExtension* | *NoVisual* | *NoGLContext* | *NoCurrentContext* | *NoGL*)
            if [ "$REQUIRE_TOOLS" = 1 ]; then
                echo "xvfb_smoke: FAIL (X11/GLX smoke unavailable: exit $smoke_rc)" >&2
                exit 1
            fi
            echo "xvfb_smoke: SKIP (X11/GLX smoke unavailable: exit $smoke_rc)"
            exit 0
            ;;
        *)
            echo "xvfb_smoke: FAIL (hidden X11/GLX smoke exited $smoke_rc)" >&2
            exit 1
            ;;
    esac
fi
printf '%s' "$smoke_log" | grep -q "linux smoke:" || {
    echo "xvfb_smoke: FAIL (no hidden X11/GLX smoke status line)" >&2
    exit 1
}
# CPU-vs-GL offscreen parity for two product routes. Thresholds live in
# design/ui-spec.json (acceptance.cross_surface.cpu_vs_gl). A driver without
# framebuffer readback reports an explicit SKIP; strict CI treats that as a
# failure instead of silently dropping the parity gate.
if printf '%s' "$smoke_log" | grep -q "gl parity: result=FAIL"; then
    echo "xvfb_smoke: FAIL (CPU-vs-GL parity above the ui-spec gate)" >&2
    exit 1
fi
if printf '%s' "$smoke_log" | grep -q "gl parity: SKIP"; then
    skip_reason=$(printf '%s' "$smoke_log" | grep -m1 "gl parity: SKIP")
    if [ "$REQUIRE_TOOLS" = 1 ]; then
        echo "xvfb_smoke: FAIL (CPU-vs-GL parity unavailable: $skip_reason)" >&2
        exit 1
    fi
    echo "xvfb_smoke: gl-parity SKIP ($skip_reason)"
    GL_PARITY=skipped
else
    routes=$(printf '%s' "$smoke_log" | grep -c "gl parity: route=.* result=PASS")
    if [ "$routes" -lt 2 ]; then
        echo "xvfb_smoke: FAIL (expected CPU-vs-GL parity PASS for home and overview, got $routes)" >&2
        exit 1
    fi
    GL_PARITY=pass
fi
# Quickstart must stay terminal-only: XSPROF_NO_UI=1 prints usage and exits 0
# instead of opening (or trying to open) a window.
no_ui=$(XSPROF_NO_UI=1 "$BIN" 2>&1 || true)
printf '%s' "$no_ui" | grep -q "Open the console:" || {
    echo "xvfb_smoke: FAIL (XSPROF_NO_UI quickstart missing)"
    exit 1
}
if [ "${GL_PARITY:-pass}" = "pass" ]; then
    echo "xvfb_smoke: PASS (hidden surface + CPU-vs-GL parity for home and overview)"
else
    echo "xvfb_smoke: PASS (hidden surface; CPU-vs-GL parity SKIPPED: no readback)"
fi
