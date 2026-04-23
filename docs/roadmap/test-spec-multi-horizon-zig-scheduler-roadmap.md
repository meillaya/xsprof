# Test Spec — Multi-Horizon Roadmap for zig-scheduler

## Status
Initial consensus draft for review — created 2026-04-20

## Purpose
Define milestone-by-milestone verification expectations for a 20+ milestone roadmap so future `ralph` and `$team` execution stays deterministic, bounded, and honest about scope.

## Verification baseline
Verified on 2026-04-20 / 2026-04-21:
- `zig build test --summary all` currently passes in the working tree with `21/21 tests passed`.
- README/docs still describe a simulator-only, Linux-inspired project.
- Existing approved roadmap remains a valid subset of this larger roadmap.

---

## Milestone verification matrix

## Track legend
- **Mainline core branch:** default sequential simulator roadmap after M5
- **Planning gate:** planning/approval milestone; no implementation starts until the gate is approved
- **Optional branch:** visible future work that is not mandatory mainline backlog

## Branch eligibility rule
- Before starting any milestone from `M6` onward, confirm that `M5` approved the branch identity required for that milestone.
- Before starting `M19` or `M20`, confirm `M18` approval.
- Before starting `M26`, confirm `M25` approval.

## Near-term

### M1.5 — CLI / scenario I/O / report-export polish
**Required verification**
- CLI validates exactly one scenario source.
- Canonical object-style ZON and legacy compatibility input are both covered.
- JSON export has explicit schema/version assertions.
- README/docs examples execute or match executable commands.

**Minimum checks**
- `zig build test --summary all`
- built-in run smoke
- file-path run smoke
- mutual-exclusion validation test
- repeated-run JSON equality check
- wording audit against simulator-only identity

### M2 — weighted single-core fairness semantics
**Required verification**
- Parser/schema coverage for weight input.
- Repeated-run determinism across policies.
- Direct tests for weight-aware fairness behavior.

**Minimum checks**
- `zig build test --summary all`
- weighted fixture parser tests
- CFS-like fairness regression tests
- FCFS/RR compatibility tests with weighted fixtures
- docs audit for Linux-inspired wording

### M2.5 — trace and export contract hardening
**Required verification**
- Public event taxonomy is asserted programmatically.
- Unsupported/missing version behavior is clear.

**Minimum checks**
- export golden/assertion tests
- trace-event coverage tests
- version compatibility tests
- docs/contract audit

### M3 — multicore / SMP simulation
**Required verification**
- No task executes on two cores in one tick.
- Per-core and per-task totals reconcile.
- Migration/balancing semantics are deterministic.

**Minimum checks**
- `zig build test --summary all`
- multicore determinism tests
- no-double-run invariant tests
- per-core reconciliation tests
- CLI/export smoke with core identity

### M3.5 — multicore invariant suite and fixture corpus
**Required verification**
- Fixture corpus covers representative multicore scenarios.
- Invariant suite is fast enough for normal regression use.

**Minimum checks**
- regression run on full corpus
- fixture metadata/docs audit
- single-core regression safety pass

### M4 — analysis + visualization from versioned exports only
**Required verification**
- Analysis consumes export files only.
- Generated outputs are reproducible.
- Unsupported versions fail cleanly.

**Minimum checks**
- export -> analysis smoke
- deterministic artifact regeneration check
- version rejection/gating test
- code-path audit proving no engine-internal dependency

### M4.5 — reproducible benchmark harness and baseline comparisons
**Required verification**
- Benchmark commands are reproducible.
- Results are labeled as simulator-local baselines, not Linux performance claims.

**Minimum checks**
- benchmark harness smoke
- repeatability check over fixed fixtures
- docs wording audit

### M5 — [Planning gate] identity ADR: simulator-only vs broader scheduler lab
**Required verification**
- ADR is approved and linked from roadmap/docs.
- Mainline vs optional milestones are reclassified explicitly.

**Minimum checks**
- ADR review signoff
- README/docs audit before any post-gate implementation

### M6 — [Mainline core branch] sleep / wakeup / blocked-state semantics
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Blocked/runnable transitions are deterministic.
- Metrics/trace output reflect blocked-state semantics.

**Minimum checks**
- blocked-state scenario tests
- transition invariant tests
- repeated-run determinism checks
- docs/examples audit

### M7 — [Mainline core branch] multi-burst and I/O-phase workload modeling
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Multi-phase workloads complete correctly.
- Existing single-burst scenarios remain valid or are migrated explicitly.

**Minimum checks**
- multi-burst fixture tests
- completion/metrics regression tests
- backwards-compat scenario checks

## Mid-term

### M8 — [Mainline core branch] richer fairness experiments: starvation, aging, and latency probes
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- New fairness metrics and scenarios prove the intended experiment value.
- Explanatory docs avoid overclaiming.

**Minimum checks**
- starvation/aging fixture tests
- metrics assertions
- docs audit

### M9 — [Mainline core branch] scheduling-class architecture
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Policy boundaries are explicit and regression-safe.
- Existing policies preserve behavior after refactor.

**Minimum checks**
- full regression suite
- API boundary tests where practical
- file/symbol audit for policy isolation

### M10 — [Mainline core branch] real-time / deadline-inspired experimental policies
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Deterministic behavior for RT/deadline fixtures.
- Comparisons against existing policies are reproducible.

**Minimum checks**
- RT/deadline scenario tests
- repeated-run checks
- docs wording audit

### M11 — [Mainline core branch] hierarchical / group scheduling model
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Group constraints/weights are represented and asserted.
- Policy and metrics semantics are documented.

