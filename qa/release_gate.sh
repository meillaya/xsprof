#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
version=""
evidence_dir=""
self_test=false
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

validate_governance_manifest() {
  python3 "$repo_root/qa/governance_manifest_check.py" --manifest "$repo_root/fixtures/lab/governance-sources.json" || fail 'missing tracked governance source: governance manifest validation failed'
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --self-test) self_test=true; shift ;;
    --version) [ "$#" -ge 2 ] || fail '--version requires value'; version="$2"; shift 2 ;;
    --evidence) [ "$#" -ge 2 ] || fail '--evidence requires value'; evidence_dir="$2"; shift 2 ;;
    --help|-h) echo 'usage: qa/release_gate.sh --self-test | --version 0.1.0-lab --evidence evidence/releases/0.1.0-lab'; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
if [ "$self_test" = true ]; then
  validate_governance_manifest
  python3 - <<'PY'
from pathlib import Path
current = 'f' * 40

def reject(label, func):
    try:
        func()
    except SystemExit as exc:
        print(f'PASS reject {label}: {exc}')
        return
    raise SystemExit(f'expected rejection did not occur: {label}')

def check_dsq(dsq):
    if dsq.get('status') != 'PASS': raise SystemExit('dsq summary not PASS')
    if dsq.get('rollback_success') is not True: raise SystemExit('dsq rollback_success is not true')
    if dsq.get('starvation_breach') is not False: raise SystemExit('dsq starvation threshold breached')
    if dsq.get('repeated_fallback_or_reject_counters') is not False: raise SystemExit('dsq fallback/reject counters repeated')
    if dsq.get('release_eligible') is not True: raise SystemExit('dsq is not release eligible')
    if dsq.get('vm_kind') != 'disposable-vm-marker-present': raise SystemExit('dsq evidence is not disposable VM evidence')
    if not dsq.get('bpf_metadata_object_sha256'): raise SystemExit('dsq missing BPF metadata sha')
    if dsq.get('verifier_metadata_object_sha256') != dsq.get('bpf_metadata_object_sha256'):
        raise SystemExit('dsq verifier metadata sha mismatch')

def check_stress(stress):
    if stress.get('status') != 'PASS': raise SystemExit('stress summary not PASS')
    if stress.get('release_ready') is True and stress.get('status') != 'PASS': raise SystemExit('skipped stress marked release-ready')

def check_existing_approval(approval):
    if approval.get('git_sha') and approval.get('git_sha') != current and approval.get('historical') is not True:
        raise SystemExit('stale current release approval git_sha')
    reviewer = str(approval.get('reviewer') or '')
    if reviewer.lower() in {'todo', 'tbd', 'placeholder', 'unknown', 'repository-owner-operator'}:
        raise SystemExit('placeholder release reviewer')
    att = approval.get('signed_attestation') or {}
    for key in ['kind', 'signed_by', 'signed_at', 'statement', 'authorized_status', 'scope']:
        if approval and not att.get(key):
            raise SystemExit('missing signed release attestation')
    if approval and att.get('signed_by') != reviewer:
        raise SystemExit('release attestation signer mismatch')
    if approval and att.get('authorized_status') != approval.get('status'):
        raise SystemExit('release attestation status mismatch')
    if approval.get('historical') is True and not approval.get('historical_reason'):
        raise SystemExit('historical approval missing reason')
    manifest = approval.get('artifact_hash_manifest')
    if manifest and not Path(str(manifest)).is_file() and approval.get('historical') is not True:
        raise SystemExit('missing artifact hash manifest')

def check_summary(summary):
    if summary.get('status') == 'PASS' and summary.get('release_status') == 'skipped_no_vm':
        raise SystemExit('summary/status contradiction')

def check_skip_cleanup():
    out = Path('evidence/releases/self-test-skip-cleanup')
    out.mkdir(parents=True, exist_ok=True)
    stale_names = ['release-approval.json', 'artifact-hashes.json']
    for name in stale_names:
        (out / name).write_text('stale release claim\n')
    for name in stale_names:
        stale = out / name
        if stale.exists() or stale.is_symlink():
            stale.unlink()
    if any((out / name).exists() for name in stale_names):
        raise SystemExit('stale skip approval/hash cleanup failed')
    for child in out.iterdir():
        child.unlink()
    out.rmdir()

