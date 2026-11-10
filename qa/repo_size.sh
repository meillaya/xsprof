#!/bin/sh
# Enforce the published-tree size budgets at HEAD.
#
# A trust-first repository must stay cheap to clone, mirror, and review. The
# budgets are measured on the tracked tree (`git ls-tree -r -l HEAD`), never on
# the developer worktree, so ignored build output, caches, and a dirty checkout
# cannot change the result:
#
#   * total tracked bytes <= 12 MiB (the post-diet target: evidence corpora and
#     vendored reference text must not live in git)
#   * no tracked file > 2 MiB, except an explicit allowlist for the GPU glyph
#     atlas: it is a product asset generated once from the bundled fonts, so it
#     cannot be regenerated cheaply at build time and is allowed up to 5 MiB.
#   * no `.zig-cache/` path may be tracked (build caches are machine-local and
#     would silently balloon the clone)
#
# The allowlist is deliberately exact: renaming or adding a large asset should
# force a conscious edit here plus a size rationale in the commit message.
# This gate intentionally fails on the pre-diet tree while the vendor/evidence
# corpus is being retired.
#
# Usage: sh qa/repo_size.sh
# Exit:  0 within budget, 1 over budget / unmeasurable / tracked build cache.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOTAL_BUDGET_BYTES=$((12 * 1024 * 1024))
FILE_BUDGET_BYTES=$((2 * 1024 * 1024))
ATLAS_MAX_BYTES=$((5 * 1024 * 1024))
ATLAS_ALLOWLIST='lib/xsui/assets/fonts/chromium_text_atlas.bin'
TAB=$(printf '\t')

fail() {
    echo "repo_size: FAIL ($*)" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || fail "git unavailable; cannot measure HEAD"
git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1 || fail "no HEAD commit to measure"

list=$(mktemp)
trap 'rm -f "$list"' EXIT HUP INT TERM
# Normalise to "<size TAB path>" so the loop below keeps the main shell (a pipe
# would run it in a subshell and lose the totals).
if ! git -C "$ROOT" ls-tree -r -l HEAD | awk -F'\t' '{ split($1, meta, " "); print meta[4] "\t" $2 }' >"$list"; then
    fail "git ls-tree failed"
fi

status=0
total=0
files=0
oversize=0
cached=0
while IFS="$TAB" read -r size path; do
    case "$size" in
        '' | -) continue ;; # gitlink (no blob) or unreadable entry
        *[!0-9]*) fail "unexpected entry size '$size' for $path" ;;
    esac
    files=$((files + 1))
    total=$((total + size))

    case "$path" in
        .zig-cache | .zig-cache/* | */.zig-cache | */.zig-cache/*)
            echo "repo_size: tracked build cache: $path" >&2
            cached=$((cached + 1))
            status=1
            ;;
    esac

    if [ "$size" -gt "$FILE_BUDGET_BYTES" ]; then
        if [ "$path" = "$ATLAS_ALLOWLIST" ] && [ "$size" -le "$ATLAS_MAX_BYTES" ]; then
            printf 'repo_size: allowed asset: %s (%s bytes, atlas allowlist)\n' \
                "$path" "$size"
        else
            printf 'repo_size: file over budget: %s (%s bytes > %s bytes)\n' \
                "$path" "$size" "$FILE_BUDGET_BYTES" >&2
            oversize=$((oversize + 1))
            status=1
        fi
    fi
done <"$list"

human() { # bytes
    awk -v b="$1" 'BEGIN { printf "%.2f MiB", b / 1048576 }'
}

if [ "$files" -eq 0 ]; then
    fail "HEAD lists no tracked files; refusing to report a false PASS"
fi
printf 'repo_size: tracked total %s bytes (%s) over %s files; budget %s bytes (%s)\n' \
    "$total" "$(human "$total")" "$files" \
    "$TOTAL_BUDGET_BYTES" "$(human "$TOTAL_BUDGET_BYTES")"
if [ "$total" -gt "$TOTAL_BUDGET_BYTES" ]; then
    printf 'repo_size: total over budget: %s > %s bytes\n' \
        "$total" "$TOTAL_BUDGET_BYTES" >&2
    status=1
fi
if [ "$oversize" -gt 0 ]; then
    printf 'repo_size: %s tracked file(s) over the %s per-file budget\n' \
        "$oversize" "$(human "$FILE_BUDGET_BYTES")" >&2
fi
if [ "$cached" -gt 0 ]; then
    printf 'repo_size: %s tracked .zig-cache path(s); remove them from git\n' \
        "$cached" >&2
fi
if [ "$status" -ne 0 ]; then
    fail "size budget exceeded"
fi
echo "repo_size: PASS (HEAD within size budgets)"
