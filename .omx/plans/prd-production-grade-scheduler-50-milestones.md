# PRD: 50-milestone roadmap to a production-grade scheduler laboratory

- Status: RALPLAN consensus approved
- Date: 2026-05-15
- Context snapshot: `.omx/context/production-grade-scheduler-roadmap-20260515T061935Z.md`
- Scope: planning only; no source implementation in this workflow

## Requirements summary

Produce a 50-milestone roadmap that evolves `zig-scheduler` from its current simulator-first scheduler laboratory into a production-grade scheduler **laboratory/product** while preserving the truth that it is not currently a live OS scheduler, daemon, or automation service. The roadmap must include repo cleanup, performance goals, and a unified smart TUI/dashboard with separate relevant screens. Any actual production daemon/service/automation scope remains gated by `docs/adr/0003-m25-productionization-gate.md` and must be explicitly re-chartered before implementation.

## RALPLAN-DR summary

### Principles
1. **Truthful scope before ambition** — current mainline remains simulator-first until a new ADR explicitly changes that.
2. **Production-grade means verified, observable, maintainable, and performant** before it means daemon/service behavior.
3. **One coherent product surface** — CLI, TUI, reports, benchmarks, observability, SDK, and docs should tell one story.
4. **Versioned contracts over hidden coupling** — scenario, report, policy, dashboard, and SDK seams must be explicit.
5. **Performance work is benchmark-gated** — no “faster” milestone without baseline, budget, regression gate, and evidence.

### Decision drivers
1. **M25 gate constraint:** production automation is currently deferred and must not sneak into mainline through roadmap wording.
2. **Existing breadth:** the repo already has simulator, policies, TUI, observability, analysis, benchmarks, courseware, SDK, and report pipeline surfaces.
3. **Maintainability pressure:** production-grade evolution requires repo simplification and test/benchmark gates before adding major features.

### Viable options

#### Option A — Production-grade scheduler laboratory first (recommended)
- Approach: make the simulator/lab/dashboard/sdk production-grade, then optionally re-charter automation/service work near the end.
- Pros: respects ADR 0003; improves current repo value immediately; reduces risk; creates performance and UX foundations.
- Cons: does not immediately create a live scheduler/daemon; requires disciplined wording.

#### Option B — Reopen production branch immediately
- Approach: begin by re-chartering M26 and building service/automation runtime in parallel with cleanup.
- Pros: fastest path to something “production scheduler”-branded.
- Cons: conflicts with current deferred state; high security/ops burden; likely blurs project identity before foundations are ready.

#### Option C — Split production scheduler into sibling package now
- Approach: keep this repo as simulator lab; create a separate product package for daemon/service scheduler work.
- Pros: strongest boundary for security/ops; protects educational simulator.
- Cons: premature without clear sponsor/operator; duplicates contracts before cleanup.

Recommendation: Option A, with explicit re-charter gates near the end for any Option B/C production runtime.

## Acceptance criteria

1. A future execution program can select any milestone and identify its deliverables, code/doc touchpoints, acceptance checks, and verification command class.
2. The first 20 milestones reduce risk before broad feature expansion: docs/gates, cleanup, test architecture, contract hardening, and quality automation.
3. Performance milestones define measurable baselines and budgets before optimization work begins.
4. TUI/dashboard milestones define a unified IA with separate screens instead of ad hoc view growth.
5. Production runtime milestones are gated by a new ADR and do not contradict ADR 0003.
6. The plan includes explicit staffing guidance for Ralph, Team, and goal-mode follow-up.

## 50 milestones

### Phase A — Governance, repo cleanup, and architectural simplification

