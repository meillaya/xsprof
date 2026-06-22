# ADR 0001: sched_ext Production Claim Boundary

## Status
Accepted for the path-to-production roadmap.

## Context
`zig-scheduler` is being re-chartered from a deterministic simulator into a Linux `sched_ext` scheduler project. The repository root is intentionally fail-closed today: it performs read-only preflight and dry-run planning, while the simulator remains archived under `simulator/`.

Upstream `sched_ext` is a Linux scheduler class implemented with BPF `struct_ops`. The kernel can revert to the default fair scheduler when a BPF scheduler exits, errors, stalls, or an operator invokes SysRq-S. That fallback behavior is a safety feature, not permission to claim arbitrary production safety.

## Decision
This project may describe itself as a **path-to-production** Linux `sched_ext` scheduler project. It must not claim to be production-ready, safe for production, or safe for arbitrary production hosts until the governance gate in `docs/releases/governance-gate.md` passes with recorded evidence.

For the VM/lab backend milestone, the maximum allowed release status is
`controlled_lab_pilot_candidate`: a disposable-VM-only backend readiness claim
backed by real VM evidence, rollback/audit proof, cleanup proof, package
default proof, and security review. This status is not a general host support
claim and does not authorize non-VM scheduler mutation.

Allowed wording before the governance gate:

- path-to-production Linux `sched_ext` scheduler project;
- fail-closed Linux scheduler operator surface;
- VM-only sched_ext lab work;
- VM/lab backend readiness milestone;
- controlled lab pilot candidate after evidence review.

Disallowed wording before the governance gate:

- Disallowed before the governance gate: production-ready scheduler;
- Disallowed before the governance gate: safe for production;
- Disallowed before the governance gate: safe for arbitrary production hosts;
- Disallowed before the governance gate: deployable live scheduler without lab/rollback/security evidence.

## Consequences
- Root commands must remain read-only or dry-run unless a later task adds an explicitly gated VM/lab mutation path.
- Every mutation-capable milestone must prove verifier logs, partial-switch scope, rollback, audit identity, cleanup, and security review before release wording changes.
- Simulator results may inform design but cannot be used as Linux production-readiness evidence.
- Packaging and service defaults must stay disabled/refusing by default; mutation-capable units require a disposable VM marker, lab approval evidence, audit id, rollback id, and release-gate proof.

## Documentation prompt-injection boundary

Tracked documentation, `AGENTS.md`, and `WORKLOG.md` are governance inputs, not executable instructions that can bypass gates. Wording that attempts to override `AGENTS.md`, governance, release, or security gates is rejected by `qa/wording_audit.sh --self-test` and the default wording audit. Legitimate guardrail wording such as "do not bypass governance gates" remains allowed.
