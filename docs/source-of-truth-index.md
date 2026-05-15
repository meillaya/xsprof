# Source-of-truth index

This index is the M36 de-duplication hub for claims that are repeated across the
repository. Keep the detailed content in the owning document and point readers
there instead of copying long status narratives into every milestone note.

## Canonical claim owners

| Claim family | Canonical owner | Mirrors may summarize in |
| --- | --- | --- |
| Project identity: deterministic simulator / scheduler laboratory | `docs/project-architecture-and-status.md` | `README.md`, `docs/roadmap/README.md` |
| Production branch / daemon / service / runtime permission | `docs/adr/0003-m25-productionization-gate.md` | roadmap docs, PRDs, release notes |
| Linux observability scope | `docs/adr/0002-m18-linux-observability-gate.md` | M19/M20 docs, teaching pack, courseware |
| Scenario input contract | `src/sim/scenario.zig` and `src/sdk/scenario_io.zig` | scenario corpus docs, SDK docs |
| Report JSON contract | `src/contract/report.zig` | analysis, benchmark, dashboard, courseware docs |
| Public SDK ownership | `docs/m22-library-sdk.md` and `src/lib.zig` | examples and release notes |
| Production-boundary classification | `docs/m31-m32-contract-inventory.md` and `src/contract/inventory.zig` | roadmap status docs |
| Phase B quality gates and release discipline | `docs/quality-gates.md`, `docs/release-checklist.md`, and `src/quality/root.zig` | PRDs, release notes, dashboard docs |
| Phase C performance budgets and reproducible perf gate | `docs/performance-gates.md` and `src/perf/root.zig` | benchmark docs, release notes |
| Scheduling semantics v2 vocabulary | `docs/scheduler-semantics-v2.md` and `src/semantics/root.zig` | policy docs, dashboard docs, report explanations |
| Smart dashboard screen IA and no-ad-hoc-mode rule | `docs/smart-dashboard-spine.md` and `src/dashboard/root.zig` | TUI docs, screenshots, help text |

## M36 maintenance rules

1. Use short summaries in mirrors; link to the canonical owner for details.
2. If production/runtime wording changes, update ADR 0003 or a superseding ADR in
   the same commit.
3. If observability wording changes, update ADR 0002 or a superseding ADR in the
   same commit.
4. If a public contract changes, update both source metadata and the matching doc
   owner in the same commit.
5. Run identity/architecture tests after claim edits.
6. For M37-M46 quality claims, update `docs/quality-gates.md`, `docs/release-checklist.md`, and `src/quality/root.zig` together.
7. For M47-M56 performance claims, update `docs/performance-gates.md`, `src/perf/root.zig`, and benchmark baseline docs together.
8. For M57-M66 semantics claims, update `docs/scheduler-semantics-v2.md`, `src/semantics/root.zig`, and semantics tests together.
9. For M67-M74 dashboard claims, update `docs/smart-dashboard-spine.md`, `src/dashboard/root.zig`, TUI mappings, and dashboard tests together.

## Known allowed repeated phrases

The following phrases are intentionally repeated because they are guardrails:

- deterministic CPU scheduling simulator
- simulator laboratory
- not a kernel scheduler, daemon, service, agent, or production automation runtime
- offline observability-only fixtures
- ADR 0003

Repeating these guardrails is allowed; introducing contradictory variants is not.
