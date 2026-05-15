# Roadmap and gate artifacts

This directory is the committed roadmap information architecture for
`zig-scheduler`. It separates active governance, milestone plans, drafts, and
archived planning material so roadmap presence cannot be mistaken for permission
to implement a gated branch.

## Current truth and production gate

- The repo is a deterministic scheduler simulator / scheduler laboratory, not a
  kernel scheduler, daemon, service, agent, or production automation runtime.
- `docs/adr/0003-m25-productionization-gate.md` deferred the optional M26
  production branch indefinitely.
- Any future daemon/service/automation/runtime work requires a new explicit
  re-charter after ADR 0003. The M26 roadmap entry remains historical/planning
  context only, not implementation approval.
- The production-grade roadmap under `.omx/plans/` means production-grade
  **laboratory/product quality** until a later ADR reopens runtime scope.

## Source-of-truth order

M36 de-duplication hub: `docs/source-of-truth-index.md` records canonical owners for repeated production, observability, scenario, report, SDK, and contract claims.

1. ADRs in `docs/adr/` define approved identity and gate decisions.
2. `docs/project-architecture-and-status.md` summarizes the current implemented
   status and active proof surfaces.
3. This file indexes roadmap artifacts and classifies active vs draft/archive
   material.
4. Milestone-specific PRDs/test specs under `docs/roadmap/` define bounded work
   only when their prerequisite gates are satisfied.
5. `.omx/plans/` contains generated/execution planning artifacts. Those plans
   are useful for follow-up execution, but they do not override ADR gates.

## Core roadmap

- `prd-multi-horizon-zig-scheduler-roadmap.md` — original M1.5-M26 roadmap and
  gate structure. M26 remains blocked by the approved M25 deferment unless a
  future ADR explicitly reopens it.
- `test-spec-multi-horizon-zig-scheduler-roadmap.md` — verification matrix for
  the original roadmap.
- `open-questions.md` — resolved/unresolved roadmap questions.

## Gate artifacts

- `gates/prd-m18-linux-observability-gate.md`
- `gates/test-spec-m18-linux-observability-gate.md`
- `m25/prd-m25-productionization-gate.md`
- `m25/test-spec-m25-productionization-gate.md`

## Active milestone plans and test specs

- `m15/` — non-TTY TUI rendering surface
- `m19/` — curated offline Linux-observability snapshots
- `m20/` — simulator-to-trace comparison summary
- `m21/` — simulator-first teaching surface polish
- `m22/` — optional library / SDK stabilization
- `m23/` — packaged teaching distribution and courseware
- `m24/` — research sandbox governance
- `m25/` — productionization gate decision artifacts
- `phase1/` — Phase 1 and sequential-roadmap baseline artifacts

## Drafts

`drafts/` contains planning notes and ralplan outputs that informed active
milestone docs. Drafts are not authoritative unless promoted into an active
milestone directory, ADR, or current status doc.

## Archive

`archive/` contains superseded planning material kept for history. Archived
files must not be used as current implementation authority without first
checking the active roadmap, current status doc, and ADRs.

## Maintenance checklist

When roadmap files move or new milestone docs are added:

1. Update this index in the same change.
2. Keep production/runtime wording aligned with ADR 0003.
3. Ensure active milestone directories include both PRD and test-spec surfaces
   when implementation is expected.
4. Keep stale drafts in `drafts/` or `archive/` instead of mixing them with
   active docs.
5. Run the docs/identity tests and a dead-link/path audit.
