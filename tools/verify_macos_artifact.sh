#!/bin/sh
# Verify a built macOS app + zip and write the xsprof/macos-notarization/v1
# attestation consumed by tools/verify_macos_attestation.py.
#
# macOS only. This script never fabricates notarization: without a successful
# notary result JSON it fails closed unless --allow-unnotarized is given, and
# the unsigned attestation explicitly records notarized=false.
#
# Usage:
#   sh tools/verify_macos_artifact.sh --app DIST/Xsprof.app --zip FILE \
#       --version VERSION --attestation-out FILE \
#       [--notary-result FILE] [--allow-unnotarized] [--require-universal]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP=
ZIP=
OUT=
VERSION=
NOTARY_RESULT=
ALLOW=0
UNIVERSAL=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app) APP=${2:-}; shift 2 ;;
        --zip) ZIP=${2:-}; shift 2 ;;
        --version) VERSION=${2:-}; shift 2 ;;
        --attestation-out) OUT=${2:-}; shift 2 ;;
        --notary-result) NOTARY_RESULT=${2:-}; shift 2 ;;
        --allow-unnotarized) ALLOW=1; shift ;;
        --require-universal) UNIVERSAL=1; shift ;;
        --help|-h)
            echo "usage: sh tools/verify_macos_artifact.sh --app DIR --zip FILE --version V --attestation-out FILE [--notary-result FILE] [--allow-unnotarized] [--require-universal]" >&2
            exit 2 ;;
        -*) echo "verify_macos_artifact: unknown argument $1" >&2; exit 2 ;;
        *) echo "verify_macos_artifact: unexpected argument $1" >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Darwin ] || { echo "verify_macos_artifact: macOS only" >&2; exit 2; }
for value in "$APP" "$ZIP" "$VERSION" "$OUT"; do
    [ -n "$value" ] || { echo "verify_macos_artifact: --app --zip --version --attestation-out are required" >&2; exit 2; }
done
[ -d "$APP" ] || { echo "verify_macos_artifact: missing app bundle $APP" >&2; exit 2; }
[ -f "$ZIP" ] || { echo "verify_macos_artifact: missing zip $ZIP" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "verify_macos_artifact: python3 is required" >&2; exit 2; }
command -v ditto >/dev/null 2>&1 || { echo "verify_macos_artifact: ditto is required" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
ditto -x -k "$ZIP" "$TMP/extracted"
APP_NAME=$(basename "$APP")
VAPP="$TMP/extracted/$APP_NAME"
[ -d "$VAPP" ] || { echo "verify_macos_artifact: zip does not contain $APP_NAME" >&2; exit 1; }
EXEC="$VAPP/Contents/MacOS/Xsprof"
[ -x "$EXEC" ] || { echo "verify_macos_artifact: zip app is missing Contents/MacOS/Xsprof" >&2; exit 1; }

plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VAPP/Contents/Info.plist" 2>/dev/null || true)
[ "$plist_version" = "$VERSION" ] || {
    echo "verify_macos_artifact: Info.plist version '$plist_version' != $VERSION" >&2
    exit 1
}
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$VAPP/Contents/Info.plist" 2>/dev/null || true)
[ -n "$bundle_id" ] || { echo "verify_macos_artifact: missing CFBundleIdentifier" >&2; exit 1; }

archs=$(lipo -archs "$EXEC" 2>/dev/null || true)
[ -n "$archs" ] || { echo "verify_macos_artifact: lipo could not read architectures" >&2; exit 1; }
if [ "$UNIVERSAL" = 1 ]; then
    case " $archs " in *" arm64 "*) ;; *) echo "verify_macos_artifact: universal build missing arm64 ($archs)" >&2; exit 1 ;; esac
    case " $archs " in *" x86_64 "*) ;; *) echo "verify_macos_artifact: universal build missing x86_64 ($archs)" >&2; exit 1 ;; esac
fi

SHA256=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
SIZE_BYTES=$(wc -c < "$ZIP" | tr -d ' ')
NAME=$(basename "$ZIP")
NOTARIZED=0
IDENTITY="ad-hoc"
TEAM=""
SUBMISSION=""
if [ -n "$NOTARY_RESULT" ] && [ -f "$NOTARY_RESULT" ]; then
    fields=$(python3 - "$NOTARY_RESULT" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError) as error:
    print(f"verify_macos_artifact: unreadable notary result: {error}", file=sys.stderr)
    sys.exit(3)
if data.get("schema") != "xsprof/notary-result/v1" or data.get("status") != "Accepted":
    print("verify_macos_artifact: notary result is not an accepted xsprof/notary-result/v1", file=sys.stderr)
    sys.exit(3)
