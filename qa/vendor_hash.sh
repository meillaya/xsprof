#!/bin/sh
# Verify the vendored Zig 0.17 reference corpus without network access.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/../docs/vendor/zig-0.17.0" && pwd)"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS
else
    shasum -a 256 -c SHA256SUMS
fi
