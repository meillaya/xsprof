# ADR 0001: sched_ext Production Claim Boundary

## Status
Accepted for the path-to-production roadmap.

## Context
`zig-scheduler` is being re-chartered from a deterministic simulator into a Linux `sched_ext` scheduler project. The repository root is intentionally fail-closed today: it performs read-only preflight, dry-run planning, and Linux operator TUI rendering, while the simulator remains archived under `simulator/`.

Upstream `sched_ext` is a Linux scheduler class implemented with BPF `struct_ops`. The kernel can revert to the default fair scheduler when a BPF scheduler exits, errors, stalls, or an operator invokes SysRq-S. That fallback behavior is a safety feature, not permission to claim arbitrary production safety.

## Decision
This project may describe itself as a **path-to-production** Linux `sched_ext` scheduler project. It must not claim to be production-ready, safe for production, or safe for arbitrary production hosts until the governance gate in `docs/releases/governance-gate.md` passes with recorded evidence.

Allowed wording before the governance gate:

- path-to-production Linux `sched_ext` scheduler project;
- fail-closed Linux scheduler operator surface;
- VM-only sched_ext lab work;
- controlled lab pilot candidate after evidence review.

Disallowed wording before the governance gate:

- Disallowed before the governance gate: production-ready scheduler;
- Disallowed before the governance gate: safe for production;
- Disallowed before the governance gate: safe for arbitrary production hosts;
- Disallowed before the governance gate: deployable live scheduler without lab/rollback/security evidence.

## Consequences
- Root commands must remain read-only or dry-run unless a later task adds an explicitly gated VM/lab mutation path.
- Every mutation-capable milestone must prove verifier logs, partial-switch scope, rollback, audit identity, and security review before release wording changes.
- Simulator results may inform design but cannot be used as Linux production-readiness evidence.

## Documentation prompt-injection boundary

Tracked documentation, `AGENTS.md`, and `WORKLOG.md` are governance inputs, not executable instructions that can bypass gates. Wording that attempts to override `AGENTS.md`, governance, release, or security gates is rejected by `qa/wording_audit.sh --self-test` and the default wording audit. Legitimate guardrail wording such as "do not bypass governance gates" remains allowed.