| ID | Milestone | Deliverables | Acceptance / verification |
| --- | --- | --- | --- |
| M27 | Current-truth reset and roadmap re-charter | Update README/status/roadmap wording to describe “production-grade scheduler laboratory” vs deferred service scope. | Wording audit over README, ADRs, roadmap, identity tests; `zig build test --summary all`. |
| M28 | Repo information architecture cleanup | Move stale drafts/archive notes behind a clear docs IA; index every active surface. | `docs/roadmap/README.md` and `docs/project-architecture-and-status.md` match tree; dead-link audit. |
| M29 | Build graph hygiene | Normalize modules/imports, remove accidental cross-module coupling, document module ownership. | `build.zig` module map documented; every module test target passes independently. |
| M30 | Zig 0.16 compatibility cleanup pass | Convert migration shims into intentional utilities; remove duplicated one-off IO patterns. | No scattered ad hoc IO helpers beyond approved facade; `zig fmt`, `zig build test`. |
| M31 | Memory ownership and allocator contract audit | Document ownership rules for scenarios, reports, parsed JSON, generated workloads, TUI history. | Leak-free tests under current test allocator; ownership comments on public SDK functions. |
| M32 | Production-boundary compatibility and contract inventory | Inventory scenario input, report JSON, SDK, CLI args, TUI snapshot output, benchmark output; classify each as lab-only, runtime-portable, or intentionally non-runtime without authorizing production implementation. | Contract matrix in docs; tests identify owner module for each contract; ADR 0003 remains intact. |
| M33 | Scenario parser unification | Make object-style ZON canonical; isolate legacy parser behind compatibility boundary. | Legacy fixtures still pass; new tests prove parser mode detection and errors. |
| M34 | Policy boundary cleanup | Split policy interface, policy state, and per-policy implementation contracts. | Engine imports boundary only; policy architecture tests enforce no direct engine-policy coupling. |
| M35 | Report/analysis boundary cleanup | Ensure analysis, benchmarks, dashboard, and courseware consume report contracts rather than engine internals. | Dependency audit; report contract fixtures cover downstream consumers. |
| M36 | Documentation de-duplication pass | Collapse duplicate milestone claims into canonical docs and generated indexes. | Docs lint/check script proves no conflicting production/observability claims. |

### Phase A touchpoint map

- Governance/docs: `README.md`, `docs/project-architecture-and-status.md`, `docs/roadmap/`, `docs/adr/`, `docs/future-directions.md`.
- Build/module graph: `build.zig`, `build.zig.zon`, module imports across `src/*`.
- Contracts and ownership: `src/sim/scenario.zig`, `src/contract/report.zig`, `src/cli/args.zig`, `src/tui/args.zig`, `src/sdk/*`, `src/bench/*`.
- Policy and engine seams: `src/sim/engine.zig`, `src/policies/class.zig`, `src/policies/*.zig`.

### Phase B — Verification, quality gates, and release discipline

| ID | Milestone | Deliverables | Acceptance / verification |
| --- | --- | --- | --- |
| M37 | Test taxonomy and ownership | Categorize unit/integration/property/golden/snapshot/contract tests and owners. | Test matrix in docs; CI/build step names match taxonomy. |
| M38 | Golden fixture governance | Define update workflow for reports, SVG, markdown, benchmark baselines, dashboard snapshots. | `zig build reports -- --check` documented and enforced. |
| M39 | Property testing expansion | Expand generator/shrinker across groups, topology, phases, deadlines, and invalid inputs. | Property suite covers every public policy class and core invariant. |
| M40 | Determinism oracle | Add reusable oracle proving repeated runs produce identical traces/reports/snapshots. | Determinism tests run over curated corpus and generated cases. |
| M41 | Mutation/fault injection harness | Add controlled invalid scenario/report/policy-state inputs for negative tests. | Negative fixtures assert stable diagnostics, not crashes. |
| M42 | Static architecture checks | Script/import tests for forbidden dependencies, branch boundaries, and policy/observability isolation. | Architecture gate fails on known forbidden import patterns. |
| M43 | CLI and SDK compatibility suite | Freeze public CLI/SDK examples and embedder smoke flows. | Versioned examples compile/run; docs examples are tested. |
| M44 | Dashboard snapshot regression suite | Capture stable dashboard frames for representative screens and terminal sizes. | Snapshot tests cover small/medium/large terminal tiers. |
| M45 | Release checklist and changelog discipline | Define release notes, version bumps, contract migration notes, and artifact checks. | Dry-run release checklist passes on current tree. |
| M46 | Quality dashboard | Produce a generated quality report from tests, coverage proxies, benchmark status, and contract gates. | One command emits current quality status for maintainers. |

### Phase B touchpoint map

