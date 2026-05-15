# Context snapshot: production-grade scheduler 50-milestone roadmap

## Task statement
Produce a `$ralplan` consensus roadmap with 50 milestones to evolve `zig-scheduler` toward a production-grade scheduler/lab, including repo cleanup, performance goals, and a unified smart-dashboard TUI with separate relevant screens.

## Desired outcome
A saved plan artifact under `.omx/plans/` that:
- preserves current simulator-first truth and explicitly handles the existing M25 productionization gate;
- defines 50 sequenced milestones, each with purpose, deliverables, acceptance criteria, and verification;
- covers cleanup/refactor, performance engineering, scheduler semantics, TUI/dashboard UX, observability, packaging/release, and production re-charter gates;
- includes RALPLAN-DR summary, ADR, staffing guidance, launch hints, and verification path.

## Known facts / evidence
- README states the project is a deterministic CPU scheduling simulator, not a kernel scheduler, daemon, or production automation system. It lists simulator, TUI, snapshots, M19/M20 observability, SDK smoke, analysis, and benchmark entrypoints.
- `docs/project-architecture-and-status.md` says the project is simulator-first and that Linux-facing/productized/research-heavy branches are gated. It identifies core layers: scenario, engine, scheduling-class boundary, reporting/export, analysis/benchmark, property/generator.
- `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md` already covers M1.5 through M26. M25 is a productionization gate; M26 is optional/deferred.
- `docs/adr/0003-m5-productionization-gate.md` equivalent path is `docs/adr/0003-m25-productionization-gate.md`; it defers daemon/service/automation scope indefinitely and requires explicit future re-charter before production branch work.
- `docs/future-directions.md` recommends any M26 return use a fresh ralplan pass and new ADR, with operational/security owners and team-based execution.
- Current source tree includes `src/sim`, `src/policies`, `src/cli`, `src/tui`, `src/analysis`, `src/bench`, `src/observability`, `src/report_pipeline`, `src/testing`, `src/sdk`, and tests.
- Current TUI already has views/domains for picker, explorer, drawer, diff, help, observability summary, and observability comparison in `src/tui/render.zig`, with args for input/stdin/scenario/M19/M20/snapshot in `src/tui/args.zig`.
- Build modules/tests are configured in `build.zig` for internal library, public SDK, analysis, bench, report pipeline, TUI, main executable, simulator executable, and embed smoke.
- The working tree currently contains the recent Zig 0.16.0 migration and doc refresh; validator evidence from prior turn: `zig version` = `0.16.0`, `zig build test --summary all` = 17/17 steps, 196/196 tests.

## Constraints
- Do not claim the current project is production-grade or a live OS scheduler.
- Any daemon/service/automation production work must be behind a new ADR/re-charter because ADR 0003 defers M26 indefinitely.
- Keep deterministic simulator behavior and `zig-scheduler/report` compatibility unless a milestone explicitly introduces a versioned contract migration.
- Prefer stdlib-first, reviewable increments; no dependencies without explicit later approval.
- Plan only; do not implement in this `$ralplan` turn.

## Unknowns / open questions
- Target meaning of “production-grade scheduler”: production-grade simulator/lab vs production automation/service vs real OS scheduler component.
- Target users: students, researchers, embedders, operators, or all in phases.
- Performance targets need baselines after cleanup because existing benchmark harness is output-size/trace-volume oriented, not runtime/latency focused.
- Release/distribution targets are not specified.

## Likely codebase touchpoints
- Governance/docs: `README.md`, `docs/project-architecture-and-status.md`, `docs/roadmap/`, `docs/adr/`, `docs/future-directions.md`.
- Core simulation: `src/sim/engine.zig`, `src/sim/types.zig`, `src/sim/metrics.zig`, `src/sim/trace.zig`.
- Policies: `src/policies/class.zig`, `src/policies/*.zig`, `src/policies/experimental/` if introduced.
- Dashboard/TUI: `src/tui/args.zig`, `src/tui/root.zig`, `src/tui/render.zig`, `src/tui/terminal.zig`.
- Reporting/API: `src/contract/report.zig`, `src/cli/report.zig`, `src/cli/output.zig`, `src/sdk/*`.
- Analysis/performance: `src/analysis/*`, `src/bench/*`, `docs/benchmarks/*`.
- Observability: `src/observability/*`, `fixtures/linux-observability/*`.
- Verification: `src/testing/property.zig`, `src/tests/*`, `build.zig`.
