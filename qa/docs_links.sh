#!/bin/sh
# Validate relative Markdown links in the tracked repository.
#
# A broken relative link is a stale-doc bug: the file it promised is gone. This
# gate walks every tracked `*.md`, extracts inline links and images
# (including `[text](<path with spaces>)` and optional `"title"` suffixes),
# and resolves each target against the Markdown file's own directory.
#
# Skipped on purpose (they are not repository-relative file links):
#   * `#anchor` targets and trailing `#fragment` parts (anchor existence is not
#     checked; Markdown renderers slugify headings differently)
#   * `http:`, `https:`, `mailto:`, and other URI schemes / site-absolute paths
#   * fenced code blocks, so examples never count as links
#
# Links are checked against the working tree (a clean CI checkout equals HEAD).
# Missing tracked files (e.g. a deletion staged but not yet committed) are
# skipped like an absent file; the committed tree is what CI sees.
#
# Usage: sh qa/docs_links.sh
# Exit:  0 all relative links resolve, 1 any dangling link.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TAB=$(printf '\t')

fail() {
    echo "docs_links: FAIL ($*)" >&2
    exit 1
}

enumerate_markdown() { # DEST
    dest=$1
    if command -v git >/dev/null 2>&1 &&
        git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$ROOT" ls-files '*.md' >"$dest"
    else
        (
            cd "$ROOT"
            find . -type f -name '*.md' \
                -not -path './.git/*' -not -path './.zig-cache/*' \
                -not -path './zig-out/*' -not -path './.tools/*' |
                sed 's|^\./||' | LC_ALL=C sort
        ) >"$dest"
    fi
}

# extract_links FILE prints "<line-number TAB target>" for every inline link.
# Fenced code blocks are skipped; a fence closes only on the same marker
# character (``` or ~~~) with at least the opening length, so examples inside
# a fence are never reported. The loop restarts the match after each link so
# several links on one line are all reported.
extract_links() { # FILE
    awk '
        BEGIN { fence = 0; marker = ""; length_ = 0 }
        {
            line = $0
            if (match(line, /^[ \t]*```+/) || match(line, /^[ \t]*~~~+/)) {
                cand = substr(line, RSTART, RLENGTH)
                sub(/^[ \t]*/, "", cand)
                if (fence == 0) {
                    fence = 1
                    marker = substr(cand, 1, 1)
                    length_ = length(cand)
                    next
                }
                if (substr(cand, 1, 1) == marker && length(cand) >= length_) {
                    fence = 0
                    next
                }
            }
            if (fence) next
            while (match(line, /[]][(][^)]*[)]/)) {
                target = substr(line, RSTART + 2, RLENGTH - 3)
                print NR "\t" target
                line = substr(line, RSTART + RLENGTH)
            }
        }' "$1"
}

files=$(mktemp)
links=$(mktemp)
trap 'rm -f "$files" "$links"' EXIT HUP INT TERM
enumerate_markdown "$files"

checked=0
skipped=0
markdown_files=0
status=0
while IFS= read -r md; do
    [ -n "$md" ] || continue
    path=$ROOT/$md
    [ -f "$path" ] || continue
    markdown_files=$((markdown_files + 1))
    dir=$(dirname -- "$md")
    extract_links "$path" >"$links"
    while IFS="$TAB" read -r lineno raw; do
        target=$raw
        # Optional Markdown title after the destination: (path "title").
        # Strip it first so (<path> "title") also works.
        space_title=" \""
        case "$target" in
            *"$space_title"*) target=${target%%"$space_title"*} ;;
        esac
        space_title=" '"
        case "$target" in
            *"$space_title"*) target=${target%%"$space_title"*} ;;
        esac
        # Angle-bracket form: [text](<path with spaces>).
        case "$target" in
            \<*\>) target=${target#<} && target=${target%>} ;;
        esac
        # Drop the fragment; a pure anchor is not a file link.
        file_target=${target%%#*}
        [ -n "$file_target" ] || {
            skipped=$((skipped + 1))
            continue
        }
        case "$file_target" in
            http://* | https://* | mailto:* | tel:* | ftp://* | /*)
                skipped=$((skipped + 1))
                continue
                ;;
            *:*)
                # Any other URI scheme (data:, etc.) is external to the repo.
                skipped=$((skipped + 1))
                continue
                ;;
        esac
        checked=$((checked + 1))
        resolved=$dir/$file_target
        if [ ! -e "$resolved" ]; then
            printf 'docs_links: BROKEN %s:%s -> %s (resolved: %s)\n' \
                "$md" "$lineno" "$file_target" "$resolved" >&2
            status=1
        fi
    done <"$links"
done <"$files"

if [ "$status" -ne 0 ]; then
    fail "dangling relative Markdown link(s)"
fi
printf 'docs_links: PASS (%s relative links in %s markdown files; %s external/anchor skipped)\n' \
    "$checked" "$markdown_files" "$skipped"
