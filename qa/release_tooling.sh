#!/bin/sh
# Offline release-tooling gate: verifies the attestation gate, the Homebrew tap
# renderer, and the release scripts without Apple credentials, network, or a
# macOS host. Run from the repo checkout; every artifact stays under mktemp.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
command -v python3 >/dev/null 2>&1 || {
    echo "release_tooling: python3 is required for the attestation gate" >&2
    exit 1
}

echo "release_tooling: checking shell syntax"
for script in tools/zig tools/*.sh qa/release_tooling.sh qa/homebrew_dry_run.sh qa/package_layout.sh qa/appimage_smoke.sh; do
    sh -n "$script"
done
python3 -c 'import ast; ast.parse(open("tools/verify_macos_attestation.py", encoding="utf-8").read())'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
printf 'xsprof-test-artifact' > "$TMP/artifact"
SHA=$(sha256sum "$TMP/artifact" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$TMP/artifact" | cut -d' ' -f1)
SIZE=$(wc -c < "$TMP/artifact" | tr -d ' ')

expect_exit() { # expected-code label command...
    expected=$1
    label=$2
    shift 2
    set +e
    "$@" >"$TMP/last.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne "$expected" ]; then
        cat "$TMP/last.log" >&2
        echo "release_tooling: $label expected exit $expected, got $rc" >&2
        exit 1
    fi
    echo "release_tooling: PASS $label (exit $rc)"
}

verify() { # name...
    python3 tools/verify_macos_attestation.py --version 0.0.0-test \
        --artifact-sha256 "$SHA" --artifact-size "$SIZE" "$@"
}
NOTARIZED_NAME="Xsprof-0.0.0-test-macos.zip"
UNSIGNED_NAME="Xsprof-0.0.0-test-macos-unsigned.zip"

expect_exit 0 "valid notarized attestation" verify \
    --attestation packaging/testdata/macos-attestation-valid.json --artifact-name "$NOTARIZED_NAME"
expect_exit 10 "tampered attestation rejected" verify \
    --attestation packaging/testdata/macos-attestation-tampered.json --artifact-name "$NOTARIZED_NAME"
expect_exit 11 "sha mismatch rejected" verify \
    --attestation packaging/testdata/macos-attestation-wrong-sha.json --artifact-name "$NOTARIZED_NAME"
expect_exit 11 "version mismatch rejected" verify \
    --attestation packaging/testdata/macos-attestation-valid.json --artifact-name "$NOTARIZED_NAME" \
    --version 9.9.9
expect_exit 12 "unsigned attestation rejected for publication" verify \
    --attestation packaging/testdata/macos-attestation-unsigned.json --artifact-name "$UNSIGNED_NAME"
expect_exit 0 "unsigned attestation accepted with --allow-unnotarized" verify \
    --attestation packaging/testdata/macos-attestation-unsigned.json --artifact-name "$UNSIGNED_NAME" \
    --allow-unnotarized

echo "release_tooling: checking native-only packaging (no web assets)"
for file in tools/package.sh tools/package_deb.sh tools/package_macos_app.sh nix/package.nix packaging/homebrew/xsprof.rb docs/guides/install.md; do
    if grep -nE 'XSPROF_WEB_DIR|xsprof-web\.wasm' "$file" >/dev/null 2>&1; then
        echo "release_tooling: $file still references packaged web assets" >&2
        exit 1
    fi
done
for file in tools/package.sh tools/package_deb.sh tools/package_macos_app.sh nix/package.nix; do
    if grep -nE 'cp (-R|-[a-z]*R[a-z]*) .*/web|install .*/web' "$file" >/dev/null 2>&1; then
        echo "release_tooling: $file still copies web assets into packages" >&2
        exit 1
    fi
done

echo "release_tooling: checking tap renderer and local tap publication"
sh qa/homebrew_dry_run.sh

echo "release_tooling: PASS"
