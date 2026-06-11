#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

run() {
  printf 'RUN: %s\n' "$*"
  "$@"
}

require_file() {
  local label="$1"
  local path="$2"
  [ -f "$path" ] || fail "$label missing: $path"
  pass "$label present: $path"
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/zig-scheduler-clean-archive.XXXXXX")"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

archive_dir="$tmp/archive"
clone_dir="$tmp/fresh-clone"
mkdir -p "$archive_dir"

printf 'repo_root=%s\n' "$repo_root"
printf 'git_sha=%s\n' "$(git rev-parse HEAD)"
printf 'tmp=%s\n' "$tmp"

printf 'RUN: git archive HEAD | tar -t | grep -E '\''^(AGENTS.md|WORKLOG.md|docs/security/threat-model.md|docs/releases/governance-gate.md)'\''\n'
git archive HEAD | tar -t | grep -E '^(AGENTS.md|WORKLOG.md|docs/security/threat-model.md|docs/releases/governance-gate.md)' >/tmp/zig-scheduler-clean-archive-list.$$ || fail 'archive proof missing required governance sources'
cat /tmp/zig-scheduler-clean-archive-list.$$
rm -f /tmp/zig-scheduler-clean-archive-list.$$
pass 'archive_proof includes AGENTS.md WORKLOG.md docs/security/threat-model.md docs/releases/governance-gate.md'

git archive HEAD | tar -x -C "$archive_dir"
require_file 'docs' "$archive_dir/docs/security/threat-model.md"
require_file 'AGENTS.md' "$archive_dir/AGENTS.md"
require_file 'WORKLOG.md' "$archive_dir/WORKLOG.md"
require_file 'wording_audit' "$archive_dir/qa/wording_audit.sh"

(
  cd "$archive_dir"
  bash qa/wording_audit.sh >/tmp/zig-scheduler-clean-archive-wording.$$.out
)
pass 'wording_audit passes in git archive extraction'
rm -f /tmp/zig-scheduler-clean-archive-wording.$$.out

printf 'RUN: git clone %s %s\n' "$repo_root" "$clone_dir"
git clone "$repo_root" "$clone_dir" >/tmp/zig-scheduler-clean-archive-clone.$$.out 2>&1 || {
  cat /tmp/zig-scheduler-clean-archive-clone.$$.out >&2 || true
  fail 'fresh clone failed'
}
rm -f /tmp/zig-scheduler-clean-archive-clone.$$.out

(
  cd "$clone_dir"
  git checkout --quiet "$(git -C "$repo_root" rev-parse HEAD)"
  require_file 'docs' docs/security/threat-model.md
  require_file 'AGENTS.md' AGENTS.md
  require_file 'WORKLOG.md' WORKLOG.md
  bash qa/wording_audit.sh >/tmp/zig-scheduler-clean-clone-wording.$$.out
  pass 'wording_audit passes in fresh clone'
  rm -f /tmp/zig-scheduler-clean-clone-wording.$$.out
  bash qa/security_gate.sh --profile read-only >/tmp/zig-scheduler-clean-clone-security.$$.out
  pass 'security_gate read-only passes in fresh clone'
  rm -f /tmp/zig-scheduler-clean-clone-security.$$.out
  bash qa/package_defaults.sh --mode inspect >/tmp/zig-scheduler-clean-clone-package.$$.out
  pass 'package defaults pass in fresh clone'
  rm -f /tmp/zig-scheduler-clean-clone-package.$$.out
  if command -v zig >/dev/null 2>&1; then
    printf 'RUN: git clone <local repo> <tmp> && cd <tmp> && zig build test --summary all && bash qa/release_gate.sh --version 0.1.0-lab --evidence evidence/releases/0.1.0-lab\n'
    zig build test --summary all
  else
    fail 'zig is required for the exact fresh-clone proof'
  fi
  bash qa/release_gate.sh --version 0.1.0-lab --evidence evidence/releases/0.1.0-lab >/tmp/zig-scheduler-clean-clone-release.$$.out
  pass 'release_gate passes in fresh clone'
  rm -f /tmp/zig-scheduler-clean-clone-release.$$.out
)

pass 'clean archive and fresh clone reproducibility gate complete'
