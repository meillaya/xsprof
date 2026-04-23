# PRD — M25 productionization gate: daemon / service / automation branch

## Status
Execution PRD reconstructed from the approved roadmap gate on 2026-04-23.

## Goal
Make the M25 re-charter decision explicit: should `zig-scheduler` ever move
into daemon/service/automation scope?

## Decision target
M25 must end with one explicit outcome:
- rejected forever
- deferred indefinitely
- approved with constraints

## Chosen M25 outcome
**Deferred indefinitely.**

The repo remains simulator-first. M26 stays blocked unless a future explicit
re-charter reopens the production branch.

## Why defer instead of approve now
- the repo’s strongest current value is simulator/teaching/research, not service operation
- production scope would require operational ownership, failure handling, security, config, lifecycle, and support commitments not justified by current goals
- approving M26 now would blur the simulator-first truth of the project

## Why defer instead of reject forever
- future needs could justify revisiting the decision
- the roadmap can keep the branch visible without authorizing implementation now

## Required deliverables
- `docs/adr/0003-m25-productionization-gate.md`
- `README.md` alignment
- `docs/project-architecture-and-status.md` alignment
- `src/tests/identity_gate_test.zig` coverage
- `docs/roadmap/open-questions.md` resolution update
- optional roadmap reference updates if needed for traceability

## Acceptance criteria
- the ADR explicitly records M25 as deferred indefinitely
- README/docs keep simulator-first identity primary
- M26 is clearly blocked pending a future explicit re-charter
- no daemon/service/automation implementation is added
- tests prove the gate decision is documented and linked

## Verification
- `zig build test --summary all`
- docs/governance audit
- no implementation-before-approval audit for M26 path
