#!/bin/sh
# Build a Debian package from the release tarball layout. Requires dpkg-deb.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' build.zig.zon | head -1)
ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
NAME="xsprof_${VERSION}_${ARCH}"
STAGE="$ROOT/dist/deb/$NAME"

case "$STAGE" in
    "$ROOT"/dist/deb/xsprof_*) ;;
    *) echo "package_deb: refusing unexpected path $STAGE" >&2; exit 1 ;;
esac

command -v dpkg-deb >/dev/null 2>&1 || {
    echo "package_deb: dpkg-deb unavailable; build on Debian/Ubuntu" >&2
    exit 1
}

./tools/zig build -Doptimize=ReleaseSafe
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/share/xsprof/web"
mkdir -p "$STAGE/usr/share/xsprof/fixtures" "$STAGE/usr/lib/systemd/system"
mkdir -p "$STAGE/usr/share/doc/xsprof"
cp zig-out/bin/xsprof "$STAGE/usr/bin/xsprof"
cp -R zig-out/web/. "$STAGE/usr/share/xsprof/web/"
cp fixtures/ui/healthy.ndjson "$STAGE/usr/share/xsprof/fixtures/healthy.ndjson"
cp packaging/systemd/xsprof-recorder.service "$STAGE/usr/lib/systemd/system/"
cp README.md THIRD_PARTY_NOTICES.md "$STAGE/usr/share/doc/xsprof/"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: xsprof
Version: $VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Maintainer: xsprof maintainers
Description: read-only Linux scheduler and memory profiler
 Flight recorder, scheduler latency metrics, timeline UI, and Chrome Trace
 export. The recorder service is opt-in and requires CAP_PERFMON.
CONTROL

dpkg-deb --build --root-owner-group "$STAGE" "$ROOT/dist/$NAME.deb"
echo "$ROOT/dist/$NAME.deb"
