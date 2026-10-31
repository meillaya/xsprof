#!/bin/sh
# Build a macOS .app bundle. Ad-hoc signing works offline; set
# XSPROF_SIGN_IDENTITY (Developer ID Application) and XSPROF_NOTARIZE=1 for a
# notarized release. The bundle's main executable is the real binary; the
# XSPROF_APP_MODE environment entry in Info.plist selects `ui`.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' build.zig.zon | head -1)
APP="$ROOT/dist/Xsprof.app"
case "$APP" in
    "$ROOT"/dist/*) ;;
    *) echo "package_macos_app: refusing unexpected path $APP" >&2; exit 1 ;;
esac

./tools/zig build web
./tools/zig build -Doptimize=ReleaseSafe
if [ "${XSPROF_UNIVERSAL:-0}" = 1 ]; then
    command -v lipo >/dev/null 2>&1 || {
        echo "package_macos_app: lipo is required for a universal bundle" >&2
        exit 1
    }
    sdk=$(xcrun --show-sdk-path 2>/dev/null) || {
        echo "package_macos_app: the macOS SDK is required for a universal bundle" >&2
        exit 1
    }
    host_arch=$(uname -m)
    if [ "$host_arch" = arm64 ]; then
        ./tools/zig build -Doptimize=ReleaseSafe --prefix zig-out/macos-native
        ./tools/zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos             -Dmacos-sdk="$sdk" --prefix zig-out/macos-cross
    else
        ./tools/zig build -Doptimize=ReleaseSafe --prefix zig-out/macos-native
        ./tools/zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos             -Dmacos-sdk="$sdk" --prefix zig-out/macos-cross
    fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web" "$APP/Contents/Resources/fixtures"
if [ "${XSPROF_UNIVERSAL:-0}" = 1 ]; then
    lipo -create \
        zig-out/macos-native/bin/xsprof \
        zig-out/macos-cross/bin/xsprof \
        -output "$APP/Contents/MacOS/Xsprof"
else
    cp zig-out/bin/xsprof "$APP/Contents/MacOS/Xsprof"
fi
chmod 755 "$APP/Contents/MacOS/Xsprof"
cp -R zig-out/web/. "$APP/Contents/Resources/web/"
cp fixtures/ui/healthy.ndjson "$APP/Contents/Resources/fixtures/healthy.ndjson"
sed "s/@VERSION@/$VERSION/g" packaging/macos/Info.plist > "$APP/Contents/Info.plist"

identity=${XSPROF_SIGN_IDENTITY:-}
if [ -n "$identity" ]; then
    codesign --force --options runtime --timestamp \
        --sign "$identity" "$APP/Contents/MacOS/Xsprof"
    codesign --force --options runtime --timestamp --sign "$identity" "$APP"
else
    codesign --force --sign - "$APP/Contents/MacOS/Xsprof" 2>/dev/null || true
    codesign --force --sign - "$APP" 2>/dev/null || \
        echo "package_macos_app: ad-hoc codesign skipped" >&2
fi
if command -v codesign >/dev/null 2>&1; then
    codesign --verify --strict --verbose=1 "$APP"
fi

if [ "${XSPROF_NOTARIZE:-0}" = 1 ]; then
    sh "$ROOT/tools/notarize_macos.sh" "$APP"
fi

mkdir -p "$ROOT/dist"
(cd "$ROOT/dist" && zip -qry "Xsprof-$VERSION-macos.zip" Xsprof.app)
echo "$ROOT/dist/Xsprof-$VERSION-macos.zip"
