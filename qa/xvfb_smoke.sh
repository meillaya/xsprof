#!/bin/sh
# Native Linux smoke under Xvfb: connects to X11, creates a GLX context,
# renders one frame, and never maps the window. Requires xvfb-run + Mesa.
set -eu
BIN=${1:-zig-out/bin/xsprof}
# Keep hidden smokes deterministic: isolated state dir, no user ui-settings.json.
XSPROF_STATE_DIR=${XSPROF_STATE_DIR:-${TMPDIR:-/tmp}/xsprof-smoke-state}
export XSPROF_STATE_DIR
if ! command -v xvfb-run >/dev/null 2>&1; then
    echo "xvfb_smoke: SKIP (xvfb-run unavailable)"
    exit 0
fi
if [ ! -x "$BIN" ]; then
    echo "xvfb_smoke: SKIP (binary missing: $BIN)"
    exit 0
fi
xvfb-run -a -s "-screen 0 1280x720x24 +extension GLX +render" "$BIN" ui --smoke --resize 900x600 --a11y
# Quickstart must stay terminal-only: XSPROF_NO_UI=1 prints usage and exits 0
# instead of opening (or trying to open) a window.
no_ui=$(XSPROF_NO_UI=1 "$BIN" 2>&1 || true)
printf '%s' "$no_ui" | grep -q "Open the console:" || {
    echo "xvfb_smoke: FAIL (XSPROF_NO_UI quickstart missing)"
    exit 1
}
echo "xvfb_smoke: PASS"
