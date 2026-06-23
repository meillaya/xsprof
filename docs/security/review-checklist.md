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
