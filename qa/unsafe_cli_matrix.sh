#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

check_refusal() {
  local label="$1"
  shift
  local out rc before after
  out="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-unsafe-${label}.XXXXXX")"
  before="$(find zig-out -maxdepth 3 -type f 2>/dev/null | sort || true)"
  set +e
  "$@" >"$out" 2>&1
  rc=$?
  set -e
  after="$(find zig-out -maxdepth 3 -type f 2>/dev/null | sort || true)"
  if [ "$rc" -eq 0 ]; then
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label unexpectedly succeeded"
  fi
  grep -Eiq 'refus|unsupported|unsafe|read-only|no mutation|dry-run|mutation|preflight-first' "$out" || {
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label missing refusal explanation"
  }
  if [ "$before" != "$after" ]; then
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label changed zig-out file list"
  fi
  rm -f "$out"
  printf 'PASS: %s refused rc=%s\n' "$label" "$rc"
}

zig build --summary all >/dev/null

for verb in load attach enable mutate apply; do
  check_refusal "raw-$verb" zig-out/bin/zig-scheduler "$verb"
done
check_refusal sched-ext-load zig-out/bin/zig-scheduler sched-ext load
check_refusal sched-ext-attach zig-out/bin/zig-scheduler sched-ext attach
check_refusal controller-apply zig-out/bin/zig-scheduler controller apply
check_refusal controller-mutate zig-out/bin/zig-scheduler controller mutate
check_refusal scheduler-enable zig-out/bin/zig-scheduler scheduler enable

printf 'PASS: unsafe CLI matrix\n'
