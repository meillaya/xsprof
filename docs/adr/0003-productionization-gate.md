# ADR 0003: M25 productionization gate for daemon / service / automation scope

- Status: Approved
- Date: 2026-04-23
- Milestone: M25
- Related roadmap: `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md`

## Context
The roadmap reserved an optional production branch (`M26`) behind the M25
planning gate. After completing the simulator mainline, the bounded
observability branch, the teaching/distribution branch, the library branch, and
an experimental sandbox, the project now has enough evidence to evaluate
whether it should ever become a daemon, service, agent, or automation system.

The repo is still explicitly simulator-first. Its current strengths are:
- deterministic scheduling experiments
- teaching and courseware surfaces
- a narrow embedder facade
- bounded research and observability side lanes

Moving into operational service scope would introduce new burdens that are not
present in the current simulator identity: process lifecycle, configuration,
security, failure handling, observability, and ongoing operational ownership.

## Decision
**Deferred the optional production branch indefinitely.**

This means:
- `zig-scheduler` remains simulator-first in current truth and near-term intent
- M26 is blocked unless a future explicit re-charter reopens the production branch
- no daemon/service/agent/automation implementation is authorized by this milestone

## Rationale
- Approving productionization now would blur the repo’s simulator-first truth.
- The current project does not yet justify the operational complexity of a service branch.
- Deferring indefinitely preserves honesty without foreclosing a later explicit revisit.

## Consequences
- README and architecture docs should describe the production branch as gated/deferred.
- M26 must not begin from roadmap inertia alone; it requires a future explicit re-charter.
- Future requests for daemon/service/automation behavior should route back through a new planning gate rather than direct implementation.

## Rejected alternatives
- **Approve M26 now with constraints** — rejected because current repo value and evidence do not justify operational/service scope.
- **Reject the production branch forever** — rejected because a future re-charter could still be appropriate if project goals materially change.

## Approval signoff
M25 is approved by landing this ADR together with README/status/test updates that keep the deferred production-branch decision explicit.
