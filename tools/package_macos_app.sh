#!/bin/sh
# Build a macOS .app bundle, sign/notarize/label it honestly, verify the
# notarization, and write the xsprof/macos-notarization/v1 attestation.
#
# Release path (requires Developer ID credentials and macOS):
#   XSPROF_UNIVERSAL=1 XSPROF_SIGN_IDENTITY="Developer ID Application: ... (TEAMID)" \
#   XSPROF_NOTARIZE=1 [NOTARY_PROFILE=...| APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD] \
#   sh tools/package_macos_app.sh
#   -> dist/Xsprof-<v>-macos.zip (notarized, stapled, attested)
#
# No-credential path (local/ad-hoc; NEVER labelled notarized):
#   sh tools/package_macos_app.sh
#   -> dist/Xsprof-<v>-macos-unsigned.zip (ad-hoc signed, notarized=false)
#
# The bundle's main executable is the real binary; the XSPROF_APP_MODE
# environment entry in Info.plist selects "ui".
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = Darwin ] || { echo "package_macos_app: macOS only" >&2; exit 2; }
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' build.zig.zon | head -1)
APP="$ROOT/dist/Xsprof.app"
case "$APP" in
    "$ROOT"/dist/*) ;;
    *) echo "package_macos_app: refusing unexpected path $APP" >&2; exit 1 ;;
esac

UNIVERSAL=${XSPROF_UNIVERSAL:-0}
NOTARIZE=${XSPROF_NOTARIZE:-0}
identity=${XSPROF_SIGN_IDENTITY:-${MACOS_SIGN_IDENTITY:-}}

./tools/zig build -Doptimize=ReleaseSafe
if [ "$UNIVERSAL" = 1 ]; then
    command -v lipo >/dev/null 2>&1 || {
        echo "package_macos_app: lipo is required for a universal bundle" >&2
        exit 1
    }
    sdk=$(xcrun --show-sdk-path 2>/dev/null) || {
        echo "package_macos_app: the macOS SDK is required for a universal bundle" >&2
        exit 1
    }
    case "$(uname -m)" in
        arm64)
            ./tools/zig build -Doptimize=ReleaseSafe --prefix zig-out/macos-native
            ./tools/zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos -Dmacos-sdk="$sdk" --prefix zig-out/macos-cross ;;
        x86_64)
            ./tools/zig build -Doptimize=ReleaseSafe --prefix zig-out/macos-native
            ./tools/zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos -Dmacos-sdk="$sdk" --prefix zig-out/macos-cross ;;
        *)
            echo "package_macos_app: unsupported host architecture $(uname -m)" >&2
            exit 1 ;;
    esac
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fixtures"
if [ "$UNIVERSAL" = 1 ]; then
    lipo -create \
        zig-out/macos-native/bin/xsprof \
        zig-out/macos-cross/bin/xsprof \
        -output "$APP/Contents/MacOS/Xsprof"
    archs=$(lipo -archs "$APP/Contents/MacOS/Xsprof")
    case " $archs " in *" arm64 "*) ;; *) echo "package_macos_app: universal build missing arm64 ($archs)" >&2; exit 1 ;; esac
    case " $archs " in *" x86_64 "*) ;; *) echo "package_macos_app: universal build missing x86_64 ($archs)" >&2; exit 1 ;; esac
else
    cp zig-out/bin/xsprof "$APP/Contents/MacOS/Xsprof"
fi
chmod 755 "$APP/Contents/MacOS/Xsprof"
cp fixtures/ui/healthy.ndjson "$APP/Contents/Resources/fixtures/healthy.ndjson"
sed "s/@VERSION@/$VERSION/g" packaging/macos/Info.plist > "$APP/Contents/Info.plist"

[ -n "$identity" ] || identity=""
if [ "$NOTARIZE" = 1 ]; then
    [ -n "$identity" ] || {
        echo "package_macos_app: XSPROF_NOTARIZE=1 requires XSPROF_SIGN_IDENTITY" >&2
        echo "package_macos_app: refusing to publish an unsigned app as notarized" >&2
        exit 2
    }
    export MACOS_SIGN_IDENTITY="$identity"
    RESULT="$ROOT/dist/Xsprof-$VERSION-macos-notary-result.json"
    sh "$ROOT/tools/notarize_macos.sh" --result-json "$RESULT" "$APP"
    ZIP="$ROOT/dist/Xsprof-$VERSION-macos.zip"
    ATTEST="$ROOT/dist/Xsprof-$VERSION-macos-notarization.json"
    mkdir -p "$ROOT/dist"
    ( cd "$ROOT/dist" && ditto -c -k --keepParent Xsprof.app "Xsprof-$VERSION-macos.zip" )
    if [ "$UNIVERSAL" = 1 ]; then
        sh "$ROOT/tools/verify_macos_artifact.sh" --app "$APP" --zip "$ZIP" \
            --version "$VERSION" --attestation-out "$ATTEST" \
            --notary-result "$RESULT" --require-universal
    else
        sh "$ROOT/tools/verify_macos_artifact.sh" --app "$APP" --zip "$ZIP" \
            --version "$VERSION" --attestation-out "$ATTEST" --notary-result "$RESULT"
    fi
else
    if [ -n "$identity" ]; then
        echo "package_macos_app: XSPROF_SIGN_IDENTITY is ignored without XSPROF_NOTARIZE=1" >&2
        echo "package_macos_app: producing a labelled UNSIGNED build (ad-hoc signed)" >&2
    fi
    # Ad-hoc signing is intentionally best-effort offline; the output name and
    # attestation always say it is not notarized.
    codesign --force --sign - "$APP/Contents/MacOS/Xsprof" 2>/dev/null || true
    codesign --force --sign - "$APP" 2>/dev/null || true
    if command -v codesign >/dev/null 2>&1; then
        codesign --verify --strict --verbose=1 "$APP" || {
            echo "package_macos_app: ad-hoc bundle verification failed" >&2
            exit 1
        }
    fi
    mkdir -p "$ROOT/dist"
    ZIP="$ROOT/dist/Xsprof-$VERSION-macos-unsigned.zip"
    ATTEST="$ROOT/dist/Xsprof-$VERSION-macos-unsigned-notarization.json"
    ( cd "$ROOT/dist" && ditto -c -k --keepParent Xsprof.app "Xsprof-$VERSION-macos-unsigned.zip" )
    if [ "$UNIVERSAL" = 1 ]; then
        sh "$ROOT/tools/verify_macos_artifact.sh" --app "$APP" --zip "$ZIP" \
            --version "$VERSION" --attestation-out "$ATTEST" \
            --allow-unnotarized --require-universal
    else
        sh "$ROOT/tools/verify_macos_artifact.sh" --app "$APP" --zip "$ZIP" \
            --version "$VERSION" --attestation-out "$ATTEST" --allow-unnotarized
    fi
fi

( cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )
echo "package_macos_app: artifact $ZIP"
echo "package_macos_app: attestation $ATTEST"
if [ "$NOTARIZE" = 1 ]; then
    echo "package_macos_app: NOTARIZED (Developer ID signed, notarized, stapled; cask-eligible)"
else
    echo "package_macos_app: UNSIGNED / NOT NOTARIZED (cask-ineligible; do not distribute as a release)"
fi
