#!/usr/bin/env bash
set -euo pipefail
plan=""
evidence=""
default_plan=".omo/plans/qa-script-consolidation.md"
default_evidence=".omo/evidence/qa-script-consolidation"
compatibility_default="false"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
usage: bash qa/scope_fidelity.sh [--plan <plan.md> --evidence <evidence-dir-or-report-file>]

Validates the QA script consolidation scope against a plan and
evidence directory. When --evidence names a report file, the containing
directory is used for evidence checks. With no arguments, this T03
compatibility entrypoint uses .omo/plans/qa-script-consolidation.md and
.omo/evidence/qa-script-consolidation, and prints that explicit scope in the
PASS line. The evidence directory must contain final-reviewer-approval.txt
with an APPROVED: marker. Partial argument sets still fail so CI cannot
silently mix scopes.
EOF
}
if [ "$#" -eq 0 ]; then
  plan="$default_plan"
  evidence="$default_evidence"
  compatibility_default="true"
fi
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
[ "$compatibility_default" = "false" ] || {
  [ "$plan" = "$default_plan" ] || fail "internal default plan drifted: $plan"
  [ "$evidence" = "$default_evidence" ] || fail "internal default evidence drifted: $evidence"
}
[ -f "$plan" ] || fail "plan missing: $plan"
if [ -d "$evidence" ]; then
  evidence_dir="$evidence"
elif [ -f "$evidence" ]; then
  evidence_dir="$(dirname -- "$evidence")"
else
  fail "evidence path missing: $evidence"
fi
compatibility_scope="false"
if [ "$plan" = "$default_plan" ] && [ "$evidence_dir" = "$default_evidence" ]; then
  compatibility_scope="true"
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
scope_drift_matches="$(
  grep -RInE --exclude-dir=vendor 'full switch|full-switch|global attach|arbitrary production hosts.*safe' src README.md docs packaging 2>/dev/null |
    grep -Eiv 'does not authorize|must not|do not|not supported|not safe|never' || true
)"
if [ -n "$scope_drift_matches" ]; then
  printf '%s\n' "$scope_drift_matches"
  fail 'scope drift wording found'
fi
printf 'PASS: scope fidelity mode=%s compatibility_scope=%s plan=%s evidence=%s evidence_dir=%s\n' "$compatibility_default" "$compatibility_scope" "$plan" "$evidence" "$evidence_dir"
