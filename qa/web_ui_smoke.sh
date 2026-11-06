#!/bin/sh
# Run the headless wasm gate when Node is available; CI has it, minimal VMs
# may not. The gate is still run explicitly by developers.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v node >/dev/null 2>&1; then
    echo "web_ui_smoke: SKIP (node unavailable)"
    exit 0
fi
cd "$ROOT"
exec node qa/web_ui_smoke.mjs
