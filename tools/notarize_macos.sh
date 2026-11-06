#!/bin/sh
# Developer ID sign, notarize, staple, and record a result JSON for a macOS
# app bundle. Release-only: every credential is read from the environment and
# is never printed. The signing identity must already exist in the keychain
# (CI imports a temporary keychain first).
#
# Required:
#   MACOS_SIGN_IDENTITY  "Developer ID Application: ... (TEAMID)"
# and either
#   NOTARY_PROFILE       a notarytool keychain profile created beforehand
# or all of
#   APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD
#
# Usage: sh tools/notarize_macos.sh [--result-json PATH] <Xsprof.app>
# The result JSON is also written to $XSPROF_NOTARY_RESULT when that variable is
# set; it is the input to tools/verify_macos_artifact.sh and is not a substitute
# for that verifier or for Gatekeeper.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RESULT=${XSPROF_NOTARY_RESULT:-}
APP=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --result-json) RESULT=${2:-}; shift 2 ;;
        --help|-h) echo "usage: sh tools/notarize_macos.sh [--result-json PATH] <Xsprof.app>" >&2; exit 2 ;;
        -*) echo "notarize_macos: unknown argument $1" >&2; exit 2 ;;
        *) APP=$1; shift ;;
    esac
done
[ -n "$APP" ] || { echo "notarize_macos: missing Xsprof.app argument" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || { echo "notarize_macos: macOS only" >&2; exit 2; }
[ -d "$APP" ] || { echo "notarize_macos: missing bundle $APP" >&2; exit 2; }
command -v xcrun >/dev/null 2>&1 || {
    echo "notarize_macos: xcrun unavailable; install Xcode command-line tools" >&2
    exit 2
}
command -v python3 >/dev/null 2>&1 || {
    echo "notarize_macos: python3 is required to write the result JSON" >&2
    exit 2
}
identity=${MACOS_SIGN_IDENTITY:-}
[ -n "$identity" ] || {
    echo "notarize_macos: MACOS_SIGN_IDENTITY is required" >&2
    exit 2
}
team=$(printf '%s\n' "$identity" | sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\))$/\1/p')
[ -n "$team" ] || {
    echo "notarize_macos: MACOS_SIGN_IDENTITY must end with a (TEAMID)" >&2
    exit 2
}
if command -v security >/dev/null 2>&1; then
    security find-identity -v -p codesigning | grep -F "$identity" >/dev/null || {
        echo "notarize_macos: signing identity not found in the keychain: $identity" >&2
        exit 2
    }
fi

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

notary_log() { # submission id
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool log "$1" --keychain-profile "$NOTARY_PROFILE"
    else
        xcrun notarytool log "$1" --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" --password "@env:APPLE_APP_PASSWORD"
    fi
}

echo "notarize_macos: signing $APP"
codesign --force --options runtime --timestamp --sign "$identity" "$APP/Contents/MacOS/Xsprof"
codesign --force --options runtime --timestamp --sign "$identity" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
ditto -c -k --keepParent "$APP" "$TMP/notarize.zip"
LOG="$TMP/notarytool.log"
echo "notarize_macos: submitting to the Apple notary service"
if ! submit "$TMP/notarize.zip" >"$LOG" 2>&1; then
    cat "$LOG" >&2
    echo "notarize_macos: notarytool submission failed" >&2
    exit 1
fi
cat "$LOG"
submission=$(sed -n 's/^ *id: *//p' "$LOG" | head -1)
status=$(sed -n 's/^ *status: *//p' "$LOG" | tail -1)
if [ -z "$submission" ]; then
    echo "notarize_macos: could not determine the notarization submission id" >&2
    exit 1
fi
if [ "$status" != "Accepted" ]; then
    echo "notarize_macos: notarization status is '$status', not Accepted" >&2
    notary_log "$submission" >&2 || true
    exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
if command -v spctl >/dev/null 2>&1; then
    spctl --assess --type execute -vv "$APP" || {
        echo "notarize_macos: Gatekeeper assessment failed" >&2
        exit 1
    }
fi

if [ -z "$RESULT" ]; then
    RESULT=$(dirname "$APP")/notarization-result.json
fi
mkdir -p "$(dirname "$RESULT")"
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
XSPROF_RESULT_JSON="$RESULT" XSPROF_RESULT_ID="$submission" XSPROF_RESULT_TEAM="$team" \
XSPROF_RESULT_IDENTITY="$identity" XSPROF_RESULT_CREATED_AT="$CREATED_AT" \
python3 - <<'PY'
import json
import os
import sys

path = os.environ["XSPROF_RESULT_JSON"]
data = {
    "created_at": os.environ["XSPROF_RESULT_CREATED_AT"],
    "identity": os.environ["XSPROF_RESULT_IDENTITY"],
    "schema": "xsprof/notary-result/v1",
    "status": "Accepted",
    "submission_id": os.environ["XSPROF_RESULT_ID"],
    "team_id": os.environ["XSPROF_RESULT_TEAM"],
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(tmp, path)
PY
echo "notarize_macos: PASS (submission $submission, result $RESULT)"
