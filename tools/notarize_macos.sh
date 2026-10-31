#!/bin/sh
# Developer ID sign, notarize, and staple a macOS app bundle. Release-only:
# every credential is read from the environment and is never printed.
#
# Required:
#   MACOS_SIGN_IDENTITY  "Developer ID Application: ... (TEAMID)"
# and either
#   NOTARY_PROFILE       a notarytool keychain profile created beforehand
# or all of
#   APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD
set -eu
APP=${1:-}
[ -n "$APP" ] || { echo "notarize_macos: usage: $0 <Xsprof.app>" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || { echo "notarize_macos: macOS only" >&2; exit 2; }
[ -d "$APP" ] || { echo "notarize_macos: missing bundle $APP" >&2; exit 2; }
command -v xcrun >/dev/null 2>&1 || {
    echo "notarize_macos: xcrun unavailable; install Xcode command-line tools" >&2
    exit 2
}
identity=${MACOS_SIGN_IDENTITY:-}
[ -n "$identity" ] || {
    echo "notarize_macos: MACOS_SIGN_IDENTITY is required" >&2
    exit 2
}

submit() { # zip
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
        return
    fi
    if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ]; then
        echo "notarize_macos: set NOTARY_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD" >&2
        exit 2
    fi
    # notarytool reads @env: references itself, so the password never appears
    # in the process argument list.
    xcrun notarytool submit "$1" --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" --password "@env:APPLE_APP_PASSWORD" --wait
}

echo "notarize_macos: signing $APP"
codesign --force --options runtime --timestamp --sign "$identity" "$APP/Contents/MacOS/Xsprof"
codesign --force --options runtime --timestamp --sign "$identity" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
ditto -c -k --keepParent "$APP" "$TMP/notarize.zip"
echo "notarize_macos: submitting to the Apple notary service"
submit "$TMP/notarize.zip"

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
if command -v spctl >/dev/null 2>&1; then
    spctl --assess --type execute -vv "$APP" || {
        echo "notarize_macos: Gatekeeper assessment failed" >&2
        exit 1
    }
fi
echo "notarize_macos: PASS"
