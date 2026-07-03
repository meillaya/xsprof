#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/manual_vm_proof_ci_check.py --self-test
# python3 qa/manual_vm_proof_ci_check.py --workflow .github/workflows/manual-vm-proof.yml --docs docs/ci.md docs/runbooks/vm-lab.md docs/releases/governance-gate.md docs/security/review-checklist.md
"""Statically validate the protected manual VM proof CI/provenance lane."""
from __future__ import annotations

import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Literal

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from qa.manual_vm_proof_flow import ManualVmProofFlowError, validate_qemu_proof_semantics
else:
    from .manual_vm_proof_flow import ManualVmProofFlowError, validate_qemu_proof_semantics

WORKFLOW_PATH: Final = Path(".github/workflows/manual-vm-proof.yml")
DEFAULT_DOCS: Final[tuple[Path, ...]] = (
    Path("docs/ci.md"),
    Path("docs/runbooks/vm-lab.md"),
    Path("docs/releases/governance-gate.md"),
    Path("docs/security/review-checklist.md"),
)
REQUIRED_ARTIFACTS: Final[tuple[str, ...]] = tuple("""matrix manifest|matrix rows|bpf metadata|bpf skip json|daemon events|live summary|static verification logs|audit id|rollback id|vm marker|supported tuple|pre state|post state|rollback proof|cleanup proof|host refusal|benchmark provenance|evidence manifest|SHA-256 hashes|attestation status|runner substrate proof|runner cleanliness proof|JIT config|clean-machine boot|no-reuse evidence|removal receipt|runner class|runner group|runner labels|protected environment reviewer|run URL|QEMU path|QEMU version|/dev/kvm status|accel mode|kernel tuple|unavailable reasons|protected-environment-review.json|kernel BTF metadata unavailable|sched_ext kernel substrate unavailable|protected-core suite|protected-core telemetry|workload-cpu-saturation|workload-cgroup-weight-quota|exactly one latency/churn row""".split("|"))
REQUIRED_DOC_TERMS: Final[tuple[str, ...]] = tuple("""workflow_dispatch|manual-vm-proof|vm-proof-bundle.tar.zst|protected environment|required reviewers|self-hosted|zig-scheduler-vm-proof|disposable-vm|release_eligible=false|not a release asset|not production approval|gh attestation verify|evidence-manifest.json|qa/evidence_manifest_check.py|qa/protected_core_suite_check.py|qa/protected_core_telemetry_check.py|qa/runner_substrate_proof_check.py|qa/runner_cleanliness_proof_check.py|runner-substrate-proof.json|runner-cleanliness-proof.json""".split("|"))
FORBIDDEN_TRIGGER_RE: Final = re.compile(r"^\s*(push|pull_request|pull_request_target|schedule):", re.MULTILINE)
FORBIDDEN_RELEASE_RE: Final = re.compile(
    r"(\bgh\s+release\b|actions/create-release|softprops/action-gh-release|upload-release-asset|release_eligible\s*[:=]\s*true|\bproduction[_ -]?ready\b|\bpublish release\b)",
    re.IGNORECASE,
)
HOSTED_RUNNER_RE: Final = re.compile(r"\b(ubuntu|macos|windows)-latest\b")
DIRECT_INPUT_IN_RUN_RE: Final = re.compile(r"\$\{\{\s*inputs\.")


@dataclass(frozen=True, slots=True)
class Args:
    mode: Literal["check", "self-test"]
    workflow: Path
    docs: tuple[Path, ...]


