#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/manual_vm_proof_ci_selftest.py
"""Self-tests for manual_vm_proof_ci_check.py."""
from __future__ import annotations

from pathlib import Path
import sys
from tempfile import TemporaryDirectory

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from qa.manual_vm_proof_ci_check import Args, ManualVmProofError, validate
else:
    from .manual_vm_proof_ci_check import Args, ManualVmProofError, validate


def expect_reject(label: str, workflow: str, docs: str) -> None:
    with TemporaryDirectory() as temp:
        root = Path(temp)
        workflow_path = root / "manual-vm-proof.yml"
        doc_path = root / "docs.md"
        _ = workflow_path.write_text(workflow)
        _ = doc_path.write_text(docs)
        try:
            validate(Args("check", workflow_path, (doc_path,)))
        except ManualVmProofError as exc:
            print(f"PASS reject {label}: {exc}")
            return
    raise ManualVmProofError(f"expected rejection did not occur: {label}")


def good_workflow() -> str:
    return r"""name: manual-vm-proof
on:
  workflow_dispatch:
    inputs:
      audit_id: {required: true, type: string}
      rollback_id: {required: true, type: string}
      vm_marker_path: {required: true, default: /run/zig-scheduler-vm-lab.marker, type: string}
      supported_tuple: {required: true, type: string}
      confirm_vm_only: {required: true, type: string}
      approval_ack: {required: true, type: string}
permissions:
  contents: read
  id-token: write
  attestations: write
jobs:
  vm-proof:
    environment: vm-proof-manual
    runs-on: [self-hosted, zig-scheduler-vm-proof, disposable-vm]
    env:
      VM_PROOF_BUNDLE: evidence/lab/manual-vm-proof-bundle/vm-proof-bundle.tar.zst
    steps:
      - env:
          INPUT_AUDIT_ID: ${{ inputs.audit_id }}
          INPUT_ROLLBACK_ID: ${{ inputs.rollback_id }}
          INPUT_VM_MARKER_PATH: ${{ inputs.vm_marker_path }}
          INPUT_SUPPORTED_TUPLE: ${{ inputs.supported_tuple }}
          INPUT_CONFIRM_VM_ONLY: ${{ inputs.confirm_vm_only }}
          INPUT_APPROVAL_ACK: ${{ inputs.approval_ack }}
        run: |
          test "$INPUT_VM_MARKER_PATH" = /run/zig-scheduler-vm-lab.marker
          [[ "$INPUT_AUDIT_ID" =~ ^AUD-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{7,12}-[a-f0-9]{6}$ ]]
          [[ "$INPUT_ROLLBACK_ID" =~ ^RB-[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
          [[ "$INPUT_SUPPORTED_TUPLE" =~ ^linux-(6\.(1[2-9]|[2-9][0-9])([.][0-9]+)?|7\.1\.1-2-cachyos)-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only$ ]]
          test "$INPUT_CONFIRM_VM_ONLY" = "disposable VM-only proof; no host attach"
          test "$INPUT_APPROVAL_ACK" = "manual protected VM proof only; not release approval"
      - run: echo 'audit id rollback id VM marker supported tuple pre state post state rollback proof cleanup proof host refusal matrix manifest matrix rows BPF metadata BPF SKIP JSON daemon events live summary static verification logs benchmark provenance evidence manifest SHA-256 hashes attestation status runner substrate proof runner class runner group runner labels protected environment reviewer run URL QEMU path QEMU version /dev/kvm status accel mode kernel tuple unavailable reasons host_mutation=false release_eligible=false production_capacity_claim=false evidence-manifest.json schemas/control/evidence-manifest.v1.schema.json schemas/control/runner-substrate-proof.v1.schema.json qa/runner_substrate_proof_check.py runner-substrate-proof.json protected-environment-review.json kernel BTF metadata unavailable sched_ext kernel substrate unavailable'
      - run: zig build vm-harness-matrix -- --mode vm-required --out evidence/lab/matrix/manual
      - run: python3 qa/manual_vm_proof_ci_check.py --workflow .github/workflows/manual-vm-proof.yml --docs docs/ci.md docs/runbooks/vm-lab.md docs/releases/governance-gate.md docs/security/review-checklist.md
      - run: |
          python3 - <<'PY'
          from pathlib import Path
          import json
          out = Path('evidence/lab/manual-vm-proof/runner-substrate-proof.json')
          reviewer_signal = {'reviewer_status': 'approved'}
          qemu_supports_kvm = True
          qemu_available = True
          qemu_version = 'QEMU emulator version 8.2.0'
          qemu_unavailable_reason = 'qemu-system-x86_64 not found in PATH'
          if qemu_available:
              if qemu_version == '':
                  qemu_unavailable_reason = 'qemu-system-x86_64 version unavailable'
          qemu_usable = qemu_available and qemu_version != ''
          qemu = {'status': 'available' if qemu_usable else 'unavailable'}
          if qemu['status'] == 'unavailable':
              qemu['unavailable_reason'] = qemu_unavailable_reason
          release = '6.12.0-vm-lab'
          expected_release = '6.12.0'
          config_sha256 = 'abcdef'
          btf_available = True
          sched_ext_available = True
          bpf_role = 'bpf-metadata'
          unavailable = []
          if reviewer_signal['reviewer_status'] != 'approved': unavailable.append('reviewer')
          if qemu_version == '': unavailable.append('qemu-version')
          if not qemu_supports_kvm: unavailable.append('qemu')
          if not release.startswith(expected_release): unavailable.append('release')
          if config_sha256 == '' or config_sha256 == '0' * 64: unavailable.append('config')
          if not btf_available: unavailable.append('btf')
          if not sched_ext_available: unavailable.append('sched_ext')
          if bpf_role != 'bpf-metadata': unavailable.append('bpf')
          outcome = 'PASS' if not unavailable else 'SKIP'
          proof = {'qemu': qemu}
          out.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
          PY
          python3 qa/runner_substrate_proof_check.py --proof evidence/lab/manual-vm-proof/runner-substrate-proof.json --schema schemas/control/runner-substrate-proof.v1.schema.json
      - run: echo "manifest_outcome = runner_outcome 'outcome': manifest_outcome 'present': marker_present benchmark_provenance = { 'status': 'not_applicable' 'applies_to_outcomes': ['SKIP', 'REFUSE', 'BLOCKED'] PASS evidence manifest requires benchmark_provenance records runner_substrate_proof outcome is missing or unsupported"
      - run: python3 qa/evidence_manifest_check.py --manifest evidence/lab/manual-vm-proof/evidence-manifest.json --schema schemas/control/evidence-manifest.v1.schema.json
      - run: |
          tar_inputs=(evidence/lab/manual-vm-proof evidence/lab/matrix/manual schemas/control/evidence-manifest.v1.schema.json schemas/control/runner-substrate-proof.v1.schema.json qa/runner_substrate_proof_check.py runner-substrate-proof.json)
          tar --zstd -cf "$VM_PROOF_BUNDLE" "${tar_inputs[@]}"
      - uses: actions/upload-artifact@v4
        with:
          name: vm-proof-bundle
          path: evidence/lab/manual-vm-proof-bundle/vm-proof-bundle.tar.zst
          retention-days: 30
      - uses: actions/attest-build-provenance@v2
        with:
          subject-path: evidence/lab/manual-vm-proof-bundle/vm-proof-bundle.tar.zst
      - run: echo 'gh attestation verify evidence/lab/manual-vm-proof-bundle/vm-proof-bundle.tar.zst --repo $GITHUB_REPOSITORY'
"""


