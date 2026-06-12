#!/usr/bin/env bash
set -euo pipefail
summary=""
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary) [ "$#" -ge 2 ] || fail '--summary requires a value'; summary="$2"; shift 2 ;;
    --help|-h) printf 'usage: %s --summary evidence/lab/stress-chaos/summary.json\n' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$summary" ] || fail '--summary is required'
case "$summary" in *$'\n'*|*$'\r'*) fail 'summary path must not contain newlines' ;; esac
python3 - <<'PY' "$summary"
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))
sys.path.insert(0, str(Path.cwd() / 'qa'))
from qa.runtime_sample_check import validate_file

summary = json.loads(Path(sys.argv[1]).read_text())
if summary.get('schema') != 'zig-scheduler/stress-chaos-summary/v1':
    raise SystemExit('unsupported stress summary schema')
if summary.get('status') != 'PASS':
    raise SystemExit('stress summary status is not PASS')
if summary.get('host_mutation') is not False:
    raise SystemExit('stress summary host_mutation must be false')
if summary.get('rollback_result') != 'PASS':
    raise SystemExit('stress rollback_result must be PASS')
cleanup = summary.get('cleanup')
if not isinstance(cleanup, dict):
    raise SystemExit('stress summary missing cleanup object')
if cleanup.get('qemu_leftovers') is not False or cleanup.get('tmux_leftovers') is not False:
    raise SystemExit('stress cleanup left guest/host leftovers')
if summary.get('fallback_reject_threshold_breach') is not False:
    raise SystemExit('stress fallback/reject threshold breached')
series = Path(str(summary.get('latency_fairness_series', '')))
if not series.is_file() or series.read_text().strip() == '':
    raise SystemExit('missing latency/fairness series')
vm_kind = summary.get('vm_kind')
if vm_kind == 'vm-live':
    samples = Path(str(summary.get('runtime_samples', '')))
    if summary.get('runtime_sample_linkage') != 'vm-live-runtime-stream':
        raise SystemExit('VM-live stress summary is not linked to runtime stream')
    if not samples.is_file():
        raise SystemExit('VM-live stress runtime samples are missing')
    validate_file(samples)
    rows = [json.loads(line) for line in samples.read_text().splitlines() if line.strip()]
    if len(rows) < 3:
        raise SystemExit('VM-live stress requires before/during/after runtime samples')
    if not any(row.get('ops', {}).get('value') == 'zigsched_minimal' for row in rows[1:-1]):
        raise SystemExit('VM-live stress samples never show zigsched_minimal during attach')
    if not all(row.get('workload_alive') is True for row in rows):
        raise SystemExit('VM-live stress workload is not alive in every sample')
    pattern = re.compile(r'(nr_rejected|dispatch_failed|fallbacks?|fatal)[:=]\s*([0-9]+)')
    def counters(row):
        raw = row.get('events', {}).get('value', '')
        return {('fallback' if key.startswith('fallback') else key): int(value) for key, value in pattern.findall(raw)}
    first = counters(rows[0])
    last = counters(rows[-1])
    for key in ('nr_rejected', 'dispatch_failed', 'fallback', 'fatal'):
        if key not in first or key not in last:
            raise SystemExit(f'VM-live stress samples missing counter: {key}')
        if last[key] > first[key]:
            raise SystemExit(f'VM-live stress counter grew: {key}')
elif vm_kind != 'host-safe-disposable-sysroot':
    raise SystemExit(f'unsupported stress vm_kind: {vm_kind}')
print(f"PASS stress/chaos summary: {sys.argv[1]}")
PY
