#!/bin/sh
# Smoke-test a built xsprof AppImage without FUSE and without opening a window.
# It extracts the AppImage, checks the AppDir contents (native binary, fixture,
# desktop entry, icon, AppRun; no web assets; no bundled X11/GL drivers),
# verifies the binary has no instructions above the CPU baseline
# (qa/cpu_portability.sh: VEX/EVEX on x86_64, SVE/SVE2 on aarch64), runs
# version/help and a headless CPU snapshot through AppRun, and also runs the
# AppImage runtime path with APPIMAGE_EXTRACT_AND_RUN=1.
#
# Usage: sh qa/appimage_smoke.sh --appimage FILE [--version VERSION]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APPIMAGE=
VERSION=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --appimage) APPIMAGE=${2:-}; shift 2 ;;
        --version) VERSION=${2:-}; shift 2 ;;
        --help|-h) echo "usage: sh qa/appimage_smoke.sh --appimage FILE [--version VERSION]" >&2; exit 2 ;;
        *) echo "appimage_smoke: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$APPIMAGE" ] || { echo "appimage_smoke: --appimage is required" >&2; exit 2; }
[ -f "$APPIMAGE" ] || { echo "appimage_smoke: missing AppImage $APPIMAGE" >&2; exit 2; }
APPIMAGE=$(CDPATH= cd -- "$(dirname -- "$APPIMAGE")" && pwd)/$(basename -- "$APPIMAGE")
[ -x "$APPIMAGE" ] || { echo "appimage_smoke: AppImage is not executable" >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "appimage_smoke: AppImage is Linux-only" >&2; exit 2; }
if [ -z "$VERSION" ]; then
    VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' "$ROOT/build.zig.zon" | head -1)
fi
[ -n "$VERSION" ] || { echo "appimage_smoke: cannot determine expected version" >&2; exit 2; }

if [ -f "$APPIMAGE.sha256" ]; then
    expected=$(cut -d' ' -f1 < "$APPIMAGE.sha256")
    actual=$(sha256sum "$APPIMAGE" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$APPIMAGE" | cut -d' ' -f1)
    [ "$expected" = "$actual" ] || { echo "appimage_smoke: sha256 mismatch" >&2; exit 1; }
    echo "appimage_smoke: PASS sha256"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

echo "appimage_smoke: extracting AppDir"
( cd "$TMP" && "$APPIMAGE" --appimage-extract >/dev/null 2>&1 ) || {
    echo "appimage_smoke: --appimage-extract failed" >&2
    exit 1
}
SQ="$TMP/squashfs-root"
[ -d "$SQ" ] || { echo "appimage_smoke: extraction produced no squashfs-root" >&2; exit 1; }

for path in AppRun usr/bin/xsprof usr/share/xsprof/fixtures/healthy.ndjson xsprof.desktop xsprof.svg; do
    [ -e "$SQ/$path" ] || { echo "appimage_smoke: AppDir missing $path" >&2; exit 1; }
done
[ -x "$SQ/AppRun" ] || { echo "appimage_smoke: AppRun is not executable" >&2; exit 1; }
[ -x "$SQ/usr/bin/xsprof" ] || { echo "appimage_smoke: usr/bin/xsprof is not executable" >&2; exit 1; }

# Web assets must not ship in the AppImage.
[ ! -e "$SQ/usr/share/xsprof/web" ] || { echo "appimage_smoke: AppImage contains web assets" >&2; exit 1; }
if find "$SQ" -name '*.wasm' | grep -q .; then
    echo "appimage_smoke: AppImage contains wasm assets" >&2
    exit 1
fi

# No bundled X11/GL/mesa driver libraries: the host supplies them.
if find "$SQ" \( -name 'libX11*' -o -name 'libxcb*' -o -name 'libGL*' -o -name 'libEGL*' -o -name 'libgbm*' -o -name 'libdrm*' -o -name '*.so*' \) | grep -q .; then
    echo "appimage_smoke: AppImage bundles X11/GL/driver/shared libraries" >&2
    exit 1
fi

# The binary is dynamically linked only to the system libc; GUI libraries stay
# runtime-dlopened.
if command -v readelf >/dev/null 2>&1; then
    if readelf -d "$SQ/usr/bin/xsprof" 2>/dev/null | grep -E 'NEEDED.*lib(X11|GL|EGL|gbm|drm|xcb)' >/dev/null; then
        echo "appimage_smoke: binary has a link-time X11/GL dependency" >&2
        exit 1
    fi
fi

# A native-CPU build from an AVX-512 runner traps with SIGILL on older hosts and
# still runs on its build host, so executing the artifact cannot catch it.
# Inspect the machine code instead; the release lane runs this fail-closed via
# XSPROF_REQUIRE_TOOLS=1, so missing inspection tools fail rather than skip.
echo "appimage_smoke: checking CPU portability of the extracted binary"
if ! sh "$ROOT/qa/cpu_portability.sh" --binary "$SQ/usr/bin/xsprof"; then
    echo "appimage_smoke: FAIL (AppImage binary is not CPU-baseline portable)" >&2
    exit 1
fi

echo "appimage_smoke: running AppRun version/help/snapshot"
"$SQ/AppRun" version | grep -Fx "xsprof $VERSION" >/dev/null
"$SQ/AppRun" help >/dev/null
"$SQ/AppRun" snapshot --replay "$SQ/usr/share/xsprof/fixtures/healthy.ndjson" \
    --out "$TMP/snapshot.png" --width 320 --height 240
[ -s "$TMP/snapshot.png" ] || { echo "appimage_smoke: CPU snapshot is empty" >&2; exit 1; }

echo "appimage_smoke: running the AppImage runtime without FUSE"
APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGE" version | grep -Fx "xsprof $VERSION" >/dev/null

echo "appimage_smoke: PASS (version $VERSION; no web assets; no bundled drivers)"
