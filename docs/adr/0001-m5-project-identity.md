# ADR 0001: M5 project identity after Phase-1 hardening

- Status: Approved
- Date: 2026-04-21
- Milestone: M5
- Related roadmap: `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md`

## Context
The repository began as a deterministic CPU scheduling simulator and the first completed milestones intentionally hardened that simulator identity: stable scenario inputs, versioned exports, deterministic analysis, and reproducible benchmark baselines.

M5 is the first planning gate before the roadmap broadens beyond pure simulator hardening. The roadmap requires an explicit ADR choosing among three identity bands:
1. remain simulator-only,
2. become a broader scheduler laboratory,
3. open explicit external-facing branches.

The roadmap already sketches a sequential core spine plus optional gated branches. The decision here must keep current claims truthful while making downstream branch eligibility explicit.

## Decision
Adopt the repository identity as a **broader scheduler laboratory roadmap with a simulator-only mainline**.

This means:
- the **current implementation** remains a deterministic, user-space teaching simulator,
- the **default mainline roadmap** stays simulator-centric (`M6 -> M17`),
- Linux-observability, teaching/distribution, research, library, and production-like work remain **explicit optional branches** with their own gates,
- no optional branch changes the truthfulness requirements of the mainline simulator docs.

## Rationale
- Remaining strictly simulator-only would conflict with the already-approved long-horizon roadmap structure and hide intentional future branch work that is useful to plan openly.
- Opening all external-facing branches as part of the default backlog would blur the repo's current identity too early and weaken safety/truthfulness constraints.
- A broader lab charter with a simulator-only mainline preserves honest present-tense claims while still allowing clearly gated future exploration.

## Approved track classification after M5
- **Mainline core branch:** `M6 -> M17`
- **Planning gates:** `M5`, `M18`, `M25`
- **Optional Linux-observability branch:** `M19 -> M20` after `M18` approval
- **Optional distribution branch:** `M21 -> M23` after core export-analysis maturity
- **Optional library branch:** `M22` when embedding/API goals justify it
- **Optional research branch:** `M24` once policy/testing boundaries are mature
- **Optional production branch:** `M26` only after `M25` re-charter

## Consequences
- README and roadmap language should describe the repo as a simulator today and a broader scheduler laboratory roadmap over time.
- Future milestone execution may continue directly into `M6` because it is the approved mainline branch after this gate.
- Optional branches remain opt-in and gated; they are not mandatory serialized backlog.
- Docs must keep simulator-local caveats explicit even when optional branches are discussed.

## Rejected alternatives
- **Remain simulator-only forever** — rejected because it hides already-approved branch planning and forces later identity work into ad hoc exceptions.
- **Treat all post-M5 branches as default backlog** — rejected because it would weaken the simulator-only truthfulness band and create avoidable scope drift.
- **Split the repo immediately into multiple repos/roadmaps** — rejected because the current single-repo roadmap still benefits from one mainline plus explicit branch gates.

## Approval signoff
M5 is approved by landing this ADR together with roadmap/README wording updates that link to it and preserve the simulator-local wording audit.