reject('rollback_success=false', lambda: check_dsq({'status': 'PASS', 'rollback_success': False}))
reject('starvation breach', lambda: check_dsq({'status': 'PASS', 'rollback_success': True, 'starvation_breach': True}))
reject('fallback reject counters', lambda: check_dsq({'status': 'PASS', 'rollback_success': True, 'starvation_breach': False, 'repeated_fallback_or_reject_counters': True}))
reject('host-safe dsq release eligible', lambda: check_dsq({'status': 'PASS', 'rollback_success': True, 'starvation_breach': False, 'repeated_fallback_or_reject_counters': False, 'release_eligible': True, 'vm_kind': 'host-safe-disposable-sysroot', 'bpf_metadata_object_sha256': 'abc', 'verifier_metadata_object_sha256': 'abc'}))
reject('missing verifier metadata', lambda: check_dsq({'status': 'PASS', 'rollback_success': True, 'starvation_breach': False, 'repeated_fallback_or_reject_counters': False, 'release_eligible': True, 'vm_kind': 'disposable-vm-marker-present', 'bpf_metadata_object_sha256': 'abc'}))
reject('stale current approval', lambda: check_existing_approval({'git_sha': '0' * 40, 'historical': False}))
reject('missing hash manifest', lambda: check_existing_approval({'git_sha': current, 'reviewer': 'owner-override:repo', 'status': 'controlled_lab_pilot_candidate', 'artifact_hash_manifest': 'evidence/releases/missing-hashes.json', 'signed_attestation': {'kind': 'owner-override-release-attestation', 'signed_by': 'owner-override:repo', 'signed_at': '2026-06-11T00:00:00Z', 'authorized_status': 'controlled_lab_pilot_candidate', 'scope': 'controlled-lab-only', 'statement': 'current'}}))
reject('placeholder release reviewer', lambda: check_existing_approval({'git_sha': current, 'reviewer': 'TODO', 'status': 'controlled_lab_pilot_candidate'}))
reject('unsigned release approval', lambda: check_existing_approval({'git_sha': current, 'reviewer': 'owner-override:repo', 'status': 'controlled_lab_pilot_candidate'}))
reject('historical missing reason', lambda: check_existing_approval({'git_sha': '0' * 40, 'historical': True, 'reviewer': 'owner-override:repo', 'status': 'controlled_lab_pilot_candidate', 'signed_attestation': {'kind': 'owner-override-release-attestation', 'signed_by': 'owner-override:repo', 'signed_at': '2026-06-11T00:00:00Z', 'authorized_status': 'controlled_lab_pilot_candidate', 'scope': 'controlled-lab-only', 'statement': 'historical'}}))
reject('skipped stress release-ready', lambda: check_stress({'status': 'SKIP', 'release_ready': True}))
reject('summary contradiction', lambda: check_summary({'status': 'PASS', 'release_status': 'skipped_no_vm'}))
check_existing_approval({'git_sha': '0' * 40, 'historical': True, 'historical_reason': 'archived approval only', 'reviewer': 'owner-override:repo', 'status': 'controlled_lab_pilot_candidate', 'signed_attestation': {'kind': 'owner-override-release-attestation', 'signed_by': 'owner-override:repo', 'signed_at': '2026-06-11T00:00:00Z', 'authorized_status': 'controlled_lab_pilot_candidate', 'scope': 'controlled-lab-only', 'statement': 'historical'}})
check_dsq({'status': 'PASS', 'rollback_success': True, 'starvation_breach': False, 'repeated_fallback_or_reject_counters': False, 'release_eligible': True, 'vm_kind': 'disposable-vm-marker-present', 'bpf_metadata_object_sha256': 'abc', 'verifier_metadata_object_sha256': 'abc'})
check_skip_cleanup()
print('PASS release gate self-test: reviewer policy, stale SHA, rollback, DSQ policy, skip cleanup, hash manifest, skipped stress, and contradictions rejected')
PY
  exit 0
