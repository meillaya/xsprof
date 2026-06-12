#!/usr/bin/env bash
set -euo pipefail
plan=""
evidence=""
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) [ "$#" -ge 2 ] || fail '--plan requires value'; plan="$2"; shift 2 ;;
    --evidence) [ "$#" -ge 2 ] || fail '--evidence requires value'; evidence="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -f "$plan" ] || fail 'plan missing'
[ -d "$evidence" ] || fail 'evidence dir missing'
bash qa/wording_audit.sh >/dev/null
bash qa/wording_audit.sh --self-test >/dev/null
bash qa/no_host_mutation.sh >/dev/null
bash qa/restructure_check.sh >/dev/null
bash qa/security_gate.sh --profile mutation-capable-lab --review fixtures/lab/security-review-approved.json >/dev/null
bash qa/package_defaults.sh --mode inspect >/dev/null
approval_file="$evidence/final-reviewer-approval.txt"
[ -f "$approval_file" ] || fail "final reviewer approval missing: $approval_file"
grep -q '^APPROVED:' "$approval_file" || fail 'final reviewer approval missing APPROVED marker'
python3 - <<'PY'
import json
from pathlib import Path
summary=Path('evidence/releases/0.2.0-lab/summary.json')
approval=Path('evidence/releases/0.2.0-lab/release-approval.json')
if not summary.exists() or not approval.exists():
    raise SystemExit('release artifacts missing')
s=json.loads(summary.read_text())
a=json.loads(approval.read_text())
if s.get('release_status')!='controlled_lab_pilot_candidate':
    raise SystemExit('bad release_status')
if s.get('production_ready') is not False:
    raise SystemExit('summary production_ready is not false')
if a.get('status')!='controlled_lab_pilot_candidate':
    raise SystemExit('bad approval status')
if a.get('production_ready') is not False or a.get('arbitrary_host_safe') is not False:
    raise SystemExit('approval safety flags are not false')
PY
if grep -RInE 'full switch|full-switch|global attach|arbitrary production hosts.*safe' src README.md docs packaging 2>/dev/null; then
  fail 'scope drift wording found'
fi
printf 'PASS: scope fidelity plan=%s evidence=%s\n' "$plan" "$evidence"
