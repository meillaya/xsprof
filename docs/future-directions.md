# Future Directions: Reopening and Completing M26

## Status
As of April 23, 2026, M26 remains **deferred indefinitely** under `docs/adr/0003-m25-productionization-gate.md`.

This document does not reopen M26. It is a plain-English planning guide for a future return if there is a serious reason to revisit the optional production branch.

## Purpose of this document
This file explains the most disciplined path back to M26. It is intentionally explanatory rather than authoritative.

Canonical project governance remains in:
- `docs/adr/0003-m25-productionization-gate.md`
- `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md`
- `docs/roadmap/test-spec-multi-horizon-zig-scheduler-roadmap.md`
- `README.md`
- `docs/project-architecture-and-status.md`
- `docs/linux-mapping.md`
- `docs/roadmap/open-questions.md`
- `src/tests/identity_gate_test.zig`

## Current position
The repository is still **simulator-first**.

M26 exists only as an optional future branch for a scheduler-driven automation prototype. Its presence in the roadmap is not approval to begin implementation. The project may return to M26 only if a future decision explicitly reopens it.

## Recommended return strategy
If this project is revisited later, the safest path is a two-gate approach:

1. **Gate A: decide whether M26 should be reopened at all.**
2. **Gate B: only after approval, plan and execute the work in a controlled way.**

This prevents roadmap inertia from quietly turning a deferred idea into an active code path.

---

## Gate A — Reopen decision

### What must be true before M26 can reopen
A future return should begin with a fresh **ralplan** pass and a **new ADR**. That ADR must either:
- reopen M26 with explicit constraints, or
- reaffirm that M26 should remain deferred.

No lighter-weight memo or informal note should be treated as sufficient authority.

Before reopening M26, the following should exist:

1. **A written problem statement and sponsor**
   - Why is a scheduler-driven automation prototype needed now?
   - What user or operator outcome justifies the added complexity?

2. **A named operational owner**
   - Someone must own configuration behavior, lifecycle expectations, observability, and failure escalation.

3. **A named security review owner**
   - Someone must own the review of secrets, trust boundaries, authentication assumptions, network assumptions, and branch-level risk.

4. **An initial security and operational posture**
   - configuration sources and boundaries
   - secrets handling rules
   - trust and authentication assumptions
   - network assumptions
   - failure escalation expectations

5. **A boundary hypothesis**
   - Will M26 live as a clearly separated in-repo optional branch?
   - Or should it become a sibling package or separately packaged surface?

6. **An explicit statement that first-pass execution will be team-based**
   - If M26 is reopened, the initial execution should not be treated as solo exploratory work.

### Gate A decision rule
If any of the items above are missing, M26 should remain deferred.

If all of them are present, the new ADR may authorize post-approval planning.

---

## Boundary decision: in-repo branch or separate package?
If M26 is reopened, the first major choice is whether the work belongs inside this repository as a tightly scoped optional branch or as a more strongly separated package surface.

### Option B — constrained in-repo optional branch
This is appropriate only if all of the following stay true:
- the simulator-first identity remains obvious,
- shared internals can be reused through narrow and well-audited seams,
- security and trust assumptions remain simple enough to review inside one repository boundary,
- the documentation burden remains manageable without confusing the project’s main purpose.

### Option C — sibling package or separately packaged branch
This is preferable when:
- the automation branch risks confusing the project’s public identity,
- deployment or runtime dependencies diverge from the simulator and library surfaces,
- stronger isolation is needed for secrets, trust boundaries, or network-facing behavior,
- release cadence or support expectations differ materially from the simulator-first core.

### Default tie-breaker
If the decision is mixed or unclear, prefer **stronger separation**. In practice, that means defaulting to the sibling-package or separately packaged option.

---

## Gate B — Post-approval execution plan
Gate B starts only after a new ADR explicitly reopens M26.

### Phase 1 — Scope and boundary definition
The first post-approval task is to define exactly what M26 is and is not.

This phase should:
- apply the chosen boundary decision,
- define what code may be shared with simulator or library surfaces,
- define what must stay branch-local,
- choose packaging and naming that cannot be mistaken for the simulator’s mainline,
- define the intended operator and runtime shape.

Expected outputs:
- a boundary decision record,
- a packaging and layout proposal,
- a clear list of branch-specific deliverables.

### Phase 2 — Operational and security design before coding
M26 should not begin with implementation. It should begin with operational design.

