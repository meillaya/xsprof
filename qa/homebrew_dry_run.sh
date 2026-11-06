#!/bin/sh
# Local Homebrew tap tests with no network, no brew, and no credentials.
# - renders the formula/cask templates with fixture SHAs and a fixture attestation
# - checks that a non-notarized artifact can never render the cask
# - exercises the real commit+push path against a local bare git repository
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
command -v git >/dev/null 2>&1 || { echo "homebrew_dry_run: git is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "homebrew_dry_run: python3 is required" >&2; exit 1; }

SHA_ARM=$(printf 'a%63s' '' | tr ' ' 'a')
SHA_ARM2=$(printf 'c%63s' '' | tr ' ' 'c')
SHA_X86=$(printf 'b%63s' '' | tr ' ' 'b')
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
printf 'xsprof-test-artifact' > "$TMP/artifact"
SHA_MAC=$(sha256sum "$TMP/artifact" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$TMP/artifact" | cut -d' ' -f1)
SIZE=$(wc -c < "$TMP/artifact" | tr -d ' ')
VALID="packaging/testdata/macos-attestation-valid.json"
UNSIGNED="packaging/testdata/macos-attestation-unsigned.json"
VERSION="0.0.0-test"

expect_fail() { # label command...
    label=$1
    shift
    set +e
    "$@" >"$TMP/last.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        cat "$TMP/last.log" >&2
        echo "homebrew_dry_run: $label should have failed" >&2
        exit 1
    fi
    echo "homebrew_dry_run: PASS $label rejected (exit $rc)"
}

render() { # dest [extra...]
    dest=$1
    shift
    sh tools/update_homebrew_tap.sh --render-dir "$dest" --version "$VERSION" \
        --linux-arm64 "$SHA_ARM" --linux-x86_64 "$SHA_X86" --macos "$SHA_MAC" "$@"
}

echo "homebrew_dry_run: notarized render"
render "$TMP/render-ok" --macos-size "$SIZE" --attestation "$VALID"
grep -q 'class Xsprof < Formula' "$TMP/render-ok/Formula/xsprof.rb"
grep -q 'license "MIT"' "$TMP/render-ok/Formula/xsprof.rb"
grep -q "version \"$VERSION\"" "$TMP/render-ok/Casks/xsprof-app.rb"
grep -q "$SHA_MAC" "$TMP/render-ok/Casks/xsprof-app.rb"
grep -q "Xsprof-#{version}-macos.zip" "$TMP/render-ok/Casks/xsprof-app.rb"
if grep -R -q '@VERSION@\|@SHA256' "$TMP/render-ok"; then
    echo "homebrew_dry_run: placeholders were not substituted" >&2
    exit 1
fi
echo "homebrew_dry_run: PASS notarized formula+cask rendered"

echo "homebrew_dry_run: formula-only render (no attestation)"
render "$TMP/render-formula"
[ -f "$TMP/render-formula/Formula/xsprof.rb" ] || { echo "homebrew_dry_run: formula missing" >&2; exit 1; }
[ ! -e "$TMP/render-formula/Casks/xsprof-app.rb" ] || { echo "homebrew_dry_run: cask must not render without attestation" >&2; exit 1; }
echo "homebrew_dry_run: PASS formula-only render has no cask"

expect_fail "unsigned with --require-notarized" sh tools/update_homebrew_tap.sh \
    --render-dir "$TMP/render-require" --version "$VERSION" \
    --linux-arm64 "$SHA_ARM" --linux-x86_64 "$SHA_X86" --macos "$SHA_MAC" \
    --macos-size "$SIZE" --attestation "$UNSIGNED" --require-notarized
[ ! -e "$TMP/render-require/Casks/xsprof-app.rb" ] || { echo "homebrew_dry_run: rejected render wrote a cask" >&2; exit 1; }

expect_fail "63-character sha" sh tools/update_homebrew_tap.sh \
    --render-dir "$TMP/render-bad" --version "$VERSION" \
    --linux-arm64 "abc" --linux-x86_64 "$SHA_X86" --macos "$SHA_MAC"

echo "homebrew_dry_run: local bare-repository publication"
git init -q -b main "$TMP/tap"
git -C "$TMP/tap" config user.name "xsprof test"
git -C "$TMP/tap" config user.email "test@example.invalid"
printf '# xsprof tap test\n' > "$TMP/tap/README.md"
git -C "$TMP/tap" add README.md
git -C "$TMP/tap" commit -qm "init"
git init -q --bare "$TMP/tap.git"
git -C "$TMP/tap" remote add origin "$TMP/tap.git"
git -C "$TMP/tap" push -q -u origin main
sh tools/update_homebrew_tap.sh --tap-dir "$TMP/tap" --version "$VERSION" \
    --linux-arm64 "$SHA_ARM" --linux-x86_64 "$SHA_X86" --macos "$SHA_MAC" \
    --macos-size "$SIZE" --attestation "$VALID"
git -C "$TMP/tap.git" cat-file -e main:Formula/xsprof.rb
git -C "$TMP/tap.git" cat-file -e main:Casks/xsprof-app.rb
git -C "$TMP/tap.git" log -1 --format=%s main | grep -q "xsprof $VERSION"
echo "homebrew_dry_run: PASS commit+push to local bare origin"

echo "homebrew_dry_run: --no-push keeps the remote unchanged"
before=$(git -C "$TMP/tap.git" rev-parse main)
sh tools/update_homebrew_tap.sh --tap-dir "$TMP/tap" --version "$VERSION" \
    --linux-arm64 "$SHA_ARM2" --linux-x86_64 "$SHA_X86" --macos "$SHA_MAC" \
    --macos-size "$SIZE" --attestation "$VALID" --no-push
after=$(git -C "$TMP/tap.git" rev-parse main)
[ "$before" = "$after" ] || { echo "homebrew_dry_run: --no-push updated the remote" >&2; exit 1; }
grep -q "$SHA_ARM2" "$TMP/tap/Formula/xsprof.rb" || { echo "homebrew_dry_run: local formula not updated" >&2; exit 1; }
echo "homebrew_dry_run: PASS --no-push commits locally only"

echo "homebrew_dry_run: PASS"
