#!/bin/sh
# Enforce the 600-line limit for hand-written source files.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
status=0
list=$(mktemp)
trap 'rm -f "$list"' EXIT HUP INT TERM
find "$ROOT/src" "$ROOT/lib" "$ROOT/tests" "$ROOT/tools" "$ROOT/web" \
    -type f \( -name '*.zig' -o -name '*.js' -o -name '*.css' -o -name '*.html' \
               -o -name '*.glsl' -o -name '*.metal' \) \
    -not -path '*/zig-out/*' -not -path '*/.zig-cache/*' | LC_ALL=C sort > "$list"
while IFS= read -r f; do
    n=$(wc -l < "$f" | tr -d ' ')
    if [ "$n" -gt 600 ]; then
        printf 'line limit: %s has %s lines (max 600)\n' "${f#"$ROOT"/}" "$n" >&2
        status=1
    fi
done < "$list"
exit "$status"
