#!/usr/bin/env bash
set -euo pipefail
profile=""
review_artifact=""
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) [ "$#" -ge 2 ] || fail '--profile requires value'; profile="$2"; shift 2 ;;
    --review) [ "$#" -ge 2 ] || fail '--review requires value'; review_artifact="$2"; shift 2 ;;
    --help|-h) echo 'usage: qa/security_gate.sh --profile read-only|mutation-capable-lab [--review file]'; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$profile" ] || fail '--profile is required'
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
import json, os, sys
p=os.environ['REVIEW']
with open(p) as f: data=json.load(f)
required=['root_privileges_capabilities','config_injection','cgroup_escape','audit_tampering','bpf_verifier_assumptions','log_privacy','packaging_defaults','rollback_fallback','production_claims']
if data.get('schema')!='zig-scheduler/security-review/v1': sys.exit('bad schema')
if data.get('profile')!='mutation-capable-lab': sys.exit('bad profile')
if data.get('status')!='approved': sys.exit('not approved')
if not data.get('reviewer'): sys.exit('missing reviewer')
att=data.get('signed_attestation') or {}
for key in ['kind','signed_by','signed_at','statement']:
    if not att.get(key): sys.exit('missing signed_attestation.'+key)
if att.get('signed_by') != data.get('reviewer'): sys.exit('attestation signer must match reviewer')
check=data.get('checklist') or {}
missing=[k for k in required if check.get(k) is not True]
if missing: sys.exit('missing checklist: '+','.join(missing))
PY
    echo 'PASS: mutation-capable security review artifact accepted'
    ;;
  *) fail 'profile must be read-only or mutation-capable-lab' ;;
esac