- Test taxonomy and property/fault harness: `src/tests/*`, `src/testing/property.zig`, `scenarios/regressions/`.
- Golden artifacts and report drift: `docs/examples/`, `docs/benchmarks/`, `src/report_pipeline/*`, `src/analysis/*`, `src/bench/*`.
- Dashboard snapshots: `src/tui/render.zig`, `src/tui/root.zig`, future snapshot fixture directory.
- Release/quality reporting: `build.zig`, `docs/roadmap/`, generated quality report artifact.

### Phase C — Performance engineering and scalability

| ID | Milestone | Deliverables | Acceptance / verification |
| --- | --- | --- | --- |
| M47 | Runtime benchmark baseline | Add wall-time/allocation benchmarks for parse, simulate, export, analyze, render. | Baseline JSON committed; machine/environment metadata recorded. |
| M48 | Performance budgets | Define numeric budgets per scenario size and dashboard screen class before any optimization milestone begins. | CI/local benchmark check reports pass/fail against budgets with tolerance; every M49-M56 optimization cites its target budget. |
| M49 | Engine allocation reduction | Remove avoidable per-tick allocations and hot-path dynamic growth. | Allocation count/bytes improve vs M47 baseline without output drift. |
| M50 | Trace storage scaling | Introduce compact trace storage or indexing for large runs. | Large scenario trace memory reduced by target threshold; report compatibility preserved. |
| M51 | Policy micro-optimization pass | Benchmark FCFS/RR/CFS/deadline selection hot paths and optimize data structures. | Per-policy selection cost tracked and improved or justified. |
| M52 | Scenario parsing performance | Optimize ZON parse/materialization and legacy compatibility path. | Parse benchmarks improve; diagnostics remain stable. |
| M53 | Report JSON throughput | Optimize JSON serialization/deserialization and optional streaming path. | Export/import benchmark budget met; contract tests unchanged. |
| M54 | TUI render performance | Reduce dashboard frame render allocations and latency. | Snapshot render p95 budget per terminal size; no snapshot drift except intentional. |
| M55 | Analysis/SVG performance | Optimize downstream analysis and SVG generation over large traces. | Large-trace analysis budget met; golden outputs stable. |
| M56 | Performance regression gate | Make perf checks reproducible enough for local/CI gating with noise tolerance. | `zig build bench` plus perf gate produces actionable pass/fail. |

### Phase C touchpoint map

- Benchmark harness: `src/bench/*`, `docs/benchmarks/*`, future perf baseline artifacts.
- Hot paths: `src/sim/engine.zig`, `src/sim/trace.zig`, `src/sim/metrics.zig`, `src/policies/*.zig`.
- Parse/export/render throughput: `src/sim/scenario.zig`, `src/cli/output.zig`, `src/contract/report.zig`, `src/tui/render.zig`, `src/analysis/*`.
- Baseline rule: Phase C baselines are versioned against current simulator semantics and must be re-baselined through reviewed milestone work after Phase D semantic changes.

### Phase D — Scheduler semantics and advanced lab capability

| ID | Milestone | Deliverables | Acceptance / verification |
| --- | --- | --- | --- |
| M57 | Scheduling-class contract v2 | Define capability flags: preemptive, deadline-aware, group-aware, topology-aware, admission-aware. | Policy tests prove capabilities and unsupported combinations. |
| M58 | Priority and nice model | Add simulator-safe priority/nice inputs and policy integration. | Priority scenarios demonstrate expected ordering and starvation risks. |
| M59 | CFS-inspired fairness v2 | Refine vruntime/weight behavior and explain where it intentionally diverges from Linux. | Fairness metrics and docs demonstrate deterministic behavior. |
| M60 | Deadline/admission model v2 | Add explicit admission checks and missed-deadline accounting. | Deadline scenarios cover admission accept/reject and miss reporting. |
| M61 | Multi-queue runqueue model | Model per-core runqueues with deterministic balancing knobs. | No-double-run invariant and migration tests pass over generated cases. |
| M62 | Affinity and pinning | Add task/core affinity constraints and migration penalties. | Affinity scenarios prove constraints and fallback behavior. |
| M63 | Topology cost model | Extend topology domains to include configurable cost classes. | Cost-aware placement tests and dashboard visualization. |
| M64 | Group quota and burst accounting | Refine group scheduling with quota windows and throttling semantics. | Group fairness tests cover quota, throttle, recovery, and metrics. |
| M65 | Explainable decision log | Add structured policy-decision events separate from execution trace events. | Dashboard can explain “why this task ran” for each dispatch. |
| M66 | Deterministic replay and diff engine | Replay report/scenario pairs and diff policy decisions/metrics deterministically. | Replay reproduces committed reports; diff tests cover policy comparisons. |

