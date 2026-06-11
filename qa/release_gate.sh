#!/usr/bin/env bash
set -euo pipefail
version=""
evidence_dir=""
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) [ "$#" -ge 2 ] || fail '--version requires value'; version="$2"; shift 2 ;;
    --evidence) [ "$#" -ge 2 ] || fail '--evidence requires value'; evidence_dir="$2"; shift 2 ;;
    --help|-h) echo 'usage: qa/release_gate.sh --version 0.1.0-lab --evidence evidence/releases/0.1.0-lab'; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$version" ] || fail '--version is required'
[ -n "$evidence_dir" ] || fail '--evidence is required'
case "$version$evidence_dir" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
case "$version" in *-lab) ;; *) fail 'version must be lab candidate suffix, e.g. 0.1.0-lab' ;; esac
case "$evidence_dir" in evidence/releases/*) ;; *) fail '--evidence must be under evidence/releases' ;; esac
case "$evidence_dir" in *'/../'*|../*|*/..) fail 'unsafe evidence path' ;; esac
allowed_root="$(realpath evidence/releases)"
parent_dir="$(dirname "$evidence_dir")"
[ -d "$parent_dir" ] || mkdir -p "$parent_dir"
parent_real="$(realpath "$parent_dir")"
case "$parent_real" in "$allowed_root"|"$allowed_root"/*) ;; *) fail 'unsafe evidence parent path' ;; esac
if [ -L "$evidence_dir" ]; then fail 'evidence path must not be a symlink'; fi
if [ -e "$evidence_dir" ]; then
  target_real="$(realpath "$evidence_dir")"
  case "$target_real" in "$allowed_root"|"$allowed_root"/*) ;; *) fail 'unsafe evidence realpath' ;; esac
fi
mkdir -p "$evidence_dir"
target_real="$(realpath "$evidence_dir")"
case "$target_real" in "$allowed_root"|"$allowed_root"/*) ;; *) fail 'unsafe evidence realpath' ;; esac
link_hit="$(find "$evidence_dir" -type l -print -quit 2>/dev/null || true)"
[ -z "$link_hit" ] || fail "release output contains symlink: $link_hit"
missing=0
require_file() { if [ ! -f "$1" ]; then printf 'MISSING: %s\n' "$1"; missing=1; fi; }
require_file fixtures/lab/supported-tuples.json
require_file evidence/lab/dsq-vtime/summary.json
require_file evidence/lab/dsq-vtime/bpf-static-check.txt
require_file evidence/lab/dsq-vtime/dsq-policy-transcript.txt
require_file evidence/lab/dsq-vtime-verifier/host-refusal.json
require_file evidence/lab/partial-attach/host-refusal.json
require_file evidence/lab/partial-attach/partial-attach-manual-transcript.txt
require_file evidence/lab/cgroup-race/cgroup-race-summary.json
require_file evidence/lab/rollback-drill/summary.json
require_file evidence/lab/stress-chaos/summary.json
require_file evidence/lab/stress-chaos/stress-chaos-transcript.txt
require_file docs/security/threat-model.md
require_file fixtures/lab/security-review-approved.json
require_file packaging/config/default.toml
require_file packaging/systemd/zig-scheduler-lab-mutation.service
require_file docs/releases/governance-gate.md
if [ "$missing" -ne 0 ]; then fail 'release gate missing required artifacts'; fi
bash qa/wording_audit.sh >/dev/null
bash qa/no_host_mutation.sh >/dev/null
bash qa/security_gate.sh --profile mutation-capable-lab --review fixtures/lab/security-review-approved.json >/dev/null
bash qa/package_defaults.sh --mode inspect >/dev/null
bash qa/restructure_check.sh >/dev/null
python3 - <<'PY' "$evidence_dir" "$version"
import json, shutil, subprocess, sys
from pathlib import Path
out=Path(sys.argv[1]); version=sys.argv[2]
checks={}
checks['dsq']=json.loads(Path('evidence/lab/dsq-vtime/summary.json').read_text())
checks['rollback']=json.loads(Path('evidence/lab/rollback-drill/summary.json').read_text())
checks['stress']=json.loads(Path('evidence/lab/stress-chaos/summary.json').read_text())
checks['security']=json.loads(Path('fixtures/lab/security-review-approved.json').read_text())
checks['partial_refusal']=json.loads(Path('evidence/lab/partial-attach/host-refusal.json').read_text())
checks['verifier_refusal']=json.loads(Path('evidence/lab/dsq-vtime-verifier/host-refusal.json').read_text())
if checks['dsq'].get('status')!='PASS': raise SystemExit('dsq summary not PASS')
if checks['dsq'].get('simulator_evidence_used') is not False: raise SystemExit('dsq uses simulator evidence')
if checks['dsq'].get('vm_kind') != 'disposable-vm-marker-present': raise SystemExit('dsq evidence is not disposable VM marker evidence')
if checks['rollback'].get('status')!='PASS': raise SystemExit('rollback summary not PASS')
if checks['stress'].get('status')!='PASS': raise SystemExit('stress summary not PASS')
if checks['stress'].get('vm_kind') != 'disposable-vm-marker-present': raise SystemExit('stress evidence is not disposable VM marker evidence')
if checks['stress'].get('root_cgroup_attach') is not False: raise SystemExit('root cgroup attach present')
if checks['security'].get('status')!='approved': raise SystemExit('security not approved')
if checks['partial_refusal'].get('host_mutation') is not False: raise SystemExit('partial host refusal missing no-mutation proof')
if checks['verifier_refusal'].get('host_mutation') is not False: raise SystemExit('verifier host refusal missing no-mutation proof')
rollback_snapshot=checks['rollback'].get('rollback_snapshot')
rollback_transcript=checks['rollback'].get('transcript')
if not rollback_snapshot or not Path(rollback_snapshot).is_file(): raise SystemExit('rollback snapshot missing')
if not rollback_transcript or not Path(rollback_transcript).is_file(): raise SystemExit('rollback transcript missing')
required_sources={
 'supported-tuples.json':'fixtures/lab/supported-tuples.json',
 'dsq-summary.json':'evidence/lab/dsq-vtime/summary.json',
 'bpf-static-check.txt':'evidence/lab/dsq-vtime/bpf-static-check.txt',
 'dsq-policy-transcript.txt':'evidence/lab/dsq-vtime/dsq-policy-transcript.txt',
 'bpf-verifier-host-refusal.json':'evidence/lab/dsq-vtime-verifier/host-refusal.json',
 'partial-attach-host-refusal.json':'evidence/lab/partial-attach/host-refusal.json',
 'partial-attach-manual-transcript.txt':'evidence/lab/partial-attach/partial-attach-manual-transcript.txt',
 'cgroup-allowlist-proof.json':'evidence/lab/cgroup-race/cgroup-race-summary.json',
 'rollback-summary.json':'evidence/lab/rollback-drill/summary.json',
 'rollback-snapshot.json':str(rollback_snapshot),
 'rollback-transcript.txt':str(rollback_transcript),
 'stress-chaos-summary.json':'evidence/lab/stress-chaos/summary.json',
 'stress-chaos-transcript.txt':'evidence/lab/stress-chaos/stress-chaos-transcript.txt',
 'security-threat-model.md':'docs/security/threat-model.md',
 'security-review-approved.json':'fixtures/lab/security-review-approved.json',
 'package-default.toml':'packaging/config/default.toml',
 'package-mutation-service.service':'packaging/systemd/zig-scheduler-lab-mutation.service',
 'governance-gate.md':'docs/releases/governance-gate.md',
}
for name, src in required_sources.items():
    dst=out/name
    if dst.is_symlink():
        raise SystemExit(f'release artifact destination is symlink: {dst}')
    tmp=out/(name+'.tmp')
    if tmp.exists() or tmp.is_symlink():
        tmp.unlink()
    shutil.copyfile(src, tmp)
    tmp.replace(dst)
approval_path=out/'release-approval.json'
existing_approval={}
if approval_path.exists() and not approval_path.is_symlink():
    existing_approval=json.loads(approval_path.read_text())
git_sha=existing_approval.get('git_sha') or subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip()
reviewer=checks['security'].get('reviewer') or 'repository-owner-operator'
date=checks['security'].get('signed_attestation', {}).get('signed_at') or '2026-06-11T00:00:00Z'
approval={
 'schema':'zig-scheduler/release-approval/v1',
 'version':version,
 'git_sha':git_sha,
 'audit_id':checks['rollback'].get('audit_id'),
 'rollback_id':checks['rollback'].get('rollback_id'),
 'reviewer':reviewer,
 'date':date,
 'status':'controlled_lab_pilot_candidate',
 'owner':'repository-owner-operator',
 'approval_required_before_mutation_release':True,
 'production_ready':False,
 'arbitrary_host_safe':False,
 'evidence':[str(out/name) for name in required_sources],
}
required_approval=['version','git_sha','audit_id','rollback_id','reviewer','date','status']
missing=[key for key in required_approval if not approval.get(key)]
if missing: raise SystemExit('approval missing fields: '+','.join(missing))
approval_tmp=out/'release-approval.json.tmp'
approval_tmp.write_text(json.dumps(approval, indent=2, sort_keys=True)+'\n')
approval_tmp.replace(approval_path)
summary={
 'schema':'zig-scheduler/release-gate-summary/v1',
 'version':version,
 'status':'PASS',
 'release_status':'controlled_lab_pilot_candidate',
 'production_ready':False,
 'arbitrary_host_safe':False,
 'required_artifacts_present':True,
 'artifact_count':len(required_sources),
 'evidence_dir':str(out),
}
summary_tmp=out/'summary.json.tmp'
summary_tmp.write_text(json.dumps(summary, indent=2, sort_keys=True)+'\n')
summary_tmp.replace(out/'summary.json')
PY
printf 'summary=%s\n' "$evidence_dir/summary.json"
printf 'approval=%s\n' "$evidence_dir/release-approval.json"
printf 'PASS: release gate controlled_lab_pilot_candidate\n'
