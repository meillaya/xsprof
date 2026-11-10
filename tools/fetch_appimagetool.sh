#!/bin/sh
# Fetch and verify the pinned appimagetool AppImage.
#
# Pinned release: appimagetool 1.9.1 (2025-11-18). The SHA256 values are the
# official release assets. Downloads are cached under .tools/downloads so
# repeated builds are offline; a cached file is re-verified every run.
#
# appimagetool is itself an AppImage. Hosts without FUSE run it with
# APPIMAGE_EXTRACT_AND_RUN=1 (tools/package_appimage.sh does this).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=1.9.1
ARCH=${XSPROF_APPIMAGE_ARCH:-$(uname -m)}
case "$ARCH" in
    x86_64)
        SHA256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 ;;
    aarch64|arm64)
        ARCH=aarch64
        SHA256=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158 ;;
    *)
        echo "fetch_appimagetool: unsupported architecture: $ARCH (x86_64/aarch64)" >&2
        exit 2 ;;
esac

# The release asset names do not include the version:
#   appimagetool-x86_64.AppImage / appimagetool-aarch64.AppImage
ASSET="appimagetool-${ARCH}.AppImage"
NAME="appimagetool-${VERSION}-${ARCH}.AppImage"
CACHE="$ROOT/.tools/downloads/$NAME"
URL="https://github.com/AppImage/appimagetool/releases/download/$VERSION/$ASSET"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

verify() {
    [ -f "$1" ] || return 1
    [ "$(sha256_of "$1")" = "$SHA256" ]
}

if ! verify "$CACHE"; then
    if [ -f "$CACHE" ]; then
        echo "fetch_appimagetool: cached file has the wrong hash; redownloading" >&2
        rm -f "$CACHE"
    fi
    command -v curl >/dev/null 2>&1 || {
        echo "fetch_appimagetool: curl is required to download appimagetool" >&2
        exit 2
    }
    mkdir -p "$ROOT/.tools/downloads"
    TMP="$CACHE.part.$$"
    trap 'rm -f "$TMP"' EXIT HUP INT TERM
    echo "fetch_appimagetool: downloading $NAME" >&2
    curl -fL --retry 3 --connect-timeout 15 -o "$TMP" "$URL"
    if ! verify "$TMP"; then
        rm -f "$TMP"
        echo "fetch_appimagetool: sha256 mismatch for $NAME (expected $SHA256)" >&2
        exit 1
    fi
    mv "$TMP" "$CACHE"
    trap - EXIT HUP INT TERM
fi
chmod +x "$CACHE"
echo "fetch_appimagetool: $CACHE (verified, $VERSION $ARCH)" >&2
printf '%s\n' "$CACHE"
