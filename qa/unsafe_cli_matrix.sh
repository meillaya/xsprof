#!/usr/bin/env bash
# Unsafe CLI verb matrix for the C++ xsprof binary.
# Every unsafe verb must refuse with non-zero exit and a structured refusal
# JSON carrying host_mutation=false. Mirrors the archived Zig project's
# qa/unsafe_cli_matrix.sh for the C++ rewrite.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'FAIL: %s
' "$*" >&2
  exit 1
}

# Build if the binary is missing.
if [ ! -x build/xsprof ]; then
  cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null 2>&1
  cmake --build build -j"$(nproc)" >/dev/null 2>&1
fi

BIN=build/xsprof
[ -x "$BIN" ] || fail "xsprof binary not found at $BIN"

check_refusal() {
  local label="$1"
  shift
  local out rc
  out="$(mktemp "${TMPDIR:-/tmp}/xsprof-unsafe-${label}.XXXXXX")"
  set +e
  "$@" >"$out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label unexpectedly succeeded (rc=0)"
  fi
  # Must emit a structured refusal with host_mutation=false.
  grep -q '"host_mutation":false' "$out" || {
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label missing host_mutation=false in refusal"
  }
  grep -Eiq 'refus|unsafe|disabled|fail-closed' "$out" || {
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label missing refusal explanation"
  }
  rm -f "$out"
  printf 'PASS: %s refused rc=%s
' "$label" "$rc"
}

# --- All 9 unsafe verbs must refuse non-zero ---
for verb in load attach enable mutate apply sched-ext-attach setaffinity setpriority bind; do
  check_refusal "verb-$verb" "$BIN" "$verb"
done

# --- Unknown verbs also refuse (fail-closed default) ---
check_refusal "unknown-verb" "$BIN" "destroy-everything"
check_refusal "unknown-sched-ext-load" "$BIN" "sched-ext" "load"
check_refusal "unknown-controller-apply" "$BIN" "controller" "apply"

# --- Safe verbs must NOT refuse (exit 0 or usage error, not refusal) ---
check_safe() {
  local label="$1"
  shift
  local out rc
  out="$(mktemp "${TMPDIR:-/tmp}/xsprof-safe-${label}.XXXXXX")"
  set +e
  "$@" >"$out" 2>&1
  rc=$?
  set -e
  # Safe verbs should not produce a refusal JSON.
  if grep -q '"event":"refusal"' "$out"; then
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label was refused but should be safe"
  fi
  rm -f "$out"
  printf 'PASS: %s not refused (rc=%s)
' "$label" "$rc"
}

check_safe "help" "$BIN" "help"
check_safe "version" "$BIN" "version"

printf 'PASS: unsafe CLI matrix (%s)
' "$BIN"
