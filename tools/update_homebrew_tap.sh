#!/bin/sh
# Render the published Homebrew formula and cask into a tap checkout, or into
# a render directory for review. Formula publication never depends on Apple
# credentials; cask publication is gated on a valid
# xsprof/macos-notarization/v1 attestation.
#
# SHA-256 values are computed from the release artifacts by the caller.
#
# Usage:
#   sh tools/update_homebrew_tap.sh --tap-dir DIR --version V \
#       --linux-arm64 SHA --linux-x86_64 SHA --macos SHA \
#       [--macos-size BYTES] [--attestation FILE] [--require-notarized] \
#       [--dry-run] [--no-push]
#   sh tools/update_homebrew_tap.sh --render-dir DIR --version V ... (render only)
#
# --require-notarized: fail before any write/commit/push unless the attestation
#   verifies as notarized (used by strict tag releases).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TAP_DIR=
RENDER_DIR=
VERSION=
SHA_ARM=
SHA_X86=
SHA_MAC=
MAC_SIZE=
ATTESTATION=
REQUIRE_NOTARIZED=0
DRY_RUN=0
NO_PUSH=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tap-dir) TAP_DIR=${2:-}; shift 2 ;;
        --render-dir) RENDER_DIR=${2:-}; shift 2 ;;
        --version) VERSION=${2:-}; shift 2 ;;
        --linux-arm64) SHA_ARM=${2:-}; shift 2 ;;
        --linux-x86_64) SHA_X86=${2:-}; shift 2 ;;
        --macos) SHA_MAC=${2:-}; shift 2 ;;
        --macos-size) MAC_SIZE=${2:-}; shift 2 ;;
        --attestation) ATTESTATION=${2:-}; shift 2 ;;
        --require-notarized) REQUIRE_NOTARIZED=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-push) NO_PUSH=1; shift ;;
        --help|-h) sed -n '2,20p' "$0" >&2; exit 2 ;;
        *) echo "update_homebrew_tap: unknown argument $1" >&2; exit 2 ;;
    esac
done

[ -n "$RENDER_DIR" ] || [ -n "$TAP_DIR" ] || {
    echo "update_homebrew_tap: pass --tap-dir DIR or --render-dir DIR" >&2
    exit 2
}
[ -z "$RENDER_DIR" ] || [ -z "$TAP_DIR" ] || {
    echo "update_homebrew_tap: --tap-dir and --render-dir are mutually exclusive" >&2
    exit 2
}
if [ -z "$RENDER_DIR" ]; then
    [ -e "$TAP_DIR/.git" ] || {
        echo "update_homebrew_tap: --tap-dir must be a git checkout" >&2
        exit 2
    }
elif [ "$DRY_RUN" = 0 ] && [ "$NO_PUSH" = 0 ]; then
    # A render directory is always offline; pushing is impossible by design.
    NO_PUSH=1
fi
[ -n "$VERSION" ] || { echo "update_homebrew_tap: --version is required" >&2; exit 2; }
printf '%s' "$VERSION" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]*$' || {
    echo "update_homebrew_tap: invalid --version '$VERSION'" >&2
    exit 2
}
for value in "$SHA_ARM" "$SHA_X86" "$SHA_MAC"; do
    printf '%s' "$value" | grep -Eq '^[0-9a-f]{64}$' || {
        echo "update_homebrew_tap: every sha256 must be 64 lowercase hex characters" >&2
        exit 2
    }
done

# ---------------------------------------------------------------------------
# Cask gate. The cask is only rendered for a verified notarized artifact.
# ---------------------------------------------------------------------------
CASK_OK=0
if [ -n "$ATTESTATION" ]; then
    [ -f "$ATTESTATION" ] || { echo "update_homebrew_tap: attestation not found: $ATTESTATION" >&2; exit 2; }
    [ -n "$MAC_SIZE" ] || { echo "update_homebrew_tap: --macos-size is required with --attestation" >&2; exit 2; }
    printf '%s' "$MAC_SIZE" | grep -Eq '^[0-9]+$' || { echo "update_homebrew_tap: invalid --macos-size" >&2; exit 2; }
    set +e
    python3 "$ROOT/tools/verify_macos_attestation.py" \
        --attestation "$ATTESTATION" \
        --version "$VERSION" \
        --artifact-name "Xsprof-$VERSION-macos.zip" \
        --artifact-sha256 "$SHA_MAC" \
        --artifact-size "$MAC_SIZE"
    verify_rc=$?
    set -e
    case "$verify_rc" in
        0) CASK_OK=1 ;;
        12)
            if [ "$REQUIRE_NOTARIZED" = 1 ]; then
                echo "update_homebrew_tap: cask publication required but the artifact is not notarized" >&2
                exit 1
            fi
            echo "update_homebrew_tap: warning: artifact is not notarized; rendering formula only (no cask)" >&2 ;;
        *)
            echo "update_homebrew_tap: attestation verification failed (exit $verify_rc); refusing to update the tap" >&2
            exit 1 ;;
    esac