This phase should define:
- configuration sources, defaults, and overrides,
- invalid-configuration behavior,
- secrets boundaries,
- authentication, trust, and network assumptions,
- startup, readiness, steady-state, shutdown, and restart behavior,
- observability expectations,
- failure handling and escalation expectations,
- the boundary between scheduler logic and automation-specific control flow.

Expected outputs:
- an operational and security design note,
- an M26 PRD,
- an M26 test specification.

### Phase 3 — Team execution planning
The initial reopened implementation should be planned as coordinated team work.

This phase should:
- identify the runtime entrypoints,
- divide the work into implementation, boundary, security, documentation, and verification lanes,
- assign named ownership for each lane,
- define acceptance checkpoints before coding begins.

Expected outputs:
- an execution slice map,
- a lane ownership plan,
- a dependency order for delivery.

### Phase 4 — Controlled implementation
Only after the earlier phases are complete should implementation begin.

The first execution pass should remain team-based and should cover at least:
- runtime behavior,
- package and layout separation,
- security review,
- observability and lifecycle visibility,
- explanatory documentation,
- verification evidence.

### Phase 5 — Completion and truthfulness audit
Before calling M26 complete, the project should confirm that the optional production branch has not silently rewritten the repository’s identity.

This phase should:
- re-audit project wording,
- confirm that branch boundaries remain explicit,
- confirm that operational and security owners have signed off their surfaces,
- record remaining risks and unsupported claims.

---

## Verification expectations
A future M26 should not be considered complete unless it can show evidence for all of the following:

1. **Governance evidence**
   - ADR 0003 is cited as the prior approved state.
   - A newer ADR explicitly reopens M26.

2. **Service and integration evidence**
   - the prototype starts in its supported launch mode,
   - a basic scheduler-driven automation flow works end to end.

3. **Lifecycle evidence**
   - startup, readiness, steady-state, shutdown, and restart behavior are defined and tested.

4. **Observability and failure-mode evidence**
   - expected signals exist for normal operation and failure states,
   - failures are surfaced in a predictable and operator-visible way.

5. **Security evidence**
   - secrets and configuration boundaries are enforced as documented,
   - trust, authentication, and network assumptions are reviewed,
   - the named security review owner has completed the branch review.

6. **Boundary and documentation evidence**
   - the branch does not masquerade as the simulator default,
   - packaging and naming remain truthful,
   - documentation matches the actual scope.

7. **Regression evidence**
   - existing simulator and library surfaces still pass their required verification after any shared-internal changes.

### Exact audit surfaces
The completion audit should explicitly review:
- `README.md`
- `docs/project-architecture-and-status.md`
- `docs/linux-mapping.md`
- `docs/roadmap/open-questions.md`
- `docs/future-directions.md`
- `src/tests/identity_gate_test.zig` or an equivalent scripted audit surface

---

## Recommended execution mode
If M26 is ever reopened, the initial implementation should remain **team-only**.

That recommendation is based on the shape of the work. M26 is not just a coding milestone. It also includes boundary management, documentation, operational design, security review, and verification. Those concerns are easier to keep honest when they are treated as separate but coordinated lanes.

A later narrow fix or verification follow-up may be handled by a single-owner loop, but the first reopened execution should not.

---

## Principal risks to watch
The most important risks are:
- treating roadmap presence as approval,
- letting the optional branch blur the simulator-first identity,
- sharing too much internal surface without explicit contracts,
- under-specifying operational behavior,
- under-specifying security and trust assumptions,
- passing smoke tests while documentation and boundary truth drift out of alignment.

---

## Practical checklist for a future return
If returning to this project later with serious intent to revisit M26, use this order:

1. Re-read ADR 0003 and the roadmap M26 sections.
2. Run a fresh **ralplan** pass focused on whether M26 should be reopened.
3. Write a **new ADR** that either reopens M26 with constraints or reaffirms deferment.
4. Name the operational owner and security review owner.
5. Decide the boundary model using the in-repo versus separate-package rubric.
6. Write the operational and security design before coding.
7. Prepare the PRD and test specification.
8. Execute the first implementation pass with a coordinated team workflow.
9. Complete the audit across the required documentation and test surfaces.
10. Only then decide whether M26 is truly complete.

## Final guidance
The disciplined way to complete M26 is to treat it as a governed re-charter, not as a backlog item waiting for spare time.

If the project ever returns to this branch, the strongest sign of maturity will be restraint at the beginning: reopen it explicitly, define its boundary carefully, specify operational and security obligations before coding, and verify that the repository still tells the truth about what it is.
