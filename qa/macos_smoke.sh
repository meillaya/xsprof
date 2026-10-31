#!/bin/sh
# Hidden AppKit/Metal smoke: creates an NSWindow and CAMetalLayer but never
# orders it front, then exits. Safe under automated work.
set -eu
if [ "$(uname -s)" != "Darwin" ]; then
    echo "macos_smoke: SKIP (not macOS)"
    exit 0
fi
BIN=${1:-./zig-out/bin/xsprof}
out=$("$BIN" ui --smoke 2>&1)
printf '%s\n' "$out"
printf '%s' "$out" | grep -q "hidden NSWindow/CAMetalLayer created"
echo "macos_smoke: PASS"
