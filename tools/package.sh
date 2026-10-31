#!/bin/sh
# Build a release binary and a self-contained tarball. Does not publish.
# Cross packaging: XSPROF_TARGET=aarch64-linux-gnu XSPROF_OS=linux
# XSPROF_ARCH=aarch64.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' build.zig.zon | head -1)
OS=${XSPROF_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}
ARCH=${XSPROF_ARCH:-$(uname -m)}
TARGET=${XSPROF_TARGET:-}
NAME="xsprof-$VERSION-$OS-$ARCH"
DIST="$ROOT/dist/$NAME"
case "$VERSION$OS$ARCH" in
    *[!A-Za-z0-9._-]*) echo "package: invalid version/os/arch" >&2; exit 1 ;;
esac
case "$DIST" in
    "$ROOT"/dist/xsprof-*) ;;
    *) echo "package: refusing unexpected dist path $DIST" >&2; exit 1 ;;
esac

PREFIX="$ROOT/zig-out/package"
rm -rf "$PREFIX"
./tools/zig build web -Doptimize=ReleaseSafe
if [ -n "$TARGET" ]; then
    ./tools/zig build -Doptimize=ReleaseSafe -Dtarget="$TARGET" --prefix "$PREFIX"
else
    ./tools/zig build -Doptimize=ReleaseSafe --prefix "$PREFIX"
fi
[ -f zig-out/web/index.html ] || {
    echo "package: web assets missing after build" >&2
    exit 1
}
rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/share/xsprof/web" "$DIST/share/xsprof/fixtures"
mkdir -p "$DIST/share/doc/xsprof"
cp "$PREFIX/bin/xsprof" "$DIST/bin/xsprof"
cp -R zig-out/web/. "$DIST/share/xsprof/web/"
cp fixtures/ui/healthy.ndjson "$DIST/share/xsprof/fixtures/healthy.ndjson"
cp README.md THIRD_PARTY_NOTICES.md "$DIST/share/doc/xsprof/"
cp docs/guides/flight-recorder.md "$DIST/share/doc/xsprof/"
cp docs/guides/compare-ci.md "$DIST/share/doc/xsprof/"
cp docs/guides/host-probes.md "$DIST/share/doc/xsprof/"
if [ "$OS" = linux ]; then
    mkdir -p "$DIST/lib/systemd/system"
    cp packaging/systemd/xsprof-recorder.service "$DIST/lib/systemd/system/"
fi
chmod 755 "$DIST/bin/xsprof"

mkdir -p "$ROOT/dist"
tar -C "$ROOT/dist" -czf "$ROOT/dist/$NAME.tar.gz" "$NAME"
echo "$ROOT/dist/$NAME.tar.gz"
