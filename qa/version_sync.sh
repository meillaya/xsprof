#!/bin/sh
# Keep the package manifest, runtime version, changelog, and README in lockstep.
#
# One version bump must update all four sources of truth:
#   build.zig.zon        .version = "x.y.z"              package/dependency manifest
#   src/core/version.zig pub const version = "x.y.z"     `xsprof version` runtime
#   CHANGELOG.md         first "## <version>" heading    release notes
#   README.md            mentions the current version    version badge/downloads
#
# The release workflow preflight additionally requires the pushed `vX.Y.Z` tag
# to equal this version. A version that reaches a release while README or the
# changelog still name an older one is a published inconsistency, so this gate
# is fail-closed. If README is ever rewritten to stop naming a version, this
# gate must be changed in the same commit (do not silently drop the check).
#
# Usage: sh qa/version_sync.sh
# Exit:  0 all four agree, 1 any mismatch or missing value.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
    echo "version_sync: FAIL ($*)" >&2
    exit 1
}

[ -f "$ROOT/build.zig.zon" ] || fail "build.zig.zon missing"
[ -f "$ROOT/src/core/version.zig" ] || fail "src/core/version.zig missing"
[ -f "$ROOT/CHANGELOG.md" ] || fail "CHANGELOG.md missing"
[ -f "$ROOT/README.md" ] || fail "README.md missing"

zon=$(sed -n 's/.*\.version = "\(.*\)".*/\1/p' "$ROOT/build.zig.zon" | head -1)
src=$(sed -n 's/.*pub const version = "\(.*\)".*/\1/p' "$ROOT/src/core/version.zig" | head -1)
changelog=$(awk '
    /^##[[:space:]]+/ {
        heading = $0
        sub(/^##[[:space:]]+/, "", heading)
        split(heading, parts, /[[:space:]]+/)
        version = parts[1]
        gsub(/^\[/, "", version)
        gsub(/\]$/, "", version)
        print version
        exit
    }' "$ROOT/CHANGELOG.md")
readme_hits=$(grep -c -F -- "$zon" "$ROOT/README.md" 2>/dev/null || true)

[ -n "$zon" ] || fail "build.zig.zon has no .version"
[ -n "$src" ] || fail "src/core/version.zig has no pub const version"

status=0
if [ "$zon" != "$src" ]; then
    echo "version_sync: build.zig.zon=$zon version.zig=$src" >&2
    status=1
fi
if [ -z "$changelog" ]; then
    echo "version_sync: CHANGELOG.md has no '## <version>' heading" >&2
    status=1
elif [ "$changelog" != "$zon" ]; then
    echo "version_sync: CHANGELOG top heading=$changelog build.zig.zon=$zon" >&2
    status=1
fi
if [ -z "$readme_hits" ] || [ "$readme_hits" -eq 0 ]; then
    echo "version_sync: README.md does not mention $zon (update the version badge/download names)" >&2
    status=1
fi
if [ "$status" -ne 0 ]; then
    fail "version sources disagree"
fi
echo "version_sync: PASS ($zon; zon=runtime=changelog=README)"