fi
[ -n "$version" ] || fail '--version is required'
validate_governance_manifest
[ -n "$evidence_dir" ] || fail '--evidence is required'
case "$version$evidence_dir" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
case "$version" in *-lab|*-lab-*) ;; *) fail 'version must be lab candidate suffix, e.g. 0.1.0-lab' ;; esac
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
zig build bpf --summary all >/dev/null
require_file fixtures/lab/supported-tuples.json
require_file evidence/lab/dsq-vtime/summary.json
require_file evidence/lab/dsq-vtime/bpf-static-check.txt
require_file zig-out/bpf/zigsched_minimal.bpf.meta.json
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
if [ "${ZIG_SCHEDULER_SKIP_NOHOST_GATE:-}" != "1" ]; then
  if ! bash qa/no_host_mutation.sh >/dev/null; then
    rm -rf evidence/lab/run-all/no-host-mutation
    fail 'no host mutation gate failed'
  fi
  rm -rf evidence/lab/run-all/no-host-mutation
fi
bash qa/security_gate.sh --profile mutation-capable-lab --review fixtures/lab/security-review-approved.json >/dev/null
bash qa/package_defaults.sh --mode inspect >/dev/null
bash qa/restructure_check.sh >/dev/null
python3 - <<'PY' "$evidence_dir" "$version"
import hashlib, json, shutil, subprocess, sys
from pathlib import Path
out = Path(sys.argv[1]); version = sys.argv[2]
checks = {}
checks['dsq'] = json.loads(Path('evidence/lab/dsq-vtime/summary.json').read_text())
checks['rollback'] = json.loads(Path('evidence/lab/rollback-drill/summary.json').read_text())
checks['stress'] = json.loads(Path('evidence/lab/stress-chaos/summary.json').read_text())
checks['security'] = json.loads(Path('fixtures/lab/security-review-approved.json').read_text())
checks['partial_refusal'] = json.loads(Path('evidence/lab/partial-attach/host-refusal.json').read_text())
checks['verifier_refusal'] = json.loads(Path('evidence/lab/dsq-vtime-verifier/host-refusal.json').read_text())
checks['bpf_metadata'] = json.loads(Path('zig-out/bpf/zigsched_minimal.bpf.meta.json').read_text())

def write_skip_summary(reason):
    for stale_name in ('release-approval.json', 'artifact-hashes.json'):
        stale_path = out / stale_name
        if stale_path.exists() or stale_path.is_symlink():
            stale_path.unlink()
    summary = {
        'schema': 'zig-scheduler/release-gate-summary/v1',
        'version': version,
        'status': 'SKIP',
        'release_status': 'skipped_no_vm',
        'reason': reason,
        'production_ready': False,
        'arbitrary_host_safe': False,
        'required_artifacts_present': True,
        'artifact_count': 0,
        'artifact_hash_manifest': '',
        'evidence_dir': str(out),
    }
    summary_tmp = out / 'summary.json.tmp'
    summary_tmp.write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    summary_tmp.replace(out / 'summary.json')
    print('SKIP: release gate did not create approval: ' + reason)
    raise SystemExit(0)

if checks['dsq'].get('release_eligible') is False:
    host_safe_skip = (
        checks['dsq'].get('status') == 'PASS'
        and checks['dsq'].get('rollback_success') is True
        and checks['dsq'].get('starvation_breach') is False
        and checks['dsq'].get('repeated_fallback_or_reject_counters') is False
        and checks['dsq'].get('simulator_evidence_used') is False
        and checks['dsq'].get('vm_kind') == 'host-safe-disposable-sysroot'
    )
    if host_safe_skip:
        write_skip_summary('DSQ evidence is marked non-release-eligible')
    raise SystemExit('dsq is non-release-eligible for unexpected reason')
