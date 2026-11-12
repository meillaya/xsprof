#!/bin/sh
# Build a single-architecture AppImage for the host architecture. Does not
# publish. The AppDir contains only the native binary, the bundled replay
# fixture, the desktop entry, the icon, and AppRun: no web assets and no
# X11/GL/mesa driver libraries are bundled (the binary dlopens the host's
# libX11.so.6/libGL.so.1 as usual).
#
# Requires: Linux host matching XSPROF_APPIMAGE_ARCH (default: uname -m),
# network on first run for the pinned appimagetool, and a working Zig build.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = Linux ] || {
    echo "package_appimage: AppImage is Linux-only (host is $(uname -s))" >&2
    exit 2
}
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' build.zig.zon | head -1)
case "$VERSION" in
    ""|*[!A-Za-z0-9._-]*) echo "package_appimage: invalid version: $VERSION" >&2; exit 1 ;;
esac
HOST_ARCH=$(uname -m)
ARCH=${XSPROF_APPIMAGE_ARCH:-$HOST_ARCH}
case "$ARCH" in
    x86_64|aarch64) ;;
    *) echo "package_appimage: unsupported architecture: $ARCH" >&2; exit 2 ;;
esac
[ "$ARCH" = "$HOST_ARCH" ] || {
    echo "package_appimage: cross AppImage builds are not supported (host $HOST_ARCH, requested $ARCH)" >&2
    echo "package_appimage: build on a matching host, or use the tarball/deb for cross releases" >&2
    exit 2
}

TOOL=$(sh tools/fetch_appimagetool.sh)

PREFIX="$ROOT/zig-out/appimage"
rm -rf "$PREFIX"
# Release binaries must not inherit the build host's CPU features. A native
# build on the CI runner emitted AVX-512 (the v0.6.0 AppImage trapped with
# SIGILL on an AMD Zen3 host); -Dcpu=baseline keeps the shipped binary portable.
./tools/zig build -Doptimize=ReleaseSafe -Dcpu=baseline --prefix "$PREFIX"
[ -x "$PREFIX/bin/xsprof" ] || {
    echo "package_appimage: binary missing after build" >&2
    exit 1
}

APPDIR="$ROOT/dist/appimage/Xsprof.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/xsprof/fixtures"
mkdir -p "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/scalable/apps"
cp "$PREFIX/bin/xsprof" "$APPDIR/usr/bin/xsprof"
chmod 755 "$APPDIR/usr/bin/xsprof"
cp fixtures/ui/healthy.ndjson "$APPDIR/usr/share/xsprof/fixtures/healthy.ndjson"
cp packaging/linux/xsprof.desktop "$APPDIR/usr/share/applications/xsprof.desktop"
cp packaging/linux/xsprof.svg "$APPDIR/usr/share/icons/hicolor/scalable/apps/xsprof.svg"
cp packaging/linux/xsprof.desktop "$APPDIR/xsprof.desktop"
cp packaging/linux/xsprof.svg "$APPDIR/xsprof.svg"
ln -sf xsprof.svg "$APPDIR/.DirIcon"

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
# xsprof AppImage entry point. With no arguments in a graphical session it
# opens the native console; otherwise it passes the CLI arguments through.
set -eu
APPDIR=${APPDIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
export XSPROF_FIXTURES_DIR="$APPDIR/usr/share/xsprof/fixtures"
if [ "$#" -eq 0 ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
    set -- ui
fi
exec "$APPDIR/usr/bin/xsprof" "$@"
APPRUN
chmod 755 "$APPDIR/AppRun"

# Fail closed on packaging regressions: no web assets and no bundled graphics
# driver/X11 libraries. Ship only the binary + data; the host supplies drivers.
if [ -e "$APPDIR/usr/share/xsprof/web" ] || find "$APPDIR" -name '*.wasm' | grep -q .; then
    echo "package_appimage: refusing to bundle web assets" >&2
    exit 1
fi
if find "$APPDIR" \( -name 'libX11*' -o -name 'libxcb*' -o -name 'libGL*' -o -name 'libEGL*' -o -name 'libgbm*' -o -name 'libdrm*' \) | grep -q .; then
    echo "package_appimage: refusing to bundle X11/GL drivers" >&2
    exit 1
fi
if find "$APPDIR" -name '*.so*' | grep -q .; then
    echo "package_appimage: refusing to bundle shared libraries" >&2
    exit 1
fi

mkdir -p "$ROOT/dist"
: "${SOURCE_DATE_EPOCH:=$(git log -1 --format=%ct 2>/dev/null || date +%s)}"
export SOURCE_DATE_EPOCH
OUT="$ROOT/dist/Xsprof-$VERSION-$ARCH.AppImage"
rm -f "$OUT"
echo "package_appimage: generating $OUT"
# appimagetool is an AppImage itself; APPIMAGE_EXTRACT_AND_RUN keeps this
# working on hosts without /dev/fuse (including CI runners).
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$ARCH" "$TOOL" --no-appstream "$APPDIR" "$OUT"
[ -x "$OUT" ] || { echo "package_appimage: appimagetool did not produce an executable AppImage" >&2; exit 1; }
chmod 755 "$OUT"
if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$ROOT/dist" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
else
    ( cd "$ROOT/dist" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
fi
echo "package_appimage: artifact $OUT"
