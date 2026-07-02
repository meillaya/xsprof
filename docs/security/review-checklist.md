# Security Review Checklist

Required topics for mutation-capable lab release:

- [ ] Root privileges and Linux capabilities CAP_BPF, CAP_SYS_ADMIN, CAP_PERFMON reviewed.
- [ ] Config injection and shell concatenation risks reviewed.
- [ ] Cgroup escape and stale-scope races reviewed.
- [ ] Audit ledger append-only and tamper/duplicate protections reviewed.
- [ ] BPF verifier assumptions and kernel/API drift reviewed.
- [ ] Log privacy and private command-line sampling reviewed.
- [ ] Packaging defaults and service enablement reviewed.
- [ ] Package install, package upgrade, and package uninstall safety drills reviewed.
- [ ] Cleanup proof reviewed for QEMU, tmux, package temp roots, current-run evidence, and staged package artifacts.
- [ ] Scope fidelity reviewed: no frontend/root UI artifacts and no simulator changes in release/package gates.
- [ ] Privacy review confirms runtime samples omit raw command lines, environments, secrets, and PII.
- [ ] Security signoff includes reviewer identity, date, git SHA, authorized status, and scope.
- [ ] Rollback/fallback and SysRq runbook reviewed.
- [ ] Production-claim wording reviewed.

Unsigned or incomplete mutation-capable review artifacts must fail `qa/security_gate.sh --profile mutation-capable-lab`.

## Reviewer and signoff policy

Current local lab candidate approvals may use an explicit owner override with
`reviewer=owner-override:<owner-id>`. This is a repository-local control, not a
fabricated human approval and not a production approval.

Every mutation-capable security review and release approval must include:

- Reviewer identity.
- Signed attestation kind, signer, signing date, authorized status, scope, and statement.
- Git SHA policy: current approvals must match the current git SHA, or declare a
  `content-bound-ancestor` policy that proves the approval commit is an ancestor
  and every listed tracked source hash still matches. Historical approvals must be
  marked `historical=true` with a historical reason and are not current release
  eligibility by themselves.
- Authorized status of `controlled_lab_pilot_candidate`.
- Scope of `controlled-lab-only`.

Placeholder identities such as `TODO`, `TBD`, `unknown`, or the unqualified
`repository-owner-operator` must fail the security and release gates.

## VM-lab evidence scheduler safety checklist

- [ ] Control schemas are frozen and checked against Zig protocol sources.
- [ ] BPF ABI strategy is frozen before policy expansion.
- [ ] Host refusal artifacts exist for `cgroup.weight`, `cpu.max`, `uclamp`, and `topology.offline_cpu`.
- [ ] VM evidence for every mutation family includes marker, allowlist, audit ID, rollback ID, pre/post state, rollback proof, and cleanup proof.
- [ ] Stale target and duplicate rollback ID refusals are present in daemon events.
- [ ] Performance evidence is record-only and contains no hard threshold or production-capacity claim.
- [ ] Must not claim to be production-ready; frontend, simulator, real-host attach, release approval, and broader status changes must not be introduced and remain out of scope.

## Manual VM proof CI/provenance review

Before enabling or approving the `manual-vm-proof` `workflow_dispatch` lane, reviewers must confirm:

- [ ] The `vm-proof-manual` protected environment has required reviewers and branch/tag restrictions.
- [ ] The runner is isolated and self-hosted with `zig-scheduler-vm-proof` and `disposable-vm` labels; ordinary CI remains host-safe.
- [ ] Dispatch records include audit id, rollback id, VM marker `/run/zig-scheduler-vm-lab.marker`, and supported tuple.
- [ ] `vm-proof-bundle.tar.zst` is retained as a GitHub Actions artifact only; it is not a release asset, not OCI, and not production approval.
- [ ] The bundle contains or accounts for pre state, post state, rollback proof, cleanup proof, host refusal, matrix manifest, matrix rows, BPF metadata, BPF SKIP JSON, daemon events, live summary if present, static verification logs, and benchmark provenance.
- [ ] Every proof keeps `host_mutation=false`, `release_eligible=false`, and `production_capacity_claim=false`.
- [ ] Provenance is checked with `gh attestation verify` and `python3 qa/manual_vm_proof_ci_check.py --workflow .github/workflows/manual-vm-proof.yml --docs docs/ci.md docs/runbooks/vm-lab.md docs/releases/governance-gate.md docs/security/review-checklist.md`.
- [ ] The protected-core suite command uses `--suite protected-core`, not a single `--scenario live-backend`; evidence contains `live-backend`, `workload-cpu-saturation`, `workload-cgroup-weight-quota`, and exactly one latency/churn row with explicit non-PASS reasons when applicable.

A local static checker PASS does not prove that required reviewers approved the GitHub protected environment; approval must be read from the GitHub run/environment record.

- [ ] `evidence-manifest.json` was validated with `qa/evidence_manifest_check.py` and records an explicit outcome, SHA-256 hashes, schema roles, audit id, rollback id, VM marker, supported tuple, BPF metadata or BPF SKIP JSON, daemon events, matrix manifest, benchmark provenance, runner substrate proof, runner cleanliness proof, rollback proof, cleanup proof, host refusal proof, privacy scan, and attestation status.
- [ ] `runner-cleanliness-proof.json` was validated with `qa/runner_cleanliness_proof_check.py` and includes JIT config or clean-machine boot/run identity, no-reuse evidence, runner removal receipt, run URL, and links to `protected-environment-review.json` plus `runner-substrate-proof.json`; GitHub runner labels alone were not accepted as proof.
