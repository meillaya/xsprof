#!/bin/sh
# Native Linux smoke under Xvfb: connects to X11, creates a GLX context,
# renders one frame, and never maps the window. Requires xvfb-run + Mesa.
set -eu
BIN=${1:-zig-out/linux-arm/bin/xsprof}
if ! command -v xvfb-run >/dev/null 2>&1; then
    echo "xvfb_smoke: SKIP (xvfb-run unavailable)"
    exit 0
fi
if [ ! -x "$BIN" ]; then
    echo "xvfb_smoke: SKIP (binary missing: $BIN)"
    exit 0
fi
xvfb-run -a -s "-screen 0 1280x720x24 +extension GLX +render" "$BIN" ui --smoke
echo "xvfb_smoke: PASS"
