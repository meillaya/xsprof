# Test specification: production-grade scheduler 50-milestone roadmap

- Paired PRD: `.omx/plans/prd-production-grade-scheduler-50-milestones.md`
- Status: RALPLAN consensus approved

## Global gates

1. Formatting: `zig fmt build.zig build.zig.zon $(find src -name '*.zig' -print)`.
2. Diff hygiene: `git diff --check`.
3. Build/tests: `zig build test --summary all`.
4. Report drift: `zig build reports -- --check` for report/analysis/benchmark/dashboard-output-affecting changes.
5. Wording audit: no current-doc claim that the repo is already a live production scheduler, kernel scheduler, daemon, or Linux-performance tool.

## Acceptance-criteria traceability

| PRD acceptance criterion | Proving gates | Evidence artifact |
| --- | --- | --- |
| Milestones have deliverables, touchpoints, checks | Phase touchpoint maps plus milestone table review | PRD review checklist and milestone execution reports |
| Early milestones reduce risk before expansion | M27-M36 and M37-M46 gates pass before feature claims | Cleanup/quality reports, architecture tests |
| Performance baselines precede optimization | M47 baseline before M48-M56 budgets/optimizations | Versioned perf baseline JSON + budget report |
| TUI dashboard has unified IA and separate screens | M67 IA before M68-M74 screens | Dashboard IA doc + snapshot suite |
| Production runtime is ADR-gated | M32 compatibility classification, M75 ADR, M76 package | ADR and decision package with owners/signoff |
| Staffing/launch/verification guidance exists | PRD handoff sections reviewed | RALPLAN final plan |

## Phase-specific gates

- M27-M36 cleanup: architecture/import tests, dead-link/docs consistency checks, ownership docs, M32 lab-only/runtime-portable contract classification.
- M37-M46 quality: categorized tests, golden fixtures, deterministic oracle, negative tests, release checklist dry-run.
- M47-M56 performance: benchmark baselines, allocation counts, wall-time budgets, noise tolerance, regression reports; budgets are versioned to simulator semantics and require reviewed re-baselining after semantic changes; M48 must set numeric targets before M49-M56 optimization begins.
- M57-M66 scheduler semantics: invariant/property tests, scenario fixtures, policy contract tests, replay/diff oracles; any semantic change reports whether Phase C budgets need re-baselining.
- M67-M74 dashboard: snapshot tests for each screen and terminal tier; interaction tests for navigation/filter/scrub where supported; all old screens mapped into the M67 IA.
- M75-M76 production gates: ADR signoff, sponsor/operator/security owner evidence, threat model, explicit defer/reopen decision; M76 packages the decision or LTS lab release plan, not implementation permission by itself.

## Milestone traceability checkpoints

- M27-M32 must prove production-scope truthfulness and contract-boundary clarity.
- M33-M36 must prove cleanup did not remove compatibility without a versioned decision.
- M37-M46 must prove quality gates are runnable and documented.
- M47-M56 must prove performance claims with reproducible baselines and budget reports.
- M57-M66 must prove scheduler semantics with invariants, fixtures, and explainability artifacts.
- M67-M74 must prove dashboard IA and screen separation with snapshots and navigation tests.
- M75-M76 must prove governance decision quality, not runtime implementation.

## Roadmap review checklist

Before executing any milestone slice, the executor or planner records:
- milestone ID and intended PR-sized slice;
- applicable command class: docs audit, architecture test, golden check, snapshot, benchmark, property test, ADR signoff, or full suite;
- required evidence artifact path;
- whether the slice touches public contracts or production-boundary wording;
- reviewer/verifier role responsible for signoff.

## Completion evidence for each milestone

Each milestone is complete only when its PR or execution report includes:
- changed files;
- acceptance criteria result;
- commands run and outputs summarized;
- known gaps or Not-tested section;
- updated docs/contracts when behavior changes.
