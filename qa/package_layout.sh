#!/bin/sh
# Assert release tarball, Debian and AppImage layouts. Native-only: no web/
# WASM assets ship in any package. Every packaged binary that can be reached is
# also checked for CPU-readiness against the architecture baseline with
# qa/cpu_portability.sh (x86_64: no VEX/EVEX instructions; aarch64: no SVE/
# SVE2), so a native-CPU build cannot ship again (v0.6.0 AppImage SIGILL).
# Usage: sh qa/package_layout.sh [--tarball FILE] [--deb FILE] [--appimage FILE]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARBALL=
DEB=
APPIMAGE=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tarball) TARBALL=${2:-}; shift 2 ;;
        --deb) DEB=${2:-}; shift 2 ;;
        --appimage) APPIMAGE=${2:-}; shift 2 ;;
        --help|-h) echo "usage: sh qa/package_layout.sh [--tarball FILE] [--deb FILE] [--appimage FILE]" >&2; exit 2 ;;
        *) echo "package_layout: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$TARBALL" ] || [ -n "$DEB" ] || [ -n "$APPIMAGE" ] || {
    echo "package_layout: pass at least one of --tarball, --deb, --appimage" >&2
    exit 2
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

check_sidecar_sha256() { # artifact
    [ -f "$1.sha256" ] || return 0
    expected=$(cut -d' ' -f1 < "$1.sha256")
    actual=$(sha256_of "$1")
    [ "$expected" = "$actual" ] || { echo "package_layout: sha256 mismatch for $1" >&2; exit 1; }
    echo "package_layout: PASS sha256 $(basename "$1")"
}

reject_web_assets() { # label path-list
    label=$1
    listing=$2
    if grep -Eq 'xsprof/web|xsprof-web\.wasm|[^/]\.wasm$' "$listing"; then
        echo "package_layout: $label contains web/WASM assets" >&2
        exit 1
    fi
}

check_cpu_portability() { # label binary
    label=$1
    binary=$2
    echo "package_layout: checking CPU portability of $label"
    if ! sh "$ROOT/qa/cpu_portability.sh" --binary "$binary"; then
        echo "package_layout: FAIL ($label is not CPU-baseline portable)" >&2
        exit 1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

if [ -n "$TARBALL" ]; then
    [ -f "$TARBALL" ] || { echo "package_layout: missing tarball $TARBALL" >&2; exit 2; }
    check_sidecar_sha256 "$TARBALL"
    root=$(tar -tzf "$TARBALL" | head -1 | cut -d/ -f1)
    [ -n "$root" ] || { echo "package_layout: empty tarball" >&2; exit 1; }
    listing="$TMP/tarball-listing"
    tar -tzf "$TARBALL" > "$listing"
    reject_web_assets "tarball" "$listing"
    required="bin/xsprof
share/xsprof/fixtures/healthy.ndjson
share/applications/xsprof.desktop
share/icons/hicolor/scalable/apps/xsprof.svg
share/bash-completion/completions/xsprof
share/zsh/site-functions/_xsprof
share/fish/vendor_completions.d/xsprof.fish
lib/sysusers.d/xsprof.conf
share/doc/xsprof/LICENSE"
    case "$(basename "$TARBALL")" in
        *-linux-*) required="$required
lib/systemd/system/xsprof-recorder.service" ;;
    esac
    printf '%s\n' "$required" | while IFS= read -r path; do
        [ -n "$path" ] || continue
        grep -qx "$root/$path" "$listing" || {
            echo "package_layout: tarball missing $root/$path" >&2
            exit 1
        }
    done
    tar -xzf "$TARBALL" -C "$TMP"
    [ -x "$TMP/$root/bin/xsprof" ] || { echo "package_layout: bin/xsprof is not executable" >&2; exit 1; }
    check_cpu_portability "tarball bin/xsprof" "$TMP/$root/bin/xsprof"
    echo "package_layout: PASS tarball layout"
fi

if [ -n "$APPIMAGE" ]; then
    [ -f "$APPIMAGE" ] || { echo "package_layout: missing AppImage $APPIMAGE" >&2; exit 2; }
    [ -x "$APPIMAGE" ] || { echo "package_layout: AppImage is not executable" >&2; exit 2; }
    APPIMAGE=$(CDPATH= cd -- "$(dirname -- "$APPIMAGE")" && pwd)/$(basename -- "$APPIMAGE")
    check_sidecar_sha256 "$APPIMAGE"
    mkdir -p "$TMP/appimage"
    ( cd "$TMP/appimage" && "$APPIMAGE" --appimage-extract >/dev/null 2>&1 ) || {
        echo "package_layout: AppImage extraction failed" >&2
        exit 1
    }
    SQ="$TMP/appimage/squashfs-root"
    [ -d "$SQ" ] || { echo "package_layout: AppImage extraction produced no AppDir" >&2; exit 1; }
    for path in AppRun usr/bin/xsprof usr/share/xsprof/fixtures/healthy.ndjson xsprof.desktop xsprof.svg; do
        [ -e "$SQ/$path" ] || { echo "package_layout: AppImage missing $path" >&2; exit 1; }
    done
    [ -x "$SQ/AppRun" ] || { echo "package_layout: AppImage AppRun is not executable" >&2; exit 1; }
    [ -x "$SQ/usr/bin/xsprof" ] || { echo "package_layout: AppImage binary is not executable" >&2; exit 1; }
    check_cpu_portability "AppImage usr/bin/xsprof" "$SQ/usr/bin/xsprof"
    find "$SQ" -type f > "$TMP/appimage-listing"
    reject_web_assets "AppImage" "$TMP/appimage-listing"
    if find "$SQ" \( -name 'libX11*' -o -name 'libxcb*' -o -name 'libGL*' -o -name 'libEGL*' -o -name 'libgbm*' -o -name 'libdrm*' -o -name '*.so*' \) | grep -q .; then
        echo "package_layout: AppImage bundles X11/GL/driver/shared libraries" >&2
        exit 1
    fi
    echo "package_layout: PASS AppImage layout"
fi

if [ -n "$DEB" ]; then
    [ -f "$DEB" ] || { echo "package_layout: missing deb $DEB" >&2; exit 2; }
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        echo "package_layout: SKIP deb layout (dpkg-deb unavailable)"
    else
        check_sidecar_sha256 "$DEB"
        dpkg-deb --info "$DEB" > "$TMP/deb-info"
        grep -q 'Package: xsprof' "$TMP/deb-info"
        grep -Eq 'Version: [0-9]+\.[0-9]+\.[0-9]+-[0-9]+' "$TMP/deb-info"
        grep -Eq 'Architecture: (amd64|arm64)' "$TMP/deb-info"
        grep -q 'Maintainer: xsprof maintainers <maintainers@xsprof.dev>' "$TMP/deb-info"
        dpkg-deb --contents "$DEB" > "$TMP/deb-contents"
        reject_web_assets "deb" "$TMP/deb-contents"
        for path in ./usr/bin/xsprof ./usr/share/xsprof/fixtures/healthy.ndjson ./usr/lib/systemd/system/xsprof-recorder.service ./usr/lib/sysusers.d/xsprof.conf ./usr/share/applications/xsprof.desktop ./usr/share/bash-completion/completions/xsprof; do
            grep -q " $path\$" "$TMP/deb-contents" || {
                echo "package_layout: deb missing $path" >&2
                exit 1
            }
        done
        mkdir -p "$TMP/deb-root"
        dpkg-deb -x "$DEB" "$TMP/deb-root"
        [ -x "$TMP/deb-root/usr/bin/xsprof" ] || {
            echo "package_layout: deb usr/bin/xsprof is not executable" >&2
            exit 1
        }
        check_cpu_portability "deb usr/bin/xsprof" "$TMP/deb-root/usr/bin/xsprof"
        echo "package_layout: PASS deb layout"
    fi
fi

echo "package_layout: PASS"