def insert_before_emit(workflow: str, snippet: str) -> str:
    return workflow.replace("out.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\\n')", snippet + "\n          out.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\\n')", 1)


def good_docs() -> str:
    return " ".join((
        "workflow_dispatch manual-vm-proof vm-proof-bundle.tar.zst protected environment required reviewers",
        "self-hosted zig-scheduler-vm-proof disposable-vm release_eligible=false not a release asset not production approval",
        "gh attestation verify ordinary CI stays host-safe audit id rollback id VM marker supported tuple pre state post state",
        "rollback proof cleanup proof host refusal matrix manifest matrix rows BPF metadata BPF SKIP JSON daemon events live summary",
        "static verification logs benchmark provenance evidence manifest SHA-256 hashes attestation status runner substrate proof runner class runner group runner labels protected environment reviewer run URL QEMU path QEMU version /dev/kvm status accel mode kernel tuple unavailable reasons protected-environment-review.json kernel BTF metadata unavailable sched_ext kernel substrate unavailable evidence-manifest.json qa/evidence_manifest_check.py qa/runner_substrate_proof_check.py runner-substrate-proof.json protected-environment-review.json",
    ))


def run_self_test() -> None:
    workflow = good_workflow()
    docs = good_docs()
    with TemporaryDirectory() as temp:
        root = Path(temp)
        workflow_path = root / "manual-vm-proof.yml"
        doc_path = root / "docs.md"
        _ = workflow_path.write_text(workflow)
        _ = doc_path.write_text(docs)
        validate(Args("check", workflow_path, (doc_path,)))
    print("PASS accept protected manual VM proof workflow contract")
    expect_reject("default push trigger", workflow.replace("workflow_dispatch:", "workflow_dispatch:\n  push:"), docs)
    expect_reject("missing protected environment", workflow.replace("environment: vm-proof-manual", ""), docs)
    expect_reject("hosted runner", workflow.replace("[self-hosted, zig-scheduler-vm-proof, disposable-vm]", "ubuntu-latest"), docs)
    expect_reject("missing artifact bundle", workflow.replace("vm-proof-bundle.tar.zst", "vm-proof-bundle.zip"), docs)
    expect_reject("archive output inside archived input", workflow.replace("VM_PROOF_BUNDLE: evidence/lab/manual-vm-proof-bundle/vm-proof-bundle.tar.zst", "VM_PROOF_BUNDLE: evidence/lab/matrix/manual/vm-proof-bundle.tar.zst"), docs)
    expect_reject("release claim", workflow.replace("release_eligible=false", "release_eligible=true"), docs)
    expect_reject("missing attestation", workflow.replace("actions/attest-build-provenance@v2", "actions/upload-artifact@v4"), docs)
    expect_reject("missing evidence manifest", workflow.replace("evidence-manifest.json", "evidence-manifest.txt"), docs)
    expect_reject("evidence manifest omits explicit outcome", workflow.replace("'outcome': manifest_outcome", "'schema': 'zig-scheduler/evidence-manifest/v1'"), docs)
    expect_reject("evidence manifest hardcodes VM marker present", workflow.replace("'present': marker_present", "'present': True"), docs)
    expect_reject("evidence manifest omits benchmark not-applicable status", workflow.replace("'status': 'not_applicable'", "'status': 'missing'"), docs)
    expect_reject("real-host attach allowance", workflow.replace("static verification logs", "static verification logs bpftool prog load"), docs)
    expect_reject("direct input interpolation in run", workflow.replace('"$INPUT_AUDIT_ID"', '"${{ inputs.audit_id }}"', 1), docs)
    expect_reject("direct input interpolation in run shorthand", workflow.replace("      - run: echo 'audit id", "      - run: echo \"${{ inputs.audit_id }}\"\n      - run: echo 'audit id", 1), docs)
    expect_reject("missing input env mapping", workflow.replace("INPUT_AUDIT_ID: ${{ inputs.audit_id }}", "INPUT_AUDIT_ID: AUD-20990101T000000Z-deadbee-abc123"), docs)
    expect_reject("workflow omits reviewer PASS gate", workflow.replace("reviewer_signal['reviewer_status'] != 'approved'", "reviewer_signal.get('reviewer_status')"), docs)
    expect_reject("workflow omits QEMU version PASS gate", workflow.replace("qemu_version == ''", "qemu_version is None"), docs)
    expect_reject("workflow decoy qemu_usable assignment in comment", workflow.replace("qemu_usable = qemu_available and qemu_version != ''", "# qemu_usable = qemu_available and qemu_version != ''\n          qemu_usable = qemu_available", 1), docs)
    expect_reject("workflow decoy QEMU status expression in comment", workflow.replace("qemu = {'status': 'available' if qemu_usable else 'unavailable'}", "# qemu = {'status': 'available' if qemu_usable else 'unavailable'}\n          qemu = {'status': 'available' if qemu_available else 'unavailable'}", 1), docs)
    expect_reject("workflow executable QEMU status decoy", workflow.replace("qemu = {'status': 'available' if qemu_usable else 'unavailable'}", "_qemu_status_decoy = {'status': 'available' if qemu_usable else 'unavailable'}\n          qemu = {'status': 'available' if qemu_available else 'unavailable'}", 1), docs)
    expect_reject("workflow QEMU object reassignment decoy", insert_before_emit(workflow, "proof['qemu'] = {'status': 'available' if qemu_available else 'unavailable'}"), docs)
    expect_reject("workflow QEMU alias status mutation", insert_before_emit(workflow, "qemu['status'] = 'available' if qemu_available else 'unavailable'"), docs)
    expect_reject("workflow QEMU alias update mutation", insert_before_emit(workflow, "qemu.update({'status': 'available' if qemu_available else 'unavailable'})"), docs)
    expect_reject("workflow QEMU alias keyword update mutation", insert_before_emit(workflow, "qemu.update(status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow QEMU alias __setitem__ mutation", insert_before_emit(workflow, "qemu.__setitem__('status', 'available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow QEMU alias union update mutation", insert_before_emit(workflow, "qemu |= {'status': 'available' if qemu_available else 'unavailable'}"), docs)
    expect_reject("workflow QEMU alias subscript augassign mutation", insert_before_emit(workflow, "qemu['status'] += '-mutated'"), docs)
    expect_reject("workflow proof QEMU update mutation", insert_before_emit(workflow, "proof['qemu'].update(status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow proof QEMU __setitem__ mutation", insert_before_emit(workflow, "proof['qemu'].__setitem__('status', 'available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow proof QEMU union update mutation", insert_before_emit(workflow, "proof['qemu'] |= {'status': 'available' if qemu_available else 'unavailable'}"), docs)
    expect_reject("workflow proof get QEMU update mutation", insert_before_emit(workflow, "proof.get('qemu').update(status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow late proof QEMU alias mutation", insert_before_emit(workflow, "late_alias = proof['qemu']\n          late_alias.update(status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow late QEMU alias subscript mutation", insert_before_emit(workflow, "late_alias = qemu\n          late_alias['status'] = 'available' if qemu_available else 'unavailable'"), docs)
    expect_reject("workflow pre-capture QEMU alias mutation", workflow.replace("proof = {'qemu': qemu}", "qemu_alias = qemu\n          proof = {'qemu': qemu}\n          qemu_alias.update(status='available' if qemu_available else 'unavailable')", 1), docs)
    expect_reject("workflow pre-capture QEMU bound mutator", workflow.replace("proof = {'qemu': qemu}", "mutate_qemu = qemu.update\n          proof = {'qemu': qemu}\n          mutate_qemu(status='available' if qemu_available else 'unavailable')", 1), docs)
    expect_reject("workflow pre-capture QEMU closure mutator", workflow.replace("proof = {'qemu': qemu}", "def mutate_qemu():\n              qemu.update(status='available' if qemu_available else 'unavailable')\n          proof = {'qemu': qemu}\n          mutate_qemu()", 1), docs)
    expect_reject("workflow locals QEMU mutation", insert_before_emit(workflow, "locals()['qemu'].update(status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow locals proof QEMU mutation", insert_before_emit(workflow, "locals()['proof']['qemu'].update(status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow proof capture side-effect mutation", workflow.replace("proof = {'qemu': qemu}", "proof = {'qemu': qemu, **(qemu.update(status='available' if qemu_available else 'unavailable') or {})}", 1), docs)
    expect_reject("workflow proof capture nested QEMU clear call", workflow.replace("proof = {'qemu': qemu}", "proof = {'qemu': qemu, 'runner': {'side_effect': qemu.clear()}}", 1), docs)
    expect_reject("workflow proof capture nested QEMU pop call", workflow.replace("proof = {'qemu': qemu}", "proof = {'qemu': qemu, 'runner': {'side_effect': qemu.pop('status', None)}}", 1), docs)
    expect_reject("workflow proof capture nested QEMU setdefault call", workflow.replace("proof = {'qemu': qemu}", "proof = {'qemu': qemu, 'runner': {'side_effect': qemu.setdefault('status', 'available')}}", 1), docs)
    expect_reject("workflow proof capture broad call", workflow.replace("proof = {'qemu': qemu}", "proof = {'qemu': qemu, 'runner': {'unavailable_count': len(unavailable)}}", 1), docs)
    expect_reject("workflow proof capture schema field side effect", workflow.replace("proof = {'qemu': qemu}", "proof = {'qemu': qemu, 'schema': (globals().__setitem__('outcome', 'PASS') or unavailable.clear() or dict.__setitem__(qemu, 'status', 'available') or 'zig-scheduler/runner-substrate-proof/v1')}", 1), docs)
    expect_reject("workflow proof capture named expression", workflow.replace("proof = {'qemu': qemu}", "proof = {'qemu': qemu, 'runner': {'value': (late_status := outcome)}}", 1), docs)
    expect_reject("workflow proof capture comprehension", workflow.replace("proof = {'qemu': qemu}", "proof = {'qemu': qemu, 'runner': {'reasons': [reason for reason in unavailable]}}", 1), docs)
    expect_reject("workflow proof capture nested function decoy", workflow.replace("proof = {'qemu': qemu}", "proof = {'qemu': {'status': 'available' if qemu_available else 'unavailable'}}\n          def decoy_capture():\n              proof = {'qemu': qemu}", 1), docs)
    expect_reject("workflow bound proof QEMU mutator alias", insert_before_emit(workflow, "mutate_qemu = proof['qemu'].update\n          mutate_qemu(status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow getattr proof QEMU mutator", insert_before_emit(workflow, "getattr(proof['qemu'], 'update')(status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow type QEMU unbound mutator", insert_before_emit(workflow, "type(qemu).update(qemu, status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow dict update QEMU mutation", insert_before_emit(workflow, "dict.update(qemu, status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow dict setitem proof QEMU mutation", insert_before_emit(workflow, "dict.__setitem__(proof['qemu'], 'status', 'available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow computed proof QEMU update mutation", insert_before_emit(workflow, "proof['qe' + 'mu'].update(status='available' if qemu_available else 'unavailable')"), docs)
    expect_reject("workflow write argument QEMU update mutation", workflow.replace("out.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\\n')", "out.write_text((qemu.update(status='available' if qemu_available else 'unavailable') or json.dumps(proof, indent=2, sort_keys=True)) + '\\n')", 1), docs)
    expect_reject("workflow write argument proof QEMU update mutation", workflow.replace("out.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\\n')", "out.write_text((proof['qemu'].update(status='available' if qemu_available else 'unavailable') or json.dumps(proof, indent=2, sort_keys=True)) + '\\n')", 1), docs)
    expect_reject("workflow write argument walrus QEMU mutation", workflow.replace("out.write_text(json.dumps(proof, indent=2, sort_keys=True) + '\\n')", "out.write_text(((late_alias := qemu).update(status='available' if qemu_available else 'unavailable') or json.dumps(proof, indent=2, sort_keys=True)) + '\\n')", 1), docs)
    decoy_step = "      - run: |\n          python3 - <<'PY'\n          from pathlib import Path\n          import json\n          qemu_available = True\n          qemu_version = 'QEMU emulator version 8.2.0'\n          qemu_usable = qemu_available and qemu_version != ''\n          proof = {'qemu': {'status': 'available' if qemu_usable else 'unavailable'}}\n          Path('evidence/lab/manual-vm-proof/decoy-runner-substrate-proof.json').write_text(json.dumps(proof, indent=2, sort_keys=True) + '\\n')\n          PY\n"
    bad_canonical = workflow.replace("qemu = {'status': 'available' if qemu_usable else 'unavailable'}", "qemu = {'status': 'available' if qemu_available else 'unavailable'}", 1)
    expect_reject("workflow whole heredoc decoy", bad_canonical.replace("      - run: |\n          python3 - <<'PY'", f"{decoy_step}      - run: |\n          python3 - <<'PY'", 1), docs)
    expect_reject("workflow omits QEMU version unavailable reason", workflow.replace("qemu_unavailable_reason = 'qemu-system-x86_64 version unavailable'", "qemu_unavailable_reason = 'qemu-system-x86_64 not found in PATH'", 1), docs)
    expect_reject("workflow omits QEMU unavailable proof reason", workflow.replace("qemu['unavailable_reason'] = qemu_unavailable_reason", "proof['qemu']['unavailable_reason'] = 'qemu-system-x86_64 not found in PATH'", 1), docs)
    expect_reject("workflow omits BTF PASS gate", workflow.replace("not btf_available", "btf_available is False", 1), docs)
    expect_reject("workflow omits sched_ext PASS gate", workflow.replace("not sched_ext_available", "sched_ext_available is False", 1), docs)
    expect_reject("workflow omits placeholder config gate", workflow.replace("config_sha256 == '' or config_sha256 == '0' * 64", "config_sha256 == ''", 1), docs)
    expect_reject("docs omit reviewer gate", workflow, docs.replace("required reviewers", ""))
    print("PASS manual VM proof CI self-test: unsafe triggers, gates, runners, artifacts, archive self-inclusion, release claims, attach allowance, and docs drift rejected")


def main() -> int:
    try:
        run_self_test()
    except ManualVmProofError as exc:
        print(f"FAIL manual VM proof CI self-test: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
