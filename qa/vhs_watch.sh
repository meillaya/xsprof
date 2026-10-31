#!/bin/sh
# Build a temporary recorder state from a real perf capture, then run the
# terminal profiler for vhs. No host state is touched outside the temp dir.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
[ -x "$BIN" ] || {
    echo "vhs_watch: build first (./tools/zig build)" >&2
    exit 1
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/segments"
cp "$ROOT/fixtures/real/scheduler-mix.ndjson" "$TMP/segments/demo.ndjson"
bytes=$(wc -c <"$TMP/segments/demo.ndjson" | tr -d ' ')
events=$(wc -l <"$TMP/segments/demo.ndjson" | tr -d ' ')
now_s=$(date +%s)
start_ns=$((now_s * 1000000000 - 120000000000))
end_ns=$((now_s * 1000000000 - 1000000000))
cat >"$TMP/manifest.json" <<EOF
{"host_mutation":false,"max_age_ms":600000,"max_bytes":2147483648,"schema":"xsprof/recorder-manifest/v1","segments":[{"bytes":$bytes,"closed":true,"end_mono_ns":$end_ns,"end_wall_ns":$end_ns,"events":$events,"path":"segments/demo.ndjson","start_mono_ns":$start_ns,"start_wall_ns":$start_ns}],"session_id":"vhs-real-capture","started_mono_ns":$start_ns,"started_wall_ns":$start_ns,"state":"stopped","updated_wall_ns":$((now_s * 1000000000))}
EOF
# Keep only the last minute of wall-clock history visible to the viewer.
exec "$BIN" watch --dir "$TMP" --window 1m --duration 9000
