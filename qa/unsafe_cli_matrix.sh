#!/bin/sh
# Unsafe-verb matrix: every mutation-looking verb and unknown input must fail
# closed with canonical JSON before any dispatch.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
[ -x "$BIN" ] || { echo "unsafe_cli_matrix: build first" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail=0
for verb in load attach enable mutate apply sched-ext-attach setaffinity setpriority bind; do
    if "$BIN" "$verb" >"$TMP/out" 2>/dev/null; then
        echo "unsafe_cli_matrix: $verb exited zero" >&2
        fail=1
    fi
    grep -q '"event":"refusal"' "$TMP/out" || { echo "unsafe_cli_matrix: $verb missing refusal" >&2; fail=1; }
    grep -q '"host_mutation":false' "$TMP/out" || { echo "unsafe_cli_matrix: $verb mutation flag" >&2; fail=1; }
done
if "$BIN" definitely-not-a-verb >"$TMP/out" 2>/dev/null; then
    echo "unsafe_cli_matrix: unknown verb exited zero" >&2
    fail=1
fi
grep -q '"status":"refused"' "$TMP/out" || { echo "unsafe_cli_matrix: unknown verb not refused" >&2; fail=1; }
"$BIN" help >/dev/null
"$BIN" version >/dev/null
"$BIN" top --help >/dev/null
"$BIN" why --help >/dev/null
[ "$fail" -eq 0 ] || exit 1
echo "unsafe_cli_matrix: PASS"