class ManualVmProofError(Exception):
    """Raised when manual VM proof workflow or docs violate the static contract."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args("self-test", WORKFLOW_PATH, DEFAULT_DOCS)
    workflow = WORKFLOW_PATH
    docs = DEFAULT_DOCS
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--workflow":
            index += 1
            if index >= len(argv):
                raise ManualVmProofError("--workflow requires a path")
            workflow = Path(argv[index])
        elif arg == "--docs":
            values: list[Path] = []
            index += 1
            while index < len(argv) and not argv[index].startswith("--"):
                values.append(Path(argv[index]))
                index += 1
            if not values:
                raise ManualVmProofError("--docs requires at least one path")
            docs = tuple(values)
            index -= 1
        else:
            raise ManualVmProofError("usage: manual_vm_proof_ci_check.py --self-test | [--workflow <path>] [--docs <paths...>]")
        index += 1
    return Args("check", workflow, docs)


def read(path: Path) -> str:
    try:
        return path.read_text()
    except FileNotFoundError as exc:
        raise ManualVmProofError(f"missing required file: {path}") from exc


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ManualVmProofError(message)


def contains(text: str, needle: str) -> bool:
    return needle.lower() in text.lower()


def shell_run_blocks(text: str) -> tuple[str, ...]:
    blocks: list[str] = []
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        match = re.match(r"^(?P<indent>\s*)(?:-\s*)?run:\s*(?P<body>.*)$", lines[index])
        if match is None:
            index += 1
            continue
        body = match.group("body").strip()
        if not (body.startswith("|") or body.startswith(">")):
            blocks.append(body)
            index += 1
            continue
        base_indent = len(match.group("indent"))
        block_lines: list[str] = []
        index += 1
        while index < len(lines) and (not lines[index].strip() or len(lines[index]) - len(lines[index].lstrip(" ")) > base_indent):
            block_lines.append(lines[index])
            index += 1
        blocks.append("\n".join(block_lines))
    return tuple(blocks)


def validate_workflow(path: Path) -> None:
    text = read(path)
    lowered = text.lower()
    require("workflow_dispatch:" in text, "workflow must be manual workflow_dispatch only")
    require(FORBIDDEN_TRIGGER_RE.search(text) is None, "workflow must not run on push, pull_request, pull_request_target, or schedule")
    require("environment:" in lowered and "vm-proof-manual" in lowered, "workflow must declare protected vm-proof-manual environment")
    for label in ("self-hosted", "zig-scheduler-vm-proof", "disposable-vm"):
        require(contains(text, label), f"workflow missing restricted runner label: {label}")
    require(HOSTED_RUNNER_RE.search(text) is None, "workflow must not use hosted default runners")
    for permission in ("contents: read", "id-token: write", "attestations: write"):
        require(contains(text, permission), f"workflow missing permission: {permission}")
    for required_input in ("audit_id", "rollback_id", "vm_marker_path", "supported_tuple", "confirm_vm_only", "approval_ack"):
        require(contains(text, required_input), f"workflow missing dispatch input: {required_input}")
    run_blocks = shell_run_blocks(text)
    for block in run_blocks:
        require(DIRECT_INPUT_IN_RUN_RE.search(block) is None, "workflow run blocks must not interpolate workflow_dispatch inputs directly; pass inputs through step env and quote shell variables")
    try:
        validate_qemu_proof_semantics(text)
    except ManualVmProofFlowError as exc:
        raise ManualVmProofError(str(exc)) from exc
    for env_mapping in tuple("""INPUT_AUDIT_ID: ${{ inputs.audit_id }}|INPUT_ROLLBACK_ID: ${{ inputs.rollback_id }}|INPUT_VM_MARKER_PATH: ${{ inputs.vm_marker_path }}|INPUT_SUPPORTED_TUPLE: ${{ inputs.supported_tuple }}|INPUT_CONFIRM_VM_ONLY: ${{ inputs.confirm_vm_only }}|INPUT_APPROVAL_ACK: ${{ inputs.approval_ack }}""".split("|")):
        require(contains(text, env_mapping), f"workflow missing safe step env input mapping: {env_mapping}")
    for validation in tuple("""test "$INPUT_VM_MARKER_PATH" = /run/zig-scheduler-vm-lab.marker|[[ "$INPUT_AUDIT_ID" =~ ^AUD-|[[ "$INPUT_ROLLBACK_ID" =~ ^RB-|[[ "$INPUT_SUPPORTED_TUPLE" =~ ^linux-|test "$INPUT_CONFIRM_VM_ONLY" = "disposable VM-only proof; no host attach"|test "$INPUT_APPROVAL_ACK" = "manual protected VM proof only; not release approval""".split("|")):
        require(contains(text, validation), f"workflow missing strict quoted input validation: {validation}")
    require("/run/zig-scheduler-vm-lab.marker" in text, "workflow must pin VM marker path")
    require("vm-proof-bundle.tar.zst" in text, "workflow must upload vm-proof-bundle.tar.zst")
    require("actions/upload-artifact" in text, "workflow must upload the proof bundle as a workflow artifact")
    require("retention-days:" in text, "workflow artifact retention must be explicit")
    require("actions/attest-build-provenance" in text, "workflow must be attestation-aware")
    require("gh attestation verify" in text, "workflow must include attestation verification command placeholder")
    require("evidence-manifest.json" in text, "workflow must produce evidence-manifest.json")
    require("qa/evidence_manifest_check.py" in text, "workflow must validate the evidence manifest")
    require("schemas/control/evidence-manifest.v1.schema.json" in text, "workflow must include the evidence manifest schema")
    require("schemas/control/runner-substrate-proof.v1.schema.json" in text, "workflow must include the runner substrate proof schema")
    require("schemas/control/runner-cleanliness-proof.v1.schema.json" in text, "workflow must include the runner cleanliness proof schema")
    require("qa/runner_substrate_proof_check.py" in text, "workflow must validate runner substrate proof")
    require("qa/runner_cleanliness_proof_check.py" in text, "workflow must validate runner cleanliness proof")
    require("runner-substrate-proof.json" in text, "workflow must produce runner-substrate-proof.json")
    require("runner-cleanliness-proof.json" in text, "workflow must produce runner-cleanliness-proof.json")

    for manifest_gate in (
        "manifest_outcome = runner_outcome",
        "'outcome': manifest_outcome",
        "'present': marker_present",
        "benchmark_provenance = {",
        "'status': 'not_applicable'",
        "'applies_to_outcomes': ['SKIP', 'REFUSE', 'BLOCKED']",
        "PASS evidence manifest requires benchmark_provenance records",
        "runner_substrate_proof outcome is missing or unsupported",
        "runner_cleanliness_proof outcome is missing or unsupported",
        "non-PASS protected-core row must include an explicit reason",
    ):
        require(contains(text, manifest_gate), f"workflow missing outcome-aware evidence manifest gate: {manifest_gate}")
    for cleanliness_gate in tuple("""runner labels are not cleanliness proof|ZIGSCHED_NO_REUSE_EVIDENCE|ZIGSCHED_RUNNER_REMOVAL_RECEIPT|ZIGSCHED_EPHEMERAL_REGISTRATION_RECEIPT|ephemeral_id = os.environ.get('ZIGSCHED_EPHEMERAL_INSTANCE_ID', '')|no_reuse_status = 'PASS'|removal_receipt = {'status': 'unavailable'}|removal_receipt = {'status': 'not_applicable'}|ephemeral_registration is not None|cleanup_accounted = removal_receipt['status'] == 'removed' or (cleanliness_mode['kind'] == 'ephemeral' and removal_receipt['status'] == 'not_applicable' and ephemeral_registration is not None)|outcome = 'PASS' if no_reuse_status == 'PASS' and cleanup_accounted else 'SKIP'""".split("|")):
        require(contains(text, cleanliness_gate), f"workflow missing runner cleanliness gate: {cleanliness_gate}")
    require("first_existing_env('ZIGSCHED_EPHEMERAL_INSTANCE_ID', 'RUNNER_TRACKING_ID')" not in text, "workflow must not treat RUNNER_TRACKING_ID alone as ephemeral cleanup proof")
    require("local_receipt.write_bytes(receipt_path.read_bytes())" not in text, "workflow must normalize receipt artifacts instead of copying arbitrary runner-local files")
    for proof_gate in tuple("""protected-environment-review.json|reviewer_signal['reviewer_status'] != 'approved'|qemu_supports_kvm|qemu_version == ''|qemu_unavailable_reason = 'qemu-system-x86_64 version unavailable'|qemu['unavailable_reason'] = qemu_unavailable_reason|not release.startswith(expected_release)|config_sha256 == '' or config_sha256 == '0' * 64|not btf_available|not sched_ext_available|bpf_role != 'bpf-metadata'|outcome = 'PASS' if not unavailable else 'SKIP'""".split("|")):
        require(contains(text, proof_gate), f"workflow missing PASS substrate gate: {proof_gate}")
    require("release_eligible=false" in text, "workflow must keep release_eligible=false")
    require("production_capacity_claim=false" in text, "workflow must keep production_capacity_claim=false")
    require("host_mutation=false" in text, "workflow must require host_mutation=false evidence")
    require("zig build vm-harness-matrix" in text, "workflow must run the VM matrix proof surface")
    require("--suite protected-core" in text, "workflow must run the protected-core suite")
    require("--scenario live-backend" not in text, "workflow must not use the old single live-backend scenario invocation")
    for protected_row in ("live-backend", "workload-cpu-saturation", "workload-cgroup-weight-quota"):
        require(contains(text, protected_row), f"workflow missing protected-core PASS row requirement: {protected_row}")
    require("workload-interactive-latency" in text and "workload-scheduler-affinity-churn" in text, "workflow must account for exactly one latency/churn row")
    require("protected_core_pass" in text, "workflow must gate PASS on protected-core row outcomes")
    require("protected_core_pass_candidate" in text, "workflow must classify protected-core PASS candidate before PASS-only validators")
    require("if [ \"$protected_core_pass_candidate\" = \"1\" ]; then" in text, "workflow must run protected-core validators only for PASS candidate derivation")
    require("SKIP protected-core PASS validators" in text, "workflow must preserve packageable non-PASS bundles instead of failing PASS-only validators")
    require("BLOCKED" in text, "workflow must preserve BLOCKED as an explicit packageable non-PASS outcome")
    require("exactly one latency/churn row" in text, "workflow must explicitly require exactly one latency/churn row")
    require("manual_vm_proof_ci_check.py" in text, "workflow must self-validate its static safety contract")
    for protected_check in (
        "python3 qa/protected_core_suite_check.py",
        "python3 qa/protected_core_telemetry_check.py",
        "--manifest evidence/lab/matrix/manual-vm-proof/manifest.json",
        "protected-core-suite.log",
        "protected-core-telemetry.log",
        "protected_core_pass_candidate=1",
        "protected_core_pass_candidate=0",
        "protected-core-non-pass-reasons.txt",
        "non_pass_reason:",
    ):
        require(contains(text, protected_check), f"workflow must gate protected-core PASS derivation while packaging non-PASS bundles: {protected_check}")
    require("release" not in lowered or FORBIDDEN_RELEASE_RE.search(text) is None, "workflow contains forbidden release or production claim")
    for artifact in REQUIRED_ARTIFACTS:
        require(contains(text, artifact), f"workflow missing proof artifact/provenance requirement: {artifact}")
    for unsafe in ("/sys/kernel/sched_ext", "bpftool prog load", "scx_loader", "sched_ext attach"):
        require(not contains(text, unsafe), f"workflow text must not allow real-host attach primitive: {unsafe}")



def validate_archive_output_location(text: str) -> None:
    bundle = re.search(r"(?m)^\s*VM_PROOF_BUNDLE:\s*(\S+)\s*$", text)
    inputs = re.search(r"tar_inputs=\(([^)]*)\)", text)
    if bundle is None:
        raise ManualVmProofError("workflow must define VM_PROOF_BUNDLE")
    if inputs is None:
        raise ManualVmProofError("workflow must define explicit tar_inputs")
    output = Path(bundle.group(1))
    for item in shlex.split(inputs.group(1)):
        candidate = Path(item)
        if candidate.suffix:
            continue
        require(output != candidate and candidate not in output.parents, f"VM_PROOF_BUNDLE must not be inside archived input: {candidate}")

def validate_docs(paths: tuple[Path, ...]) -> None:
    texts = [read(path) for path in paths]
    joined = "\n".join(texts)
    for term in REQUIRED_DOC_TERMS:
        require(contains(joined, term), f"docs missing required manual VM proof term: {term}")
    for artifact in REQUIRED_ARTIFACTS:
        require(contains(joined, artifact), f"docs missing proof artifact/provenance term: {artifact}")
    require("manual vm proof is release eligible" not in joined.lower(), "docs must not mark manual VM proof release eligible")
    require("manual vm proof is production approval" not in joined.lower(), "docs must not call manual VM proof production approval")
    require("ordinary push" in joined.lower() or "ordinary ci" in joined.lower(), "docs must say ordinary/default CI stays host-safe")


def validate(args: Args) -> None:
    text = read(args.workflow)
    validate_workflow(args.workflow)
    validate_archive_output_location(text)
    validate_docs(args.docs)


def run_self_test() -> None:
    result = subprocess.run([sys.executable, "qa/manual_vm_proof_ci_selftest.py"], check=False)
    if result.returncode != 0:
        raise ManualVmProofError("manual VM proof CI self-test assertions failed")

def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        if args.mode == "self-test":
            run_self_test()
        else:
            validate(args)
            print("PASS manual VM proof workflow/docs contract")
        return 0
    except ManualVmProofError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
