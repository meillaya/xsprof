#!/bin/sh
# Deterministic accessibility-tree gate: no window, no user settings.
# Uses the CPU snapshot path for the product routes and compares two runs.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
DEMO="$ROOT/fixtures/ui/design/demo.json"
[ -x "$BIN" ] || { echo "a11y_smoke: build first" >&2; exit 1; }
[ -f "$DEMO" ] || { echo "a11y_smoke: missing demo model" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

for view in home audit settings; do
    "$BIN" snapshot --demo-model "$DEMO" --view "$view" --theme dark \
        --width 1280 --height 720 --out "$TMP/$view.png" --a11y "$TMP/$view.json" >/dev/null
    "$BIN" snapshot --demo-model "$DEMO" --view "$view" --theme dark \
        --width 1280 --height 720 --out "$TMP/$view-2.png" --a11y "$TMP/$view-2.json" >/dev/null
    cmp -s "$TMP/$view.json" "$TMP/$view-2.json" || {
        echo "a11y_smoke: $view tree is not deterministic" >&2
        exit 1
    }
    grep -q '"schema":"xsprof/a11y-tree/v1"' "$TMP/$view.json" || {
        echo "a11y_smoke: $view schema missing" >&2
        exit 1
    }
    if grep -q '"role":"none"' "$TMP/$view.json"; then
        echo "a11y_smoke: $view exposes a pointer-only role" >&2
        exit 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$TMP/$view.json" <<'PY'
import json, sys
tree = json.load(open(sys.argv[1], encoding="utf-8"))
nodes = tree["nodes"]
assert isinstance(nodes, list) and nodes, "empty tree"
seen = set()
for node in nodes:
    if node["id"]:
        assert node["id"] not in seen, f"duplicate id {node['id']}"
        seen.add(node["id"])
    assert node["label"], f"empty label for {node['id']} ({node['role']})"
    assert node["role"] != "none", "pointer-only role"
    assert node["role"] in {
        "window", "tabpanel", "tab", "button", "textbox", "list", "listitem",
        "dialog", "status", "heading", "progressbar",
    }, node["role"]
PY
    fi
done
echo "a11y_smoke: PASS (deterministic home/audit/settings trees)"
