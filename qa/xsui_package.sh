#!/bin/sh
# Standalone xsui package gate: no profiler imports, version lockstep, package
# tests, and a public-API-only PNG example. No window, GPU device, or network
# is required for the example itself.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZIG="$ROOT/tools/zig"
PKG="$ROOT/lib/xsui"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail=0

# The package must remain independently usable: no xsprof/app/OS imports.
if grep -R -n -E '@import\("(xsprof|app|core|stream|capture|serve)' \
    "$PKG/src" "$PKG/examples" >"$TMP/imports" 2>/dev/null; then
    echo "xsui_package: package imports xsprof modules" >&2
    sed -n '1,20p' "$TMP/imports" >&2
    fail=1
fi
if grep -R -n -E '\.\./\.\./src|\.\./\.\./app|src/ui/' "$PKG/src" "$PKG/examples" \
    >"$TMP/paths" 2>/dev/null; then
    echo "xsui_package: package reaches into the xsprof tree" >&2
    sed -n '1,20p' "$TMP/paths" >&2
    fail=1
fi

# The package is native-only: no WebGL2 shim/ABI or wasm/freestanding branches
# may creep back in (task: remove the browser surface).
if grep -R -n -E 'webgl|WebGL2|wasm32|freestanding' \
    "$PKG/src" "$PKG/examples" "$PKG/build.zig" "$PKG/README.md" >"$TMP/webgl" 2>/dev/null; then
    echo "xsui_package: WebGL2/wasm remnants found" >&2
    sed -n '1,20p' "$TMP/webgl" >&2
    fail=1
fi
if [ -e "$PKG/src/gpu/webgl.zig" ] || [ -d "$PKG/src/gpu/shaders/webgl2" ]; then
    echo "xsui_package: WebGL2 source files still present" >&2
    fail=1
fi

# build.zig.zon and xsui.version must agree.
zon_version=$(sed -n 's/.*\.version = "\(.*\)".*/\1/p' "$PKG/build.zig.zon" | head -1)
src_version=$(sed -n 's/.*pub const version = "\(.*\)".*/\1/p' "$PKG/src/xsui.zig" | head -1)
if [ -z "$zon_version" ] || [ "$zon_version" != "$src_version" ]; then
    echo "xsui_package: version mismatch ($zon_version vs $src_version)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi

(cd "$PKG" && "$ZIG" build test)
(cd "$PKG" && "$ZIG" build example -- --out "$TMP/example.png")

if [ ! -s "$TMP/example.png" ]; then
    echo "xsui_package: example produced no PNG" >&2
    exit 1
fi
sig=$(od -An -tx1 -N8 "$TMP/example.png" | tr -d ' \n')
if [ "$sig" != "89504e470d0a1a0a" ]; then
    echo "xsui_package: example has a bad PNG signature ($sig)" >&2
    exit 1
fi
size=$(wc -c <"$TMP/example.png" | tr -d ' ')
if [ "$size" -lt 1024 ]; then
    echo "xsui_package: example PNG is too small ($size bytes)" >&2
    exit 1
fi
echo "xsui_package: PASS (v$src_version, $size-byte example)"