for key in ("identity", "team_id", "submission_id"):
    value = data.get(key)
    if not isinstance(value, str) or not value:
        print(f"verify_macos_artifact: notary result is missing {key}", file=sys.stderr)
        sys.exit(3)
    print(value)
PY
) || exit 1
    IDENTITY=$(printf '%s\n' "$fields" | sed -n 1p)
    TEAM=$(printf '%s\n' "$fields" | sed -n 2p)
    SUBMISSION=$(printf '%s\n' "$fields" | sed -n 3p)
    NOTARIZED=1
fi

if [ "$NOTARIZED" = 1 ]; then
    codesign_info=$(codesign -dv --verbose=4 "$VAPP" 2>&1 || true)
    case "$codesign_info" in
        *"Authority=Developer ID Application:"*) ;;
        *) echo "verify_macos_artifact: bundle is not Developer ID signed" >&2; exit 1 ;;
    esac
    case "$codesign_info" in
        *"TeamIdentifier=$TEAM"*) ;;
        *) echo "verify_macos_artifact: TeamIdentifier does not match the notary result" >&2; exit 1 ;;
    esac
    case "$codesign_info" in
        *"flags=0x"*"runtime"*) ;;
        *) echo "verify_macos_artifact: hardened runtime flag missing" >&2; exit 1 ;;
    esac
    codesign --verify --deep --strict --verbose=2 "$VAPP"
    xcrun stapler validate "$VAPP"
    spctl --assess --type execute -vv "$VAPP"
    NAME_PATTERN="Xsprof-${VERSION}-macos.zip"
    [ "$NAME" = "$NAME_PATTERN" ] || {
        echo "verify_macos_artifact: notarized zip must be $NAME_PATTERN, got $NAME" >&2
        exit 1
    }
else
    [ "$ALLOW" = 1 ] || {
        echo "verify_macos_artifact: no accepted notarization result; refusing to attest (pass --allow-unnotarized only for labelled unsigned builds)" >&2
        exit 3
    }
    case "$NAME" in
        *-macos-unsigned.zip) ;;
        *) echo "verify_macos_artifact: unsigned zip must end with -macos-unsigned.zip, got $NAME" >&2; exit 1 ;;
    esac
    codesign_info=$(codesign -dv --verbose=4 "$VAPP" 2>&1 || true)
    case "$codesign_info" in
        *"Authority=Developer ID Application:"*)
            echo "verify_macos_artifact: unsigned path must not carry a Developer ID signature" >&2
            exit 1 ;;
    esac
    IDENTITY="ad-hoc"
fi

mkdir -p "$(dirname "$OUT")"
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
XSPROF_ATT_OUT="$OUT" XSPROF_ATT_NAME="$NAME" XSPROF_ATT_SHA="$SHA256" \
XSPROF_ATT_SIZE="$SIZE_BYTES" XSPROF_ATT_VERSION="$VERSION" \
XSPROF_ATT_NOTARIZED="$NOTARIZED" XSPROF_ATT_IDENTITY="$IDENTITY" \
XSPROF_ATT_TEAM="$TEAM" XSPROF_ATT_SUBMISSION="$SUBMISSION" \
XSPROF_ATT_CREATED_AT="$CREATED_AT" python3 - <<'PY'
import json
import os

notarized = os.environ["XSPROF_ATT_NOTARIZED"] == "1"
data = {
    "artifact": {
        "name": os.environ["XSPROF_ATT_NAME"],
        "sha256": os.environ["XSPROF_ATT_SHA"],
        "size_bytes": int(os.environ["XSPROF_ATT_SIZE"]),
    },
    "created_at": os.environ["XSPROF_ATT_CREATED_AT"],
    "notarized": notarized,
    "notarization": {
        "gatekeeper": "accepted" if notarized else "rejected",
        "stapled": bool(notarized),
        "status": "Accepted" if notarized else "NotNotarized",
        "submission_id": os.environ["XSPROF_ATT_SUBMISSION"] if notarized else "",
    },
    "schema": "xsprof/macos-notarization/v1",
    "signing": {
        "hardened_runtime": bool(notarized),
        "identity": os.environ["XSPROF_ATT_IDENTITY"] if notarized else "ad-hoc",
        "team_id": os.environ["XSPROF_ATT_TEAM"],
    },
    "version": os.environ["XSPROF_ATT_VERSION"],
}
tmp = os.environ["XSPROF_ATT_OUT"] + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(tmp, os.environ["XSPROF_ATT_OUT"])
PY

if [ "$NOTARIZED" = 1 ]; then
    echo "verify_macos_artifact: PASS (notarized, stapled, Gatekeeper accepted, $NAME)"
    echo "verify_macos_artifact: attestation $OUT"
else
    echo "verify_macos_artifact: PASS (UNSIGNED / NOT NOTARIZED; labelled $NAME)"
    echo "verify_macos_artifact: attestation $OUT"
fi