### Phase D touchpoint map

- Scheduling contracts and capabilities: `src/policies/class.zig`, `src/policies/*.zig`, `src/sim/types.zig`.
- Engine semantics: `src/sim/engine.zig`, `src/sim/trace.zig`, `src/sim/metrics.zig`.
- Scenario corpus and fixtures: `scenarios/basic/`, `scenarios/regressions/`, `src/tests/scenario*_test.zig`.
- Explainability/replay/diff: `src/contract/report.zig`, `src/cli/report.zig`, `src/observability/comparison.zig`, dashboard screens.

### Phase E — Unified smart dashboard and production-runtime decision gates

| ID | Milestone | Deliverables | Acceptance / verification |
| --- | --- | --- | --- |
| M67 | Dashboard IA and navigation model | Define one smart dashboard shell with screens: Home, Scenario, Timeline, Tasks/Cores, Policy Compare, Observability, Performance, Reports, Help. | IA doc plus keyboard/navigation tests; old screens mapped to new screens. |
| M68 | Smart Home screen | Unified entry screen summarizing loaded source, health, recommended next actions, recent history. | Snapshot tests for empty, scenario, report, M19, M20 states. |
| M69 | Scenario and policy workspace | Screen for scenario metadata, policy settings, validation issues, and run controls. | Can inspect built-in/file scenarios and policy parameters from TUI. |
| M70 | Timeline trace explorer v2 | Rich timeline with scrub, zoom, event filters, and decision-log overlays. | Snapshot + interaction tests cover filters and selected tick/task. |
| M71 | Task/core drilldown screen | Dedicated task/core screen for lifecycle, waits, migrations, group/topology context. | Screens answer per-task/per-core questions without reading raw JSON. |
| M72 | Policy comparison screen | First-class compare screen across policies/scenarios with metric deltas and fairness indicators. | Deterministic pairwise comparison fixtures and dashboard snapshots. |
| M73 | Observability calibration screen | Unified M19/M20 screen with fixture provenance, limitations, and simulator-to-trace comparison. | Wording audit prevents Linux-performance overclaims. |
| M74 | Performance lab screen | Dashboard surface for benchmark baselines, budgets, regressions, and scenario scale. | Displays M47-M56 metrics from committed artifacts. |
| M75 | Production re-charter gate | New ADR decides whether production runtime remains deferred, becomes sibling package, or reopens constrained branch. | ADR requires sponsor, operator owner, security owner, threat model, and boundary choice. |
| M76 | Production-runtime decision package / LTS lab release package | If M75 approves, produce PRD/test-spec for production runtime; if not, produce LTS simulator-lab release plan. This milestone packages the decision, not runtime implementation permission by itself. | Either approved execution artifacts exist, or docs explicitly reaffirm deferred service scope. |

## Cross-cutting implementation guidance

- Treat M27-M46 as mandatory before any production-runtime work.
- Treat M47-M56 as mandatory before claiming production-grade performance. Phase C budgets are tied to the semantics available at the time they are captured; Phase D semantic expansion requires reviewed re-baselining rather than silent budget churn.
- Treat M67-M74 as the TUI unification spine; do not add more ad hoc one-off TUI modes outside the dashboard IA after M67.
- Treat M75-M76 as gates and decision packaging, not implementation permission.

## Verification strategy

- Always run: `zig fmt`, `git diff --check`, `zig build test --summary all`.
- Contract milestones: add golden fixtures and drift checks.
- Performance milestones: compare against M47 baseline and update budgets only through review.
- Dashboard milestones: snapshot tests across terminal tiers plus interaction tests where supported.
- Production gate milestones: docs/identity wording audit plus named owner signoff artifacts.

## ADR

### Decision
Adopt Option A: evolve `zig-scheduler` into a production-grade scheduler laboratory and dashboard first, while keeping live production automation/service scope behind a later explicit re-charter gate.

### Drivers
- ADR 0003 currently defers productionization indefinitely.
- The current codebase already has broad simulator/product surfaces that need cleanup and integration before expansion.
- Performance, verification, and dashboard IA are prerequisites to credible production-grade claims.