if checks['dsq'].get('status') != 'PASS': raise SystemExit('dsq summary not PASS')
if checks['dsq'].get('rollback_success') is not True: raise SystemExit('dsq rollback_success is not true')
if checks['dsq'].get('starvation_breach') is not False: raise SystemExit('dsq starvation threshold breached')
if checks['dsq'].get('repeated_fallback_or_reject_counters') is not False: raise SystemExit('dsq fallback/reject counters repeated')
if checks['dsq'].get('release_eligible') is not True: raise SystemExit('dsq missing release eligibility proof')
if checks['dsq'].get('simulator_evidence_used') is not False: raise SystemExit('dsq uses simulator evidence')
if checks['dsq'].get('vm_kind') != 'disposable-vm-marker-present': raise SystemExit('dsq evidence is not disposable VM marker evidence')
if checks['rollback'].get('status') != 'PASS': raise SystemExit('rollback summary not PASS')
if checks['stress'].get('status') != 'PASS': raise SystemExit('stress summary not PASS')
if checks['stress'].get('release_ready') is True and checks['stress'].get('status') != 'PASS': raise SystemExit('skipped stress marked release-ready')
if checks['stress'].get('vm_kind') != 'disposable-vm-marker-present': raise SystemExit('stress evidence is not disposable VM marker evidence')
if checks['stress'].get('root_cgroup_attach') is not False: raise SystemExit('root cgroup attach present')
if checks['security'].get('status') != 'approved': raise SystemExit('security not approved')
if checks['partial_refusal'].get('host_mutation') is not False: raise SystemExit('partial host refusal missing no-mutation proof')
if checks['verifier_refusal'].get('host_mutation') is not False: raise SystemExit('verifier host refusal missing no-mutation proof')
if checks['bpf_metadata'].get('status') != 'built': raise SystemExit('BPF metadata is not a built object')
if checks['bpf_metadata'].get('object_sha256') in (None, ''): raise SystemExit('BPF metadata missing object sha')
if checks['bpf_metadata'].get('verification_claimed') is not False: raise SystemExit('BPF metadata must not claim verifier success')
if checks['dsq'].get('bpf_metadata_object_sha256') != checks['bpf_metadata'].get('object_sha256'):
    raise SystemExit('dsq BPF metadata sha mismatch')
if checks['dsq'].get('verifier_metadata_object_sha256') != checks['bpf_metadata'].get('object_sha256'):
    raise SystemExit('dsq verifier metadata sha mismatch')
rollback_snapshot = checks['rollback'].get('rollback_snapshot')
rollback_transcript = checks['rollback'].get('transcript')
if not rollback_snapshot or not Path(rollback_snapshot).is_file(): raise SystemExit('rollback snapshot missing')
if not rollback_transcript or not Path(rollback_transcript).is_file(): raise SystemExit('rollback transcript missing')
required_sources = {
 'supported-tuples.json': 'fixtures/lab/supported-tuples.json',
 'dsq-summary.json': 'evidence/lab/dsq-vtime/summary.json',
 'bpf-static-check.txt': 'evidence/lab/dsq-vtime/bpf-static-check.txt',
 'bpf-object-metadata.json': 'zig-out/bpf/zigsched_minimal.bpf.meta.json',
 'dsq-policy-transcript.txt': 'evidence/lab/dsq-vtime/dsq-policy-transcript.txt',
 'bpf-verifier-host-refusal.json': 'evidence/lab/dsq-vtime-verifier/host-refusal.json',
 'partial-attach-host-refusal.json': 'evidence/lab/partial-attach/host-refusal.json',
 'partial-attach-manual-transcript.txt': 'evidence/lab/partial-attach/partial-attach-manual-transcript.txt',
 'cgroup-allowlist-proof.json': 'evidence/lab/cgroup-race/cgroup-race-summary.json',
 'rollback-summary.json': 'evidence/lab/rollback-drill/summary.json',
 'rollback-snapshot.json': str(rollback_snapshot),
 'rollback-transcript.txt': str(rollback_transcript),
 'stress-chaos-summary.json': 'evidence/lab/stress-chaos/summary.json',
 'stress-chaos-transcript.txt': 'evidence/lab/stress-chaos/stress-chaos-transcript.txt',
 'security-threat-model.md': 'docs/security/threat-model.md',
 'security-review-approved.json': 'fixtures/lab/security-review-approved.json',
 'package-default.toml': 'packaging/config/default.toml',
 'package-mutation-service.service': 'packaging/systemd/zig-scheduler-lab-mutation.service',
 'governance-gate.md': 'docs/releases/governance-gate.md',
}
approval_path = out / 'release-approval.json'
existing_approval = {}
if approval_path.exists() and not approval_path.is_symlink(): existing_approval = json.loads(approval_path.read_text())
current_git_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
existing_summary_path = out / 'summary.json'
if existing_summary_path.exists() and not existing_summary_path.is_symlink():
    existing_summary = json.loads(existing_summary_path.read_text())
    if existing_summary.get('status') == 'PASS' and existing_summary.get('release_status') == 'skipped_no_vm' and existing_summary.get('historical') is not True:
        raise SystemExit('summary/status contradiction')

