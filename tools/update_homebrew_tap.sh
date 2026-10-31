#!/bin/sh
# Write the published Homebrew formula and cask into a tap checkout.
# SHA-256 values are computed from the release artifacts by the caller.
# Use --dry-run to render into the checkout without committing or pushing.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TAP_DIR=
VERSION=
SHA_ARM=
SHA_X86=
SHA_MAC=
DRY_RUN=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tap-dir) TAP_DIR=${2:-}; shift 2 ;;
        --version) VERSION=${2:-}; shift 2 ;;
        --linux-arm64) SHA_ARM=${2:-}; shift 2 ;;
        --linux-x86_64) SHA_X86=${2:-}; shift 2 ;;
        --macos) SHA_MAC=${2:-}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "update_homebrew_tap: unknown argument $1" >&2; exit 2 ;;
    esac
done

[ -n "$TAP_DIR" ] && [ -d "$TAP_DIR/.git" ] || {
    echo "update_homebrew_tap: --tap-dir must be a git checkout" >&2
    exit 2
}
[ -n "$VERSION" ] || { echo "update_homebrew_tap: --version is required" >&2; exit 2; }
for value in "$SHA_ARM" "$SHA_X86" "$SHA_MAC"; do
    printf '%s' "$value" | grep -Eq '^[0-9a-f]{64}$' || {
        echo "update_homebrew_tap: every sha256 must be 64 lowercase hex characters" >&2
        exit 2
    }
done

mkdir -p "$TAP_DIR/Formula" "$TAP_DIR/Casks"
FORMULA="$TAP_DIR/Formula/xsprof.rb"
CASK="$TAP_DIR/Casks/xsprof-app.rb"
sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@SHA256_ARM64@/$SHA_ARM/g" \
    -e "s/@SHA256_X86_64@/$SHA_X86/g" \
    "$ROOT/packaging/homebrew/xsprof.rb" >"$FORMULA"
sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@SHA256@/$SHA_MAC/g" \
    "$ROOT/packaging/homebrew/xsprof-app.rb" >"$CASK"

if [ "$DRY_RUN" = 1 ]; then
    echo "update_homebrew_tap: rendered $FORMULA and $CASK (dry run)"
    exit 0
fi
git -C "$TAP_DIR" add Formula/xsprof.rb Casks/xsprof-app.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
    echo "update_homebrew_tap: tap already current"
    exit 0
fi
git -C "$TAP_DIR" -c user.name="xsprof release" \
    -c user.email="release@xsprof.dev" \
    commit -m "xsprof $VERSION"
git -C "$TAP_DIR" push
echo "update_homebrew_tap: pushed $VERSION"
