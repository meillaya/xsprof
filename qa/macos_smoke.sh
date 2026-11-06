#!/bin/sh
# Hidden AppKit/Metal smoke: creates an NSWindow and CAMetalLayer but never
# orders it front, then exits. Safe under automated work.
set -eu
if [ "$(uname -s)" != "Darwin" ]; then
    echo "macos_smoke: SKIP (not macOS)"
    exit 0
fi
BIN=${1:-./zig-out/bin/xsprof}
# Keep hidden smokes deterministic: isolated state dir, no user ui-settings.json.
XSPROF_STATE_DIR=${XSPROF_STATE_DIR:-${TMPDIR:-/tmp}/xsprof-smoke-state}
export XSPROF_STATE_DIR
out=$("$BIN" ui --smoke --resize 900x600 --a11y 2>&1)
printf '%s\n' "$out"
printf '%s' "$out" | grep -q "NSWindow/CAMetalLayer created"
printf '%s' "$out" | grep -q "native a11y smoke:" || {
    echo "macos_smoke: FAIL (accessibility bridge smoke missing)"
    exit 1
}
no_ui=$(XSPROF_NO_UI=1 "$BIN" 2>&1 || true)
printf '%s' "$no_ui" | grep -q "Open the console:" || {
    echo "macos_smoke: FAIL (XSPROF_NO_UI quickstart missing)"
    exit 1
}
echo "macos_smoke: PASS"
