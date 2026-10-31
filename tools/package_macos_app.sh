#!/bin/sh
# Build an ad-hoc-signed macOS .app bundle. Notarization needs an Apple identity.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' build.zig.zon | head -1)
APP="$ROOT/dist/Xsprof.app"
case "$APP" in
    "$ROOT"/dist/*) ;;
    *) echo "package_macos_app: refusing unexpected path $APP" >&2; exit 1 ;;
esac

./tools/zig build -Doptimize=ReleaseSafe
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web" "$APP/Contents/Resources/fixtures"
cp zig-out/bin/xsprof "$APP/Contents/MacOS/xsprof-real"
cp -R zig-out/web/. "$APP/Contents/Resources/web/"
cp fixtures/ui/healthy.ndjson "$APP/Contents/Resources/fixtures/healthy.ndjson"
sed "s/@VERSION@/$VERSION/g" packaging/macos/Info.plist > "$APP/Contents/Info.plist"
cat > "$APP/Contents/MacOS/Xsprof" <<'LAUNCH'
#!/bin/sh
exec "$(dirname "$0")/xsprof-real" ui
LAUNCH
chmod 755 "$APP/Contents/MacOS/Xsprof"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" 2>/dev/null || \
        echo "package_macos_app: ad-hoc codesign skipped (script launcher)" >&2
fi
mkdir -p "$ROOT/dist"
(cd "$ROOT/dist" && zip -qry "Xsprof-$VERSION-macos.zip" Xsprof.app)
echo "$ROOT/dist/Xsprof-$VERSION-macos.zip"
