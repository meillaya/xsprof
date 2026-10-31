#!/bin/sh
# Build a release binary and a self-contained tarball. Does not publish.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' build.zig.zon | head -1)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
NAME="xsprof-$VERSION-$OS-$ARCH"
DIST="$ROOT/dist/$NAME"

case "$DIST" in
    "$ROOT"/dist/xsprof-*) ;;
    *) echo "package: refusing unexpected dist path $DIST" >&2; exit 1 ;;
esac

./tools/zig build -Doptimize=ReleaseSafe
rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/share/xsprof/web" "$DIST/share/xsprof/fixtures"
mkdir -p "$DIST/lib/systemd/system" "$DIST/share/doc/xsprof"
cp zig-out/bin/xsprof "$DIST/bin/xsprof"
cp -R zig-out/web/. "$DIST/share/xsprof/web/"
cp fixtures/ui/healthy.ndjson "$DIST/share/xsprof/fixtures/healthy.ndjson"
cp packaging/systemd/xsprof-recorder.service "$DIST/lib/systemd/system/"
cp README.md THIRD_PARTY_NOTICES.md "$DIST/share/doc/xsprof/"
cp docs/guides/flight-recorder.md "$DIST/share/doc/xsprof/"
cp docs/guides/compare-ci.md "$DIST/share/doc/xsprof/"
chmod 755 "$DIST/bin/xsprof"

mkdir -p "$ROOT/dist"
tar -C "$ROOT/dist" -czf "$ROOT/dist/$NAME.tar.gz" "$NAME"
echo "$ROOT/dist/$NAME.tar.gz"
