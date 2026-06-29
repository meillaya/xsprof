#!/usr/bin/env bash
set -euo pipefail
plan=""
evidence=""
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
usage: bash qa/scope_fidelity.sh --plan <plan.md> --evidence <evidence-dir-or-report-file>

Validates the VM harness matrix hardening scope against an explicit plan and
evidence directory. When --evidence names a report file, the containing
directory is used for evidence checks. The plan argument is required so
CI/evidence logs name the scope being checked instead of silently defaulting to
a stale plan.
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --plan) [ "$#" -ge 2 ] || fail '--plan requires value'; plan="$2"; shift 2 ;;
    --evidence) [ "$#" -ge 2 ] || fail '--evidence requires value'; evidence="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$plan" ] || { usage >&2; fail 'plan missing; pass --plan <plan.md>'; }
[ -n "$evidence" ] || { usage >&2; fail 'evidence path missing; pass --evidence <dir-or-report-file>'; }
[ -f "$plan" ] || fail "plan missing: $plan"
if [ -d "$evidence" ]; then
  evidence_dir="$evidence"
elif [ -f "$evidence" ]; then
  evidence_dir="$(dirname -- "$evidence")"
else
  fail "evidence path missing: $evidence"
fi
bash qa/wording_audit.sh >/dev/null
bash qa/wording_audit.sh --self-test >/dev/null
bash qa/no_host_mutation.sh >/dev/null
bash qa/restructure_check.sh >/dev/null
bash qa/security_gate.sh --profile mutation-capable-lab --review fixtures/lab/security-review-approved.json >/dev/null
bash qa/package_defaults.sh --mode inspect >/dev/null
approval_file="$evidence_dir/final-reviewer-approval.txt"
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
if grep -RInE --exclude-dir=vendor 'full switch|full-switch|global attach|arbitrary production hosts.*safe' src README.md docs packaging 2>/dev/null; then
  fail 'scope drift wording found'
fi
printf 'PASS: scope fidelity plan=%s evidence=%s evidence_dir=%s\n' "$plan" "$evidence" "$evidence_dir"
