#!/bin/sh
# Download and verify the pinned Zig 0.17.0 toolchain for this host.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=0.17.0
DEST="$ROOT/.tools/zig-$VERSION"
DL="$ROOT/.tools/downloads"
mkdir -p "$DL"

if [ -x "$DEST/zig" ] && [ "$("$DEST/zig" version)" = "$VERSION" ]; then
    printf '%s\n' "$DEST/zig"
    exit 0
fi

os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
    Darwin/arm64)   name=zig-aarch64-macos-$VERSION.tar.xz;  sum=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a ;;
    Darwin/x86_64)  name=zig-x86_64-macos-$VERSION.tar.xz;   sum=4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6 ;;
    Linux/x86_64)   name=zig-x86_64-linux-$VERSION.tar.xz;   sum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
    Linux/aarch64|Linux/arm64) name=zig-aarch64-linux-$VERSION.tar.xz; sum=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
    *) echo "unsupported host: $os/$arch" >&2; exit 1 ;;
esac

tarball="$DL/$name"
if [ ! -f "$tarball" ]; then
    curl -fL --retry 3 --connect-timeout 15 \
        -o "$tarball" "https://ziglang.org/download/$VERSION/$name"
fi

if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$sum" "$tarball" | sha256sum -c -
else
    printf '%s  %s\n' "$sum" "$tarball" | shasum -a 256 -c -
fi

rm -rf "$DEST"
mkdir -p "$ROOT/.tools/extract"
tar -xJf "$tarball" -C "$ROOT/.tools/extract"
extracted="$ROOT/.tools/extract/${name%.tar.xz}"
[ -d "$extracted" ] || { echo "unexpected archive layout: $extracted" >&2; exit 1; }
mv "$extracted" "$DEST"
rmdir "$ROOT/.tools/extract" 2>/dev/null || true
[ "$("$DEST/zig" version)" = "$VERSION" ] || { echo "zig version mismatch" >&2; exit 1; }
printf '%s\n' "$DEST/zig"
