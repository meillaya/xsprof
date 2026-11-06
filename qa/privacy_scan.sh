#!/bin/sh
# Privacy boundary: seeded secrets must not survive canonical output, and a
# mutation-bearing journal must be refused.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
[ -x "$BIN" ] || { echo "privacy_scan: build first" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
SECRET="supersecret-value-987654"
cat >"$TMP/secret.ndjson" <<EOF
{"a":0,"b":0,"c":0,"comm":"worker","cpu":0,"detail":"token=$SECRET api_key=abc Bearer xyz","event":"marker","host_mutation":false,"pid":1,"schema":"xsprof/event/v1","tid":1,"ts_ns":1}
{"a":0,"b":0,"c":0,"comm":"worker","cpu":0,"detail":"safe","event":"marker","host_mutation":false,"pid":1,"schema":"xsprof/event/v1","tid":1,"ts_ns":2}
EOF
"$BIN" advise --input "$TMP/secret.ndjson" >"$TMP/advise" 2>/dev/null || true
"$BIN" metrics --input "$TMP/secret.ndjson" >"$TMP/metrics" 2>/dev/null || true
"$BIN" timeline --input "$TMP/secret.ndjson" >"$TMP/timeline" 2>/dev/null || true
if grep -R "$SECRET" "$TMP/advise" "$TMP/metrics" "$TMP/timeline" >/dev/null 2>&1; then
    echo "privacy_scan: secret leaked into output" >&2
    exit 1
fi
grep -q 'REDACTED' "$TMP/timeline" || { echo "privacy_scan: timeline did not redact" >&2; exit 1; }
cat >"$TMP/mutated.ndjson" <<'EOF'
{"a":0,"b":0,"c":0,"cpu":0,"event":"marker","host_mutation":true,"pid":1,"schema":"xsprof/event/v1","tid":1,"ts_ns":1}
EOF
if "$BIN" advise --input "$TMP/mutated.ndjson" >/dev/null 2>&1; then
    echo "privacy_scan: mutation-bearing journal accepted" >&2
    exit 1
fi
echo "privacy_scan: PASS"
