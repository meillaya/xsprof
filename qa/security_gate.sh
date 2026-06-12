#!/usr/bin/env bash
set -euo pipefail
trusted_path="/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:${HOME:-}/.nix-profile/bin"
export PATH="$trusted_path"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
profile=""
review_artifact=""
self_test=false
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

validate_governance_manifest() {
  python3 "$repo_root/qa/governance_manifest_check.py" --manifest "$repo_root/fixtures/lab/governance-sources.json" || fail 'missing tracked governance source: governance manifest validation failed'
}
reject_nohost_bypass_env() {
  [ "${ZIG_SCHEDULER_ALLOW_NO_STRACE:-}" != "1" ] || fail 'security gate rejects ambient ZIG_SCHEDULER_ALLOW_NO_STRACE'
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --self-test) self_test=true; shift ;;
    --profile) [ "$#" -ge 2 ] || fail '--profile requires value'; profile="$2"; shift 2 ;;
    --review) [ "$#" -ge 2 ] || fail '--review requires value'; review_artifact="$2"; shift 2 ;;
    --help|-h) echo 'usage: qa/security_gate.sh --self-test | --profile read-only|mutation-capable-lab [--review file]'; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
if [ "$self_test" = true ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp fixtures/lab/security-review-approved.json "$tmp/placeholder.json"
  python3 - <<'PY' "$tmp/placeholder.json"
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['reviewer'] = 'TODO'
data['signed_attestation']['signed_by'] = 'TODO'
path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
PY
  if bash qa/security_gate.sh --profile mutation-capable-lab --review "$tmp/placeholder.json" >/dev/null 2>&1; then
    fail 'self-test expected placeholder reviewer rejection'
  fi
  cp fixtures/lab/security-review-approved.json "$tmp/unsigned.json"
  python3 - <<'PY' "$tmp/unsigned.json"
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data.pop('signed_attestation', None)
path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
PY
  if bash qa/security_gate.sh --profile mutation-capable-lab --review "$tmp/unsigned.json" >/dev/null 2>&1; then
    fail 'self-test expected unsigned review rejection'
  fi
  cp fixtures/lab/security-review-approved.json "$tmp/stale-unbound.json"
  python3 - <<'PY' "$tmp/stale-unbound.json"
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['git_sha'] = '0' * 40
data.pop('git_sha_policy', None)
data['historical'] = False
path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
PY
  if bash qa/security_gate.sh --profile mutation-capable-lab --review "$tmp/stale-unbound.json" >/dev/null 2>&1; then
    fail 'self-test expected stale unbound review rejection'
  fi
  cp fixtures/lab/security-review-approved.json "$tmp/historical-missing-reason.json"
  python3 - <<'PY' "$tmp/historical-missing-reason.json"
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['historical'] = True
data.pop('historical_reason', None)
path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
PY
  if bash qa/security_gate.sh --profile mutation-capable-lab --review "$tmp/historical-missing-reason.json" >/dev/null 2>&1; then
    fail 'self-test expected historical reason rejection'
  fi
  if ZIG_SCHEDULER_ALLOW_NO_STRACE=1 bash qa/security_gate.sh --profile read-only >/dev/null 2>&1; then
    fail 'self-test expected ambient no-strace security bypass rejection'
  fi
  bash qa/security_gate.sh --profile mutation-capable-lab --review fixtures/lab/security-review-approved.json >/dev/null
  echo 'PASS security gate self-test: reviewer policy, git SHA policy, signed attestation, and ambient no-strace bypass rejection enforced'
  exit 0
fi
[ -n "$profile" ] || fail '--profile is required'
reject_nohost_bypass_env
validate_governance_manifest
case "$profile$review_artifact" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
[ -f docs/security/threat-model.md ] || fail 'threat model missing'
[ -f docs/security/review-checklist.md ] || fail 'review checklist missing'
grep -q 'CAP_BPF' docs/security/threat-model.md || fail 'CAP_BPF missing from threat model'
grep -q 'CAP_SYS_ADMIN' docs/security/threat-model.md || fail 'CAP_SYS_ADMIN missing from threat model'
grep -q 'CAP_PERFMON' docs/security/threat-model.md || fail 'CAP_PERFMON missing from threat model'
grep -qi 'config injection' docs/security/threat-model.md || fail 'config injection missing'
grep -qi 'cgroup escape' docs/security/threat-model.md || fail 'cgroup escape missing'
grep -qi 'audit tampering' docs/security/threat-model.md || fail 'audit tampering missing'
grep -qi 'BPF verifier' docs/security/threat-model.md || fail 'BPF verifier missing'
grep -qi 'Log privacy' docs/security/threat-model.md || fail 'log privacy missing'
grep -qi 'Packaging defaults' docs/security/threat-model.md || fail 'packaging defaults missing'
case "$profile" in
  read-only)
    bash qa/no_host_mutation.sh >/dev/null
    bash qa/wording_audit.sh >/dev/null
    echo 'PASS: read-only security gate satisfied'
    ;;
  mutation-capable-lab)
    [ -n "$review_artifact" ] || fail 'mutation-capable profile requires --review artifact'
    case "$review_artifact" in /*|*'/../'*|../*|*/..) fail 'unsafe review path' ;; esac
    [ -f "$review_artifact" ] || fail 'security review artifact missing'
    REVIEW="$review_artifact" python3 - <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path
