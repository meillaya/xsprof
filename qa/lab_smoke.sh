#!/bin/sh
# Headless GUI lab gate: built-in scenarios, assertions, snapshots, and a
# deliberately failing run. No window and no host mutation.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$ROOT/zig-out/bin/xsprof"
[ -x "$BIN" ] || { echo "lab_smoke: build first (zig build)" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

"$BIN" lab --list >"$TMP/list"
for id in healthy loss empty scheduler-mix; do
    grep -q "$id.json" "$TMP/list" || { echo "lab_smoke: $id missing from --list" >&2; exit 1; }
done

for id in healthy loss empty scheduler-mix; do
    "$BIN" lab --scenario "$ROOT/scenarios/$id.json" --out "$TMP/$id" --json \
        >"$TMP/$id.json"
    grep -q '"status":"passed"' "$TMP/$id.json" || {
        echo "lab_smoke: $id did not pass" >&2
        exit 1
    }
    grep -q '"host_mutation":false' "$TMP/$id.json" || {
        echo "lab_smoke: $id omitted host_mutation=false" >&2
        exit 1
    }
    for png in "$TMP/$id"/*.png; do
        sig=$(od -An -tx1 -N8 "$png" | tr -d ' \n')
        [ "$sig" = "89504e470d0a1a0a" ] || {
            echo "lab_smoke: $id has a bad PNG" >&2
            exit 1
        }
    done
done

cat >"$TMP/failing.json" <<'JSON'
{
  "schema": "xsprof/lab-scenario/v1",
  "id": "must-fail",
  "source": {"kind": "fixture", "path": "fixtures/ui/empty.ndjson"},
  "steps": [{"at_ms": 0, "action": "screen", "value": "overview"}],
  "assertions": [{"metric": "events", "op": "eq", "value": "999999"}]
}
JSON
if "$BIN" lab --scenario "$TMP/failing.json" --json >"$TMP/failing.out" 2>/dev/null; then
    echo "lab_smoke: failing assertion exited zero" >&2
    exit 1
fi
grep -q '"status":"failed"' "$TMP/failing.out" || {
    echo "lab_smoke: failure status missing" >&2
    exit 1
}
echo "lab_smoke: PASS"
