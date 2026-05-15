# Source-of-truth index

This index is the M36 de-duplication hub for claims that are repeated across the
repository. Keep the detailed content in the owning document and point readers
there instead of copying long status narratives into every milestone note.

## Canonical claim owners

| Claim family | Canonical owner | Mirrors may summarize in |
| --- | --- | --- |
| Project identity: deterministic simulator / scheduler laboratory | `docs/project-architecture-and-status.md` | `README.md`, `docs/roadmap/README.md` |
| Production branch / daemon / service / runtime permission | `docs/adr/0003-productionization-gate.md` | roadmap docs, PRDs, release notes |
| Linux observability scope | `docs/adr/0002-linux-observability-gate.md` | observability/comparison docs, teaching pack, courseware |
| Scenario input contract | `src/sim/scenario.zig` and `src/sdk/scenario_io.zig` | scenario corpus docs, SDK docs |
| Report JSON contract | `src/contract/report.zig` | analysis, benchmark, dashboard, courseware docs |
| Public SDK ownership | `docs/library-sdk.md` and `src/lib.zig` | examples and release notes |
| Production-boundary classification | `docs/contract-inventory.md` and `src/contract/inventory.zig` | roadmap status docs |
| Phase B quality gates and release discipline | `docs/quality-gates.md`, `docs/release-checklist.md`, and `src/quality/root.zig` | PRDs, release notes, dashboard docs |
| Phase C performance budgets and reproducible perf gate | `docs/performance-gates.md` and `src/perf/root.zig` | benchmark docs, release notes |
| Scheduling semantics v2 vocabulary | `docs/scheduler-semantics-v2.md` and `src/semantics/root.zig` | policy docs, dashboard docs, report explanations |
| Smart dashboard screen IA and no-ad-hoc-mode rule | `docs/smart-dashboard-spine.md` and `src/dashboard/root.zig` | TUI docs, screenshots, help text |
| LTS simulator-lab release decision | `docs/adr/0004-lts-simulator-lab-release.md` and `docs/lts-simulator-lab-release-plan.md` | release notes, roadmap closeout |

## M36 maintenance rules

1. Use short summaries in mirrors; link to the canonical owner for details.
2. If production/runtime wording changes, update ADR 0003 or a superseding ADR in
   the same commit.
3. If observability wording changes, update ADR 0002 or a superseding ADR in the
   same commit.
4. If a public contract changes, update both source metadata and the matching doc
   owner in the same commit.
5. Run identity/architecture tests after claim edits.
6. For quality claims, update `docs/quality-gates.md`, `docs/release-checklist.md`, and `src/quality/root.zig` together.
7. For performance claims, update `docs/performance-gates.md`, `src/perf/root.zig`, and benchmark baseline docs together.
8. For scheduler semantics claims, update `docs/scheduler-semantics-v2.md`, `src/semantics/root.zig`, and semantics tests together.
9. For dashboard claims, update `docs/smart-dashboard-spine.md`, `src/dashboard/root.zig`, TUI mappings, and dashboard tests together.
10. For release decisions, update ADR 0004, the LTS release plan, and decision-package tests together.

## Known allowed repeated phrases

The following phrases are intentionally repeated because they are guardrails:

- deterministic CPU scheduling simulator
- simulator laboratory
- not a kernel scheduler, daemon, service, agent, or production automation runtime
- offline observability-only fixtures
- ADR 0003

Repeating these guardrails is allowed; introducing contradictory variants is not.
