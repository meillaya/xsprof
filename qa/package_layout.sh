#!/bin/sh
# Assert the release tarball and Debian layouts. Linux-only for the deb check;
# the tarball check runs anywhere tar is available.
# Usage: sh qa/package_layout.sh --tarball FILE [--deb FILE]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARBALL=
DEB=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tarball) TARBALL=${2:-}; shift 2 ;;
        --deb) DEB=${2:-}; shift 2 ;;
        --help|-h) echo "usage: sh qa/package_layout.sh --tarball FILE [--deb FILE]" >&2; exit 2 ;;
        *) echo "package_layout: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$TARBALL" ] || { echo "package_layout: --tarball is required" >&2; exit 2; }
[ -f "$TARBALL" ] || { echo "package_layout: missing tarball $TARBALL" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
if [ -f "$TARBALL.sha256" ]; then
    expected=$(cut -d' ' -f1 < "$TARBALL.sha256")
    actual=$(sha256sum "$TARBALL" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$TARBALL" | cut -d' ' -f1)
    [ "$expected" = "$actual" ] || { echo "package_layout: tarball sha256 mismatch" >&2; exit 1; }
    echo "package_layout: PASS tarball sha256"
fi
root=$(tar -tzf "$TARBALL" | head -1 | cut -d/ -f1)
[ -n "$root" ] || { echo "package_layout: empty tarball" >&2; exit 1; }
listing="$TMP/listing"
tar -tzf "$TARBALL" > "$listing"
required="bin/xsprof
share/xsprof/web/index.html
share/xsprof/web/assets/xsprof-web.wasm
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
[ -s "$TMP/$root/share/xsprof/web/assets/xsprof-web.wasm" ] || {
    echo "package_layout: wasm asset is empty" >&2
    exit 1
}
echo "package_layout: PASS tarball layout"

if [ -z "$DEB" ]; then
    echo "package_layout: SKIP deb layout (no --deb)"
    exit 0
fi
[ -f "$DEB" ] || { echo "package_layout: missing deb $DEB" >&2; exit 2; }
if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "package_layout: SKIP deb layout (dpkg-deb unavailable)"
    exit 0
fi
if [ -f "$DEB.sha256" ]; then
    expected=$(cut -d' ' -f1 < "$DEB.sha256")
    actual=$(sha256sum "$DEB" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$DEB" | cut -d' ' -f1)
    [ "$expected" = "$actual" ] || { echo "package_layout: deb sha256 mismatch" >&2; exit 1; }
fi
dpkg-deb --info "$DEB" > "$TMP/deb-info"
grep -q 'Package: xsprof' "$TMP/deb-info"
grep -Eq 'Version: [0-9]+\.[0-9]+\.[0-9]+-[0-9]+' "$TMP/deb-info"
grep -Eq 'Architecture: (amd64|arm64)' "$TMP/deb-info"
grep -q 'Maintainer: xsprof maintainers <maintainers@xsprof.dev>' "$TMP/deb-info"
dpkg-deb --contents "$DEB" > "$TMP/deb-contents"
for path in ./usr/bin/xsprof ./usr/share/xsprof/web/index.html ./usr/share/xsprof/fixtures/healthy.ndjson ./usr/lib/systemd/system/xsprof-recorder.service ./usr/lib/sysusers.d/xsprof.conf ./usr/share/applications/xsprof.desktop ./usr/share/bash-completion/completions/xsprof; do
    grep -q " $path\$" "$TMP/deb-contents" || {
        echo "package_layout: deb missing $path" >&2
        exit 1
    }
done
echo "package_layout: PASS deb layout"
