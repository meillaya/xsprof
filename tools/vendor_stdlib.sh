#!/bin/sh
# Refresh the vendored Zig 0.17.0 standard-library text corpus.
# Network is required only when the pinned artifacts are not already cached.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=0.17.0
SRC_SUM=b6c7f1728f043700d6529bac980800792f824256a9d2f1839b3d62beed0b8abd
DL="$ROOT/.tools/downloads"
SRC="$ROOT/.tools/zig-src-$VERSION"
OUT="$ROOT/docs/vendor/zig-$VERSION"
mkdir -p "$DL" "$SRC" "$OUT"

if [ ! -f "$DL/zig-$VERSION.tar.xz" ]; then
    curl -fL --retry 3 --connect-timeout 15 \
        -o "$DL/zig-$VERSION.tar.xz" "https://ziglang.org/download/$VERSION/zig-$VERSION.tar.xz"
fi
if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$SRC_SUM" "$DL/zig-$VERSION.tar.xz" | sha256sum -c -
else
    printf '%s  %s\n' "$SRC_SUM" "$DL/zig-$VERSION.tar.xz" | shasum -a 256 -c -
fi
if [ ! -f "$SRC/lib/std/std.zig" ]; then
    tar -xJf "$DL/zig-$VERSION.tar.xz" -C "$SRC" --strip-components=1
fi

LANGREF="$DL/langref-$VERSION.html"
if [ ! -f "$LANGREF" ]; then
    curl -fL --retry 3 --connect-timeout 15 \
        -o "$LANGREF" "https://ziglang.org/documentation/$VERSION/"
fi

python3 "$ROOT/tools/vendor_stdlib.py" --std "$SRC/lib/std" --out "$OUT" --langref "$LANGREF"

cd "$OUT"
if [ -f SOURCE.md ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum SOURCE.md zig-$VERSION-stdlib-sources.txt zig-$VERSION-stdlib-reference.txt zig-$VERSION-langref.txt > SHA256SUMS
    else
        shasum -a 256 SOURCE.md zig-$VERSION-stdlib-sources.txt zig-$VERSION-stdlib-reference.txt zig-$VERSION-langref.txt > SHA256SUMS
    fi
fi
cat SHA256SUMS