p=os.environ['REVIEW']
with open(p) as f: data=json.load(f)
required=['root_privileges_capabilities','config_injection','cgroup_escape','audit_tampering','bpf_verifier_assumptions','log_privacy','packaging_defaults','package_lifecycle','privacy_review','security_signoff','rollback_fallback','production_claims']
if data.get('schema')!='zig-scheduler/security-review/v1': sys.exit('bad schema')
if data.get('profile')!='mutation-capable-lab': sys.exit('bad profile')
if data.get('status')!='approved': sys.exit('not approved')
reviewer=data.get('reviewer')
if not reviewer: sys.exit('missing reviewer')
if str(reviewer).lower() in {'todo','tbd','placeholder','unknown','repository-owner-operator'}: sys.exit('placeholder reviewer')
policy=data.get('reviewer_policy') or {}
if policy.get('kind') != 'owner-override': sys.exit('missing reviewer_policy.kind')
if policy.get('human_approval_fabricated') is not False: sys.exit('reviewer policy must not fabricate human approval')
current_git_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
review_git_sha = data.get('git_sha')
if not review_git_sha: sys.exit('missing security review git_sha')
if data.get('historical') is True and not data.get('historical_reason'):
    sys.exit('historical security review missing reason')
git_policy = data.get('git_sha_policy') or {}
if review_git_sha != current_git_sha:
    if git_policy.get('kind') != 'content-bound-ancestor':
        sys.exit('stale security review git_sha')
    ancestor = subprocess.run(
        ['git', 'merge-base', '--is-ancestor', str(review_git_sha), current_git_sha],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if ancestor.returncode != 0: sys.exit('security review git_sha is not an ancestor')
    for path, expected in (git_policy.get('sha256') or {}).items():
        actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        if actual != expected: sys.exit('security review content hash mismatch: '+path)
if data.get('authorized_status') != 'controlled_lab_pilot_candidate': sys.exit('bad authorized status')
if data.get('scope') != 'controlled-lab-only': sys.exit('bad review scope')
att=data.get('signed_attestation') or {}
for key in ['kind','signed_by','signed_at','statement','authorized_status','scope']:
    if not att.get(key): sys.exit('missing signed_attestation.'+key)
if att.get('signed_by') != reviewer: sys.exit('attestation signer must match reviewer')
if att.get('authorized_status') != data.get('authorized_status'): sys.exit('attestation status mismatch')
if att.get('scope') != data.get('scope'): sys.exit('attestation scope mismatch')
check=data.get('checklist') or {}
missing=[k for k in required if check.get(k) is not True]
if missing: sys.exit('missing checklist: '+','.join(missing))
PY
    echo 'PASS: mutation-capable security review artifact accepted'
    ;;
  *) fail 'profile must be read-only or mutation-capable-lab' ;;
esac