### Alternatives considered
- Immediate production branch: rejected because it conflicts with current governance and front-loads security/ops risk.
- Immediate sibling production package: rejected as premature before a sponsor/operator/problem statement exists.
- Cleanup-only roadmap: rejected because the user explicitly requested production-grade scheduler, performance, and dashboard evolution.

### Why chosen
This roadmap maximizes current repo value, reduces false claims, sequences risk, and preserves a credible path to production runtime only if later evidence justifies it.

### Consequences
- The next execution pass should start with docs/cleanup/test architecture, not service code.
- “Production-grade” must be qualified as lab/product quality until M75 approves a runtime branch.
- Dashboard work gets a dedicated IA spine to avoid continuing ad hoc TUI growth.

### Follow-ups
- Save dedicated test-spec artifact for this roadmap.
- If execution begins, start with M27-M32 as the first governance/cleanup/contract-boundary tranche.
- Revisit M75 only after M27-M74 produce evidence, with M32 reducing late surprise by identifying lab-only vs runtime-portable contracts early.

## Available-agent-types roster

- `explore` — repository lookup and dependency mapping.
- `planner` — milestone slicing and PRD/test-spec updates.
- `architect` — boundary design, module graph, dashboard IA, contract migration.
- `critic` / `code-reviewer` — plan and implementation review.
- `executor` — implementation/refactor work.
- `test-engineer` — test taxonomy, property/golden/snapshot/perf gates.
- `performance-reviewer` — performance budgets, profiling, benchmark interpretation.
- `security-reviewer` — M75/M76 production re-charter, threat model, trust boundaries.
- `designer` / `ux-researcher` — dashboard IA, screen flows, accessibility.
- `writer` — docs, ADRs, release notes, courseware synchronization.
- `verifier` — completion evidence and final gate validation.

## Follow-up staffing guidance

### `$ralph` path
Use Ralph for a single-owner sequence such as M27-M29 or M67 only after this plan is accepted.
- Suggested reasoning: high for architect/planner decisions, medium for executor edits, high for verifier gates.
- First slice: M27 current-truth reset + M28 docs IA + M29 build graph hygiene; include M32 if the executor will touch public contracts.
- Ralph verification: run full test suite and docs wording audit before completion.

### `$team` path
Use Team for multi-lane phases, especially M27-M36 cleanup or M67-M74 dashboard unification.
- Lane 1 (`architect`, high): module/contract boundaries.
- Lane 2 (`executor`, medium): implementation/refactor edits.
- Lane 3 (`test-engineer`, high): regression/golden/snapshot/perf tests.
- Lane 4 (`designer`, medium-high): dashboard IA and screen contracts.
- Lane 5 (`writer`, medium): docs/ADR/status updates.
- Lane 6 (`verifier`, high): integration evidence and final audit.

Launch hints:
```sh
$team "Execute M27-M32 from .omx/plans/prd-production-grade-scheduler-50-milestones.md with lanes: docs/governance, build graph, contract inventory, architecture tests, verification."
omx team --task "Execute dashboard IA milestone M67 from .omx/plans/prd-production-grade-scheduler-50-milestones.md" --workers 4
```

Team verification path:
1. Each lane reports changed files, tests, risks.
2. Integration owner runs `zig fmt`, `git diff --check`, `zig build test --summary all`.
3. Verifier audits roadmap/ADR wording for production-scope truthfulness.
4. Ralph follow-up performs final single-owner completion check if team work is broad.

## Goal-mode follow-up suggestions

- `$ultragoal` — recommended default for executing the 50-milestone roadmap as durable sequential goals.
- `$performance-goal` — recommended for Phase C (M47-M56), because success depends on measured performance budgets.
- `$autoresearch-goal` — use before M75 if production-runtime re-charter needs external scheduler/ops/security research.

## Changelog

- Initial RALPLAN draft created from repo context snapshot and current roadmap/ADR evidence.
- Architect iteration applied: added early production-boundary compatibility milestone, phase touchpoint maps, Phase C baseline semantics, M76 wording clarification, and first-slice guidance.
- Critic approval applied: status updated to consensus approved, M48 requires numeric targets before optimization, and paired test spec references a roadmap review checklist.
