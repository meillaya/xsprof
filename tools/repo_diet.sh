#!/bin/sh
# One-time repository history diet. DESTRUCTIVE: rewrites every commit id.
#
# The tracked tree was already dieted (Phase C5a/C5b) to <=12 MiB, but old
# history still contains build caches, vendor corpora, evidence/media blobs and
# pre-diet captures. This script removes only paths that are gone from the
# current tree, so HEAD content is preserved.
#
# Run once, BEFORE the first release tag, from a clean checkout:
#   CONFIRM=1 sh tools/repo_diet.sh
#
# Then verify:
#   git log --oneline -2
#   git count-objects -vH
#   ./tools/zig build check
#
# The script refuses to run with a dirty worktree, creates a backup branch and
# a git bundle in the parent directory, and never pushes anything.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

[ "${CONFIRM:-0}" = "1" ] || {
    echo "repo_diet: refusing to rewrite history without CONFIRM=1" >&2
    exit 1
}
command -v git-filter-repo >/dev/null 2>&1 || {
    echo "repo_diet: git-filter-repo is required (developer tool, not a runtime dependency)" >&2
    exit 1
}
[ -z "$(git status --porcelain)" ] || {
    echo "repo_diet: working tree is dirty; commit or stash before history rewrite" >&2
    exit 1
}
[ -z "$(git tag --list 'v*')" ] || {
    echo "repo_diet: release tags already exist; do not rewrite tagged history" >&2
    exit 1
}

BACKUP_BRANCH="backup/pre-diet"
if ! git rev-parse --verify "$BACKUP_BRANCH" >/dev/null 2>&1; then
    git branch "$BACKUP_BRANCH" HEAD
fi
git bundle create "$ROOT/../xsprof-pre-diet-$(git rev-parse --short HEAD).bundle" --all
echo "repo_diet: backup branch $BACKUP_BRANCH and bundle written next to the checkout"

git filter-repo --force --invert-paths \
    --path .zig-cache \
    --path docs/vendor \
    --path docs/evidence \
    --path docs/media \
    --path docs/ui/screenshots \
    --path design/media \
    --path design/evidence \
    --path design/screenshots/breakpoints \
    --path design/screenshots/prototype

echo "repo_diet: history rewritten (local only; no push performed)"
git count-objects -vH
echo "repo_diet: re-run ./tools/zig build check before tagging"