**Minimum checks**
- parser/schema tests for groups
- engine/policy tests for group fairness
- export/trace assertions for group-aware data

### M12 — [Mainline core branch] topology-aware simulation
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Topology representation is testable and deterministic.
- Placement/migration rules are externally visible in trace/export data.

**Minimum checks**
- topology fixture tests
- placement invariant tests
- export contract checks for topology fields

### M13 — [Mainline core branch] scenario generator, shrinking, and fuzz/property-style testing
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Generated scenarios satisfy core validity constraints.
- Failures can be persisted or reduced into regression artifacts.

**Minimum checks**
- generator validity tests
- invariant/property test suite
- shrink/save regression path test

### M14 — [Mainline core branch] plugin-style scenario packs and policy extension boundary
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Extension boundary is documented and exercised.
- Core remains operable without optional packs.

**Minimum checks**
- extension loading tests or boundary tests
- docs/examples audit
- regression pass without optional extras

### M15 — [Mainline core branch] interactive TUI trace explorer
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Interactive view works on representative fixtures.
- Non-interactive fallback or export path remains available.

**Minimum checks**
- smoke test for TUI launch path
- golden/assertion coverage for at least some rendered state
- docs usability audit

### M16 — [Mainline core branch] reproducible lab notebooks / report pipeline
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- End-to-end report regeneration is deterministic.
- Inputs/outputs and regeneration steps are documented.

**Minimum checks**
- regenerate-all command smoke
- artifact diff/repeatability check
- contributor docs audit

### M17 — [Mainline core branch] scenario corpus expansion and curriculum-grade examples
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Each canonical scenario has metadata or explanation.
- Corpus supports both demos and regression use.

**Minimum checks**
- corpus integrity checks
- sample scenario smoke runs
- docs/curriculum audit

## Long-term

### M18 — [Planning gate / optional Linux-observability branch] Linux-facing observability gate
**Required verification**
- Approval exists before any ingestion implementation.
- Provenance/support policy is explicit.

**Minimum checks**
- ADR approval
- no-code-before-approval audit
- confirm future execution will re-enter `ralplan` rather than direct implementation if the gate is still unresolved

### M19 — [Optional Linux-observability branch] import real scheduler trace snapshots
**Required verification**
- Confirm `M18` approved the Linux-observability branch before implementation begins.
- Curated import formats are documented and bounded.
- Imported data is separated from native simulator fixtures.

**Minimum checks**
- import parser tests
- provenance metadata checks
- import -> analysis smoke

### M20 — [Optional Linux-observability branch] simulator-to-trace comparison / calibration layer
**Required verification**
- Confirm `M18` approved the Linux-observability branch before implementation begins.
- Comparison logic is reproducible and caveated.
- Docs/tests reject unsupported fidelity claims.

**Minimum checks**
- comparison metric tests
- fixed-input reproducibility checks
- wording audit against overclaiming

### M21 — [Optional distribution branch] simulator-first teaching surface polish
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Added teaching/demo surfaces consume stable contracts rather than engine internals.
- CLI/TUI paths remain functional, documented, and first-class.
- No browser/WASM path becomes required for ordinary local use.

**Minimum checks**
- deterministic TUI snapshot/golden smoke
- canonical-scenario walkthrough/doc audit
- contract/boundary wording audit

### M22 — [Optional library branch] library / SDK stabilization for embedders
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Public APIs are documented and versioned.
- Embedding examples work against the intended interface.

**Minimum checks**
- library/API tests
- example embedding smoke
- compatibility/docs audit

### M23 — [Optional teaching/distribution branch] packaged teaching distribution and courseware
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Exercises and walkthroughs are reproducible from committed artifacts.
- Onboarding path is documented clearly.

**Minimum checks**
- courseware/example smoke
- doc package audit
- sample instructor/student path review

### M24 — [Optional research branch] research sandbox branch for new policies / experiments
**Required verification**
- Confirm `M5` approved this branch before implementation begins.
- Unstable/stable boundary is explicit.
- Promotion path from sandbox to supported milestone is documented.

**Minimum checks**
- sandbox labeling audit
- boundary tests where applicable
- governance/docs audit

### M25 — [Planning gate / optional production branch] productionization gate: daemon / service / automation branch
**Required verification**
- Re-charter approved before implementation.
- Operational burden and split strategy are explicitly reviewed.

**Minimum checks**
- ADR approval
- no implementation before approval audit
- confirm future execution will re-enter `ralplan` rather than direct implementation if the gate is still unresolved

### M26 — [Optional production branch] scheduler-driven automation prototype
**Required verification**
- Confirm `M25` approved the production branch before implementation begins.
- Operational lifecycle, failure modes, and observability are specified.
- Branch remains clearly separate from the simulator core.

**Minimum checks**
- integration/service smoke
- lifecycle/observability tests
- repo-boundary/docs audit

---

## Cross-milestone regression expectations
- Every code-bearing milestone reruns `zig build test --summary all`.
- Existing supported scenario dialects remain tested until a later approved milestone explicitly removes compatibility.
- README and `docs/linux-mapping.md` must be reviewed at every gate and every milestone that broadens fidelity claims.
- Export/trace contract consumers must treat versioned data as the integration boundary.
- New milestone-specific invariants should become automated tests or scripted verification, not just manual observations.
- Gate milestones (`M5`, `M18`, `M25`) stop execution and require planning/approval evidence before coding resumes.

## Team verification path
For `$team` execution, dedicate one lane to verification with authority to block completion until:
1. milestone acceptance criteria are mapped to evidence,
2. required commands/tests have been run,
3. docs wording stays within the approved identity band,
4. any new contracts are documented and asserted,
5. remaining risks are recorded explicitly.
