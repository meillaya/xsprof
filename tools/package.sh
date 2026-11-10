#!/bin/sh
# Build a release binary and a self-contained tarball. Does not publish.
# Cross packaging: XSPROF_TARGET=aarch64-linux-gnu XSPROF_OS=linux
# XSPROF_ARCH=aarch64.
#
# Layout (also asserted by qa/package_layout.sh):
#   bin/xsprof
#   share/xsprof/fixtures/healthy.ndjson
#   share/applications/xsprof.desktop
#   share/icons/hicolor/scalable/apps/xsprof.svg
#   share/bash-completion/completions/xsprof, zsh, fish
#   lib/systemd/system/xsprof-recorder.service
#   lib/sysusers.d/xsprof.conf
#   share/doc/xsprof/
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' build.zig.zon | head -1)
OS=${XSPROF_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}
ARCH=${XSPROF_ARCH:-$(uname -m)}
TARGET=${XSPROF_TARGET:-}
NAME="xsprof-$VERSION-$OS-$ARCH"
DIST="$ROOT/dist/$NAME"
case "$VERSION$OS$ARCH" in
    *[!A-Za-z0-9._-]*) echo "package: invalid version/os/arch" >&2; exit 1 ;;
esac
case "$DIST" in
    "$ROOT"/dist/xsprof-*) ;;
    *) echo "package: refusing unexpected dist path $DIST" >&2; exit 1 ;;
esac

PREFIX="$ROOT/zig-out/package"
HOST_PREFIX="$ROOT/zig-out/package-host"
rm -rf "$PREFIX" "$HOST_PREFIX"
# One build installs the binary. For cross packaging, completions are
# arch-independent and are generated from a host-native build of the same
# revision. A target equal to the host target is treated as native so CI does
# not compile twice.
NATIVE=0
if [ -z "$TARGET" ]; then
    NATIVE=1
else
    case "$(uname -s)/$(uname -m)/$TARGET" in
        Linux/x86_64/x86_64-linux-gnu|Linux/aarch64/aarch64-linux-gnu) NATIVE=1 ;;
    esac
fi
if [ "$NATIVE" = 1 ]; then
    ./tools/zig build -Doptimize=ReleaseSafe --prefix "$PREFIX"
    COMPLETIONS_BIN="$PREFIX/bin/xsprof"
else
    ./tools/zig build -Doptimize=ReleaseSafe --prefix "$HOST_PREFIX"
    ./tools/zig build -Doptimize=ReleaseSafe -Dtarget="$TARGET" --prefix "$PREFIX"
    COMPLETIONS_BIN="$HOST_PREFIX/bin/xsprof"
fi
[ -x "$PREFIX/bin/xsprof" ] || {
    echo "package: binary missing after build" >&2
    exit 1
}
# v0.5 ships the native console only; browser/WASM assets are not packaged.
if [ -d "$PREFIX/web" ]; then
    echo "package: ignoring legacy web assets in $PREFIX/web (not packaged)" >&2
fi

rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/share/xsprof/fixtures"
mkdir -p "$DIST/share/doc/xsprof" "$DIST/share/applications"
mkdir -p "$DIST/share/icons/hicolor/scalable/apps" "$DIST/lib/sysusers.d"
cp "$PREFIX/bin/xsprof" "$DIST/bin/xsprof"
cp fixtures/ui/healthy.ndjson "$DIST/share/xsprof/fixtures/healthy.ndjson"
cp packaging/linux/xsprof.desktop "$DIST/share/applications/xsprof.desktop"
cp packaging/linux/xsprof.svg "$DIST/share/icons/hicolor/scalable/apps/xsprof.svg"
cp packaging/sysusers/xsprof.conf "$DIST/lib/sysusers.d/xsprof.conf"
sh tools/gen_completions.sh "$COMPLETIONS_BIN" "$DIST/share"
cp README.md THIRD_PARTY_NOTICES.md LICENSE CHANGELOG.md "$DIST/share/doc/xsprof/"
for guide in flight-recorder compare-ci quickstart top-why install; do
    cp "docs/guides/$guide.md" "$DIST/share/doc/xsprof/"
done
if [ "$OS" = linux ]; then
    mkdir -p "$DIST/lib/systemd/system"
    cp packaging/systemd/xsprof-recorder.service "$DIST/lib/systemd/system/"
fi
chmod 755 "$DIST/bin/xsprof"
if [ -e "$DIST/share/xsprof/web" ] || find "$DIST" -name '*.wasm' | grep -q .; then
    echo "package: refusing to package web assets" >&2
    exit 1
fi

mkdir -p "$ROOT/dist"
: "${SOURCE_DATE_EPOCH:=$(git log -1 --format=%ct 2>/dev/null || date +%s)}"
export SOURCE_DATE_EPOCH
TARBALL="$ROOT/dist/$NAME.tar.gz"
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar -C "$ROOT/dist" --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner -czf "$TARBALL" "$NAME"
else
    # bsdtar on macOS: keep the fallback simple; release tarballs are built on Linux.
    tar -C "$ROOT/dist" -czf "$TARBALL" "$NAME"
fi
if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$ROOT/dist" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
else
    ( cd "$ROOT/dist" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
fi
echo "$TARBALL"