elif [ "$REQUIRE_NOTARIZED" = 1 ]; then
    echo "update_homebrew_tap: --require-notarized needs --attestation" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Render. Validate placeholders after substitution so a missing value fails.
# ---------------------------------------------------------------------------
TEMPLATE_FORMULA="$ROOT/packaging/homebrew/xsprof.rb"
TEMPLATE_CASK="$ROOT/packaging/homebrew/xsprof-app.rb"
[ -f "$TEMPLATE_FORMULA" ] || { echo "update_homebrew_tap: missing $TEMPLATE_FORMULA" >&2; exit 2; }
[ -f "$TEMPLATE_CASK" ] || { echo "update_homebrew_tap: missing $TEMPLATE_CASK" >&2; exit 2; }

render_into() { # dest-dir
    dest=$1
    mkdir -p "$dest/Formula" "$dest/Casks"
    sed -e "s/@VERSION@/$VERSION/g" \
        -e "s/@SHA256_ARM64@/$SHA_ARM/g" \
        -e "s/@SHA256_X86_64@/$SHA_X86/g" \
        "$TEMPLATE_FORMULA" > "$dest/Formula/xsprof.rb"
    if [ "$CASK_OK" = 1 ]; then
        sed -e "s/@VERSION@/$VERSION/g" \
            -e "s/@SHA256@/$SHA_MAC/g" \
            "$TEMPLATE_CASK" > "$dest/Casks/xsprof-app.rb"
    fi
    for rendered in "$dest/Formula/xsprof.rb" "$dest/Casks/xsprof-app.rb"; do
        [ -f "$rendered" ] || continue
        if grep -q '@VERSION@\|@SHA256' "$rendered"; then
            echo "update_homebrew_tap: unsubstituted placeholder in $rendered" >&2
            exit 1
        fi
    done
}

if [ -n "$RENDER_DIR" ]; then
    render_into "$RENDER_DIR"
    echo "update_homebrew_tap: rendered $RENDER_DIR/Formula/xsprof.rb"
    if [ "$CASK_OK" = 1 ]; then
        echo "update_homebrew_tap: rendered $RENDER_DIR/Casks/xsprof-app.rb (notarized)"
    else
        echo "update_homebrew_tap: cask not rendered (notarization attestation required)"
    fi
    exit 0
fi

render_into "$TAP_DIR"
FORMULA_REL="Formula/xsprof.rb"
CASK_REL="Casks/xsprof-app.rb"
if [ "$DRY_RUN" = 1 ]; then
    echo "update_homebrew_tap: rendered $TAP_DIR/$FORMULA_REL (dry run, no commit/push)"
    [ "$CASK_OK" = 1 ] && echo "update_homebrew_tap: rendered $TAP_DIR/$CASK_REL (dry run, notarized)" || true
    exit 0
fi

git -C "$TAP_DIR" add "$FORMULA_REL"
if [ "$CASK_OK" = 1 ]; then
    git -C "$TAP_DIR" add "$CASK_REL"
fi
if git -C "$TAP_DIR" diff --cached --quiet; then
    echo "update_homebrew_tap: tap already current"
    exit 0
fi
git -C "$TAP_DIR" -c user.name="xsprof release" \
    -c user.email="release@xsprof.dev" commit -m "xsprof $VERSION"
if [ "$NO_PUSH" = 1 ]; then
    echo "update_homebrew_tap: committed $VERSION locally (--no-push)"
    exit 0
fi
git -C "$TAP_DIR" push
echo "update_homebrew_tap: pushed $VERSION"
