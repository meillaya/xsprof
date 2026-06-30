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
          [[ "$INPUT_SUPPORTED_TUPLE" =~ ^linux-6\.(1[2-9]|[2-9][0-9])([.][0-9]+)?-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only$ ]]
          test "$INPUT_CONFIRM_VM_ONLY" = "disposable VM-only proof; no host attach"
          test "$INPUT_APPROVAL_ACK" = "manual protected VM proof only; not release approval"
      - run: echo 'audit id rollback id VM marker supported tuple pre state post state rollback proof cleanup proof host refusal matrix manifest matrix rows BPF metadata BPF SKIP JSON daemon events live summary static verification logs benchmark provenance evidence manifest SHA-256 hashes attestation status host_mutation=false release_eligible=false production_capacity_claim=false evidence-manifest.json schemas/control/evidence-manifest.v1.schema.json'
      - run: zig build vm-harness-matrix -- --mode vm-required --out evidence/lab/matrix/manual
      - run: python3 qa/manual_vm_proof_ci_check.py --workflow .github/workflows/manual-vm-proof.yml --docs docs/ci.md docs/runbooks/vm-lab.md docs/releases/governance-gate.md docs/security/review-checklist.md
      - run: python3 qa/evidence_manifest_check.py --manifest evidence/lab/manual-vm-proof/evidence-manifest.json --schema schemas/control/evidence-manifest.v1.schema.json
      - run: |
          tar_inputs=(evidence/lab/manual-vm-proof evidence/lab/matrix/manual schemas/control/evidence-manifest.v1.schema.json)
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


def good_docs() -> str:
    return " ".join((
        "workflow_dispatch manual-vm-proof vm-proof-bundle.tar.zst protected environment required reviewers",
        "self-hosted zig-scheduler-vm-proof disposable-vm release_eligible=false not a release asset not production approval",
        "gh attestation verify ordinary CI stays host-safe audit id rollback id VM marker supported tuple pre state post state",
        "rollback proof cleanup proof host refusal matrix manifest matrix rows BPF metadata BPF SKIP JSON daemon events live summary",
        "static verification logs benchmark provenance evidence manifest SHA-256 hashes attestation status evidence-manifest.json qa/evidence_manifest_check.py",
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
    expect_reject("real-host attach allowance", workflow.replace("static verification logs", "static verification logs bpftool prog load"), docs)
    expect_reject("direct input interpolation in run", workflow.replace('"$INPUT_AUDIT_ID"', '"${{ inputs.audit_id }}"', 1), docs)
    expect_reject("missing input env mapping", workflow.replace("INPUT_AUDIT_ID: ${{ inputs.audit_id }}", "INPUT_AUDIT_ID: AUD-20990101T000000Z-deadbee-abc123"), docs)
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
