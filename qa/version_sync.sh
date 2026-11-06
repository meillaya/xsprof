#!/bin/sh
# Keep the package manifest, runtime version, and release tooling in lockstep.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZON=$(sed -n 's/.*\.version = "\(.*\)".*/\1/p' "$ROOT/build.zig.zon" | head -1)
SRC=$(sed -n 's/.*pub const version = "\(.*\)".*/\1/p' "$ROOT/src/core/version.zig" | head -1)
if [ -z "$ZON" ] || [ "$ZON" != "$SRC" ]; then
    echo "version_sync: build.zig.zon=$ZON version.zig=$SRC" >&2
    exit 1
fi
echo "version_sync: PASS ($ZON)"
