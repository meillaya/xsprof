#!/bin/sh
# Build a Debian package from the release tarball layout. Requires dpkg-deb.
# Cross packaging: XSPROF_DEB_ARCH=arm64 (needs an aarch64-linux-gnu Zig target;
# set XSPROF_TARGET to override). The package is unsigned; no repository keys
# are created or used here.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' build.zig.zon | head -1)
REVISION=${XSPROF_DEB_REVISION:-1}
case "$VERSION" in
    ""|*[!A-Za-z0-9.+~-]*) echo "package_deb: invalid version: $VERSION" >&2; exit 1 ;;
esac
case "$REVISION" in
    ""|*[!A-Za-z0-9.+~-]*) echo "package_deb: invalid revision: $REVISION" >&2; exit 1 ;;
esac

DEB_ARCH=${XSPROF_DEB_ARCH:-}
if [ -z "$DEB_ARCH" ]; then
    if command -v dpkg >/dev/null 2>&1; then
        DEB_ARCH=$(dpkg --print-architecture)
    else
        case "$(uname -m)" in
            x86_64|amd64) DEB_ARCH=amd64 ;;
            aarch64|arm64) DEB_ARCH=arm64 ;;
            *) echo "package_deb: unsupported host architecture $(uname -m)" >&2; exit 1 ;;
        esac
    fi
fi
case "$DEB_ARCH" in
    amd64) ZIG_TARGET=x86_64-linux-gnu ;;
    arm64) ZIG_TARGET=aarch64-linux-gnu ;;
    *) echo "package_deb: supported architectures are amd64 and arm64" >&2; exit 1 ;;
esac
TARGET=${XSPROF_TARGET:-$ZIG_TARGET}
NAME="xsprof_${VERSION}-${REVISION}_${DEB_ARCH}"
STAGE="$ROOT/dist/deb/$NAME"
case "$STAGE" in
    "$ROOT"/dist/deb/xsprof_*) ;;
    *) echo "package_deb: refusing unexpected path $STAGE" >&2; exit 1 ;;
esac

command -v dpkg-deb >/dev/null 2>&1 || {
    echo "package_deb: dpkg-deb unavailable; build on Debian/Ubuntu" >&2
    exit 1
}

# Build the target binary, and a host-native binary only to render
# arch-independent shell completions. A native package reuses one build.
# -Dcpu=baseline keeps the shipped binary portable: a native build on a newer
# host (or CI runner) may require CPU features the target host lacks.
PREFIX="$ROOT/zig-out/package-deb"
HOST_PREFIX="$ROOT/zig-out/package-deb-host"
rm -rf "$PREFIX" "$HOST_PREFIX"
./tools/zig build -Doptimize=ReleaseSafe -Dcpu=baseline --prefix "$HOST_PREFIX"
NATIVE=0
if [ -z "${XSPROF_TARGET:-}" ]; then
    case "$(uname -m)/$DEB_ARCH" in
        x86_64/amd64|aarch64/arm64) NATIVE=1 ;;
    esac
fi
if [ "$NATIVE" = 1 ]; then
    PREFIX="$HOST_PREFIX"
else
    ./tools/zig build -Doptimize=ReleaseSafe -Dcpu=baseline -Dtarget="$TARGET" --prefix "$PREFIX"
fi
[ -x "$HOST_PREFIX/bin/xsprof" ] || { echo "package_deb: host binary missing" >&2; exit 1; }
[ -x "$PREFIX/bin/xsprof" ] || { echo "package_deb: target binary missing" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin"
mkdir -p "$STAGE/usr/share/xsprof/fixtures" "$STAGE/usr/lib/systemd/system"
mkdir -p "$STAGE/usr/lib/sysusers.d" "$STAGE/usr/share/doc/xsprof"
mkdir -p "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/scalable/apps"
cp "$PREFIX/bin/xsprof" "$STAGE/usr/bin/xsprof"
cp fixtures/ui/healthy.ndjson "$STAGE/usr/share/xsprof/fixtures/healthy.ndjson"
cp packaging/systemd/xsprof-recorder.service "$STAGE/usr/lib/systemd/system/"
cp packaging/sysusers/xsprof.conf "$STAGE/usr/lib/sysusers.d/xsprof.conf"
cp packaging/linux/xsprof.desktop "$STAGE/usr/share/applications/xsprof.desktop"
cp packaging/linux/xsprof.svg "$STAGE/usr/share/icons/hicolor/scalable/apps/xsprof.svg"
sh tools/gen_completions.sh "$HOST_PREFIX/bin/xsprof" "$STAGE/usr/share"
cp README.md THIRD_PARTY_NOTICES.md LICENSE CHANGELOG.md "$STAGE/usr/share/doc/xsprof/"
chmod 755 "$STAGE/usr/bin/xsprof"
if [ -e "$STAGE/usr/share/xsprof/web" ] || find "$STAGE" -name '*.wasm' | grep -q .; then
    echo "package_deb: refusing to package web assets" >&2
    exit 1
fi

cat > "$STAGE/usr/share/doc/xsprof/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: xsprof
Source: https://github.com/meillaya/xsprof
License: MIT
Copyright: 2026 xsprof contributors
COPYRIGHT

: "${SOURCE_DATE_EPOCH:=$(git log -1 --format=%ct 2>/dev/null || date +%s)}"
export SOURCE_DATE_EPOCH
DEB_DATE=$(date -u -R -d "@$SOURCE_DATE_EPOCH" 2>/dev/null || date -u -R)
cat > "$STAGE/usr/share/doc/xsprof/changelog.Debian" <<CHANGELOG
xsprof (${VERSION}-${REVISION}) unstable; urgency=medium

  * Upstream release ${VERSION}.

 -- xsprof maintainers <maintainers@xsprof.dev>  ${DEB_DATE}
CHANGELOG
if command -v gzip >/dev/null 2>&1; then
    gzip -9n "$STAGE/usr/share/doc/xsprof/changelog.Debian"
fi

(
    cd "$STAGE"
    find usr -type f -print | LC_ALL=C sort | xargs md5sum > DEBIAN/md5sums
)

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: xsprof
Version: ${VERSION}-${REVISION}
Section: admin
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: xsprof maintainers <maintainers@xsprof.dev>
Homepage: https://github.com/meillaya/xsprof
Depends: libc6
Recommends: libx11-6, libgl1
Description: read-only Linux scheduler and memory profiler
 Flight recorder, scheduler latency metrics, timeline UI, and Chrome Trace
 export. The recorder service is opt-in and requires CAP_PERFMON.
CONTROL

mkdir -p "$ROOT/dist"
DEB="$ROOT/dist/${NAME}.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"
if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$ROOT/dist" && sha256sum "${NAME}.deb" > "${NAME}.deb.sha256" )
else
    ( cd "$ROOT/dist" && shasum -a 256 "${NAME}.deb" > "${NAME}.deb.sha256" )
fi
echo "$DEB"