def check_existing_approval(approval):
    if approval.get('schema') != 'zig-scheduler/release-approval/v1':
        raise SystemExit('bad release approval schema')
    if approval.get('status') != 'controlled_lab_pilot_candidate':
        raise SystemExit('release approval status mismatch')
    if approval.get('production_ready') is not False:
        raise SystemExit('release approval must keep production_ready=false')
    if approval.get('arbitrary_host_safe') is not False:
        raise SystemExit('release approval must keep arbitrary_host_safe=false')
    if approval.get('approval_required_before_mutation_release') is not True:
        raise SystemExit('release approval missing mutation-release gate')
    approval_sha = approval.get('git_sha')
    if approval_sha and approval_sha != current_git_sha and approval.get('historical') is not True:
        git_policy = approval.get('git_sha_policy') or {}
        if git_policy.get('kind') != 'content-bound-ancestor':
            raise SystemExit('stale current release approval git_sha')
        if git_policy.get('approved_git_sha') != approval_sha:
            raise SystemExit('release approval git_sha_policy approved sha mismatch')
        ancestor = subprocess.run(
            ['git', 'merge-base', '--is-ancestor', str(approval_sha), current_git_sha],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if ancestor.returncode != 0:
            raise SystemExit('release approval git_sha is not an ancestor')
    reviewer_value = approval.get('reviewer')
    reviewer = str(reviewer_value or '')
    if reviewer.lower() in {'todo', 'tbd', 'placeholder', 'unknown', 'repository-owner-operator'}:
        raise SystemExit('placeholder release reviewer')
    att = approval.get('signed_attestation') or {}
    for key in ['kind', 'signed_by', 'signed_at', 'statement', 'authorized_status', 'scope']:
        if approval and not att.get(key):
            raise SystemExit('missing signed release attestation')
    if approval and att.get('signed_by') != reviewer:
        raise SystemExit('release attestation signer mismatch')
    if approval and att.get('authorized_status') != approval.get('status'):
        raise SystemExit('release attestation status mismatch')
    if approval and att.get('scope') != 'controlled-lab-only':
        raise SystemExit('release attestation scope mismatch')
    if approval.get('historical') is True and not approval.get('historical_reason'):
        raise SystemExit('historical approval missing reason')
    manifest = approval.get('artifact_hash_manifest')
    if manifest and not Path(str(manifest)).is_file() and approval.get('historical') is not True:
        raise SystemExit('missing artifact hash manifest')

def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

expected_artifact_hashes = {
    name: {'path': str(out / name), 'sha256': sha256_file(src)}
    for name, src in required_sources.items()
}
expected_hash_manifest = {
    'schema': 'zig-scheduler/release-artifact-hashes/v1',
    'artifacts': expected_artifact_hashes,
}

def existing_hashes_match_expected(approval):
    manifest = approval.get('artifact_hash_manifest')
    if not manifest or not Path(str(manifest)).is_file():
        return False
    try:
        observed = json.loads(Path(str(manifest)).read_text())
    except json.JSONDecodeError:
        return False
    return observed == expected_hash_manifest

def is_ancestor_of_head(revision):
    if not revision:
        return False
    result = subprocess.run(
        ['git', 'merge-base', '--is-ancestor', str(revision), current_git_sha],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0

preserve_existing_approval = False
if existing_approval:
    existing_git_sha = existing_approval.get('git_sha')
    existing_policy = existing_approval.get('git_sha_policy') or {}
    existing_has_content_policy = (
        existing_policy.get('kind') == 'content-bound-ancestor'
        and existing_policy.get('approved_git_sha') == existing_git_sha
    )
    if existing_approval.get('historical') is True:
        check_existing_approval(existing_approval)
    elif existing_git_sha == current_git_sha:
        check_existing_approval(existing_approval)
        preserve_existing_approval = existing_has_content_policy and existing_hashes_match_expected(existing_approval)
    elif is_ancestor_of_head(existing_git_sha) and existing_hashes_match_expected(existing_approval):
        if existing_has_content_policy:
            check_existing_approval(existing_approval)
            preserve_existing_approval = True
        else:
            preserve_existing_approval = False
    else:
        raise SystemExit('stale current release approval git_sha')

for name, src in required_sources.items():
    dst = out / name
    if dst.is_symlink(): raise SystemExit(f'release artifact destination is symlink: {dst}')
    tmp = out / (name + '.tmp')
    if tmp.exists() or tmp.is_symlink(): tmp.unlink()
    shutil.copyfile(src, tmp)
    tmp.replace(dst)
artifact_hashes = {}
for name in required_sources:
    digest = hashlib.sha256((out / name).read_bytes()).hexdigest()
    artifact_hashes[name] = {'path': str(out / name), 'sha256': digest}
hash_manifest = out / 'artifact-hashes.json'
hash_tmp = out / 'artifact-hashes.json.tmp'
hash_tmp.write_text(json.dumps({'schema': 'zig-scheduler/release-artifact-hashes/v1', 'artifacts': artifact_hashes}, indent=2, sort_keys=True) + '\n')
hash_tmp.replace(hash_manifest)
if artifact_hashes != expected_artifact_hashes:
    raise SystemExit('internal artifact hash mismatch')
reviewer = checks['security'].get('reviewer')
date = checks['security'].get('signed_attestation', {}).get('signed_at') or '2026-06-11T00:00:00Z'
security_attestation = checks['security'].get('signed_attestation', {})
approval = {
 'schema': 'zig-scheduler/release-approval/v1',
 'version': version,
 'git_sha': current_git_sha,
 'git_sha_policy': {
   'kind': 'content-bound-ancestor',
   'approved_git_sha': current_git_sha,
   'artifact_hash_manifest': str(hash_manifest),
   'statement': 'Approval remains usable on descendant commits only when the git SHA is an ancestor and this release artifact hash manifest still matches exactly.',
 },
 'audit_id': checks['rollback'].get('audit_id'),
 'rollback_id': checks['rollback'].get('rollback_id'),
 'reviewer': reviewer,
 'date': date,
 'status': 'controlled_lab_pilot_candidate',
 'owner': 'repository-owner-operator',
 'approval_required_before_mutation_release': True,
 'production_ready': False,
 'arbitrary_host_safe': False,
 'historical': False,
 'artifact_hash_manifest': str(hash_manifest),
 'signed_attestation': {
   'kind': 'owner-override-release-attestation',
   'signed_by': reviewer,
   'signed_at': date,
   'authorized_status': 'controlled_lab_pilot_candidate',
   'scope': checks['security'].get('scope') or security_attestation.get('scope') or 'controlled-lab-only',
   'statement': 'Controlled lab candidate approval only; no production or arbitrary-host approval is granted.',
 },
 'evidence': [str(out / name) for name in required_sources] + [str(hash_manifest)],
}
required_approval = ['version', 'git_sha', 'audit_id', 'rollback_id', 'reviewer', 'date', 'status', 'artifact_hash_manifest']
missing = [key for key in required_approval if not approval.get(key)]
if missing: raise SystemExit('approval missing fields: ' + ','.join(missing))
check_existing_approval(approval)
if not preserve_existing_approval:
    approval_tmp = out / 'release-approval.json.tmp'
    approval_tmp.write_text(json.dumps(approval, indent=2, sort_keys=True) + '\n')
    approval_tmp.replace(approval_path)
summary = {
 'schema': 'zig-scheduler/release-gate-summary/v1',
 'version': version,
 'status': 'PASS',
 'release_status': 'controlled_lab_pilot_candidate',
 'production_ready': False,
 'arbitrary_host_safe': False,
 'required_artifacts_present': True,
 'artifact_count': len(required_sources),
 'artifact_hash_manifest': str(hash_manifest),
 'evidence_dir': str(out),
}
if summary.get('status') == 'PASS' and summary.get('release_status') == 'skipped_no_vm': raise SystemExit('summary/status contradiction')
summary_tmp = out / 'summary.json.tmp'
summary_tmp.write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
summary_tmp.replace(out / 'summary.json')
PY
release_summary_status="$(python3 - "$evidence_dir/summary.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
print(json.loads(path.read_text()).get('status', 'missing') if path.is_file() else 'missing')
PY
)"
if [ "$release_summary_status" = "SKIP" ]; then
  printf 'summary=%s\n' "$evidence_dir/summary.json"
  printf 'SKIP: release gate skipped approval for non-release-eligible evidence\n'
  exit 0
fi
printf 'summary=%s\n' "$evidence_dir/summary.json"
printf 'approval=%s\n' "$evidence_dir/release-approval.json"
printf 'hashes=%s\n' "$evidence_dir/artifact-hashes.json"
printf 'PASS: release gate controlled_lab_pilot_candidate\n'
