#!/bin/sh
# Enforce the 1000-line responsibility limit for hand-written source files.
#
# One hand-written file should hold one responsibility. The ceiling is 1000
# lines: the previous 600-line cap forced mechanical splitting long before a
# file became hard to review, so the rule now targets genuinely oversized
# modules. A file over this limit is holding several concerns and should be
# split by responsibility rather than grown.
#
# Exemptions (they are not one hand-written concern):
#   * tests/**       test shards grow with cases and fixtures
#   * *_test.zig     inline/companion test files
#   * generated files  the first line contains GENERATED, e.g.
#     src/app/design/ui_spec.zig; regenerate the source of truth instead
#
# Scanned trees: src, lib, tests, tools. Generated assets, vendored corpora,
# and build output (`zig-out/`, `.zig-cache/`) are not source and are skipped.
#
# Usage: sh qa/lines.sh
# Exit:  0 within the limit, 1 any oversized hand-written file.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MAX_LINES=1000
status=0
checked=0
exempt=0
list=$(mktemp)
trap 'rm -f "$list"' EXIT HUP INT TERM
find "$ROOT/src" "$ROOT/lib" "$ROOT/tests" "$ROOT/tools" \
    -type f \( -name '*.zig' -o -name '*.js' -o -name '*.css' -o -name '*.html' \
               -o -name '*.glsl' -o -name '*.metal' \) \
    -not -path '*/zig-out/*' -not -path '*/.zig-cache/*' | LC_ALL=C sort > "$list"
while IFS= read -r f; do
    rel=${f#"$ROOT"/}
    case "$rel" in
        tests/* | */tests/* | *_test.zig)
            exempt=$((exempt + 1))
            continue
            ;;
    esac
    first=$(head -n 1 "$f")
    case "$first" in
        *GENERATED*)
            exempt=$((exempt + 1))
            continue
            ;;
    esac
    checked=$((checked + 1))
    n=$(wc -l < "$f" | tr -d ' ')
    if [ "$n" -gt "$MAX_LINES" ]; then
        printf 'line limit: %s has %s lines (max %s)\n' \
            "$rel" "$n" "$MAX_LINES" >&2
        status=1
    fi
done <"$list"
if [ "$status" -ne 0 ]; then
    echo "lines: FAIL (hand-written source over $MAX_LINES lines)" >&2
    exit 1
fi
printf 'lines: PASS (%s hand-written files <= %s lines; %s exempt)\n' \
    "$checked" "$MAX_LINES" "$exempt"
