# PRD — Sequential Milestones Roadmap for zig-scheduler

## Status
Revised draft — architect feedback incorporated on 2026-04-20

## Planning baseline
Repo facts verified on 2026-04-20:
- `docs/phase1-signoff-report.md` marks Phase 1 as acceptance-ready.
- `zig build test --summary all` currently passes with `20/20 tests passed`.
- Current implementation is simulator-only, single-core, deterministic, and supports FCFS, Round Robin, and a simplified CFS-inspired policy.
- `src/sim/scenario.zig` already supports loading scenario files by path, while `src/main.zig` currently exposes only built-in scenario names on the CLI.
- Current fixtures include both legacy line-oriented `.zon` files and object-style `.zon` examples.
- Current report output is human-readable only; there is not yet a public machine-readable export contract.
- `docs/linux-mapping.md` explicitly keeps nice weights, sleeper bonuses, SMP/per-CPU queues, cgroups/group scheduling, and kernel integration out of current scope.

## Roadmap goal
Turn the current Phase 1 simulator into a staged roadmap that:
1. finishes the obvious simulator-surface polish,
2. deepens single-core scheduling semantics before introducing multicore complexity,
3. adds SMP simulation only after the single-core model is stable,
4. layers analysis/visualization on top of stable versioned exported simulation data,
5. keeps Linux-facing work gated behind an explicit identity decision rather than allowing scope drift.

---

## RALPLAN-DR Summary

### Principles
1. **Preserve simulator identity until explicitly re-chartered.**
2. **Keep the roadmap strictly sequential: `M1.5 -> M2 -> M3 -> M4 -> optional M5`.**
3. **Freeze public input/output contracts before adding downstream consumers.**
4. **Prefer repo-local, stdlib-only, reviewable increments over speculative framework growth.**
5. **Keep documentation and CLI wording aligned with actual fidelity.**

### Decision Drivers
1. **Sequence risk:** multicore and visualization work are lower-risk after CLI/data contracts and single-core semantics stabilize.
2. **Teaching value:** the repo is strongest when each phase clearly teaches one new scheduler concept without blurring boundaries.
3. **Verification cost:** deterministic single-core behavior is much cheaper to prove than SMP behavior, so Phase 2 should freeze one semantic package before Phase 3 multiplies state-space.

### Viable Options

#### Option A — Recommended: polish -> richer single-core -> SMP -> analysis/visualization -> optional Linux-facing branch
**Pros**
- Matches current repo shape (`src/main.zig`, `src/sim/*`, `src/policies/*`, `src/tests/*`) with minimal churn.
- Uses Phase 1.5 to formalize public scenario/export contracts needed by later milestones.
- Keeps Phase 2 semantics understandable before Phase 3 introduces per-CPU queues and migration.
- Lets Phase 4 consume already-stable export formats instead of inventing them late.

**Cons**
- Visualization waits until after deeper engine work.
- Some export work in Phase 1.5 may need additive extension later for SMP-specific fields.

#### Option B — analysis/visualization immediately after Phase 1.5, then richer semantics, then SMP
**Pros**
- Faster visible/demoable artifacts.
- Could improve stakeholder communication early.

**Cons**
- Risks building charts/reports against unstable semantics and unstable data shape.
- Likely causes rework once weighted scheduling or SMP trace events arrive.
- Pulls effort away from the deeper engine changes the roadmap already anticipates.

#### Option C — Linux-facing fidelity push immediately after Phase 1.5
**Pros**
- Maximizes external marketing relevance to Linux scheduler discussions.
- Could justify early work on weights and kernel-adjacent concepts.

**Cons**
- Conflicts with the current README and `docs/linux-mapping.md` identity.
- Invites scope creep into kernel integration, real workloads, or overclaiming fidelity.
- Creates architectural pressure before the simulator core is mature.

### Chosen sequence
**Option A wins** because it respects the current repo contract, minimizes rework, and creates the cleanest dependency chain:
- **M1.5** freezes public CLI/scenario/export surfaces,
- **M2** freezes one richer single-core semantic package,
- **M3** extends those semantics into SMP,
- **M4** analyzes only the stable versioned export contract,
- **M5** remains explicitly optional and identity-gated.

---

## ADR Snapshot

### Decision
Adopt a strictly sequential simulator roadmap: `M1.5 -> M2 -> M3 -> M4 -> optional M5`.

### Drivers
- Existing Phase 1 simulator is green and should be extended rather than re-architected.
- `docs/linux-mapping.md` already documents omitted features that naturally map to later milestones.
- The current CLI/output surface is the narrowest bottleneck blocking richer scenario I/O and later analysis.

### Alternatives considered
- Pull visualization earlier for faster demos.
- Keep M2 as an open menu of possible semantics.
- Start Linux-facing work as the next milestone.

### Why this decision
It keeps each milestone reviewable, testable, and consistent with the repo’s current simulator-only promise while preserving a clean handoff path for `ralph` or `team` execution.

### Consequences
- Early milestones bias toward interface/data-contract cleanup rather than headline features.
- M2 is now intentionally narrower: one concrete semantic package instead of multiple candidate directions.
- M4 is contract-bound: analysis consumes versioned exports only, not engine internals.
- Any Linux-facing move requires an explicit docs/identity decision first.

### Follow-ups
- M1.5 must define the public scenario/export contract precisely enough that M4 can rely on it.
- M3 may extend export payloads additively, but only within the versioning rules established in M1.5.

---

## Public-contract decisions frozen by this roadmap

### M1.5 contract decisions
1. **CLI argument contract**
   - Built-in scenarios remain selectable by name via `--scenario <builtin-name>`.
   - Direct file input becomes a separate public flag: `--scenario-file <path>`.
   - `--scenario` and `--scenario-file` are mutually exclusive.
   - Any existing positional/built-in workflow may remain as a compatibility affordance, but the documented contract for roadmap work is the explicit flag pair above.

2. **Scenario source resolution contract**
   - CLI resolution is a distinct concern from parsing and rendering.
   - Resolution order is explicit: parse CLI args -> choose exactly one source (`builtin` or `file`) -> load scenario -> run engine -> produce report/export.
   - No heuristic “guess whether the token is a name or a path” behavior is added.

3. **Canonical scenario-file dialect**
   - The canonical external scenario-file dialect becomes **object-style ZON** (`.{ .name = ..., .quantum = ..., .tasks = ... }`).
   - Current mixed fixtures are handled by a transition rule:
     - object-style `.zon` is the canonical documented/write-target format,
     - legacy line-oriented `.zon` remains accepted as a backward-compatible read format during roadmap execution,
     - legacy fixtures are retained as compatibility coverage until an explicit cleanup milestone removes them.
   - New or migrated examples added after M1.5 should use canonical object-style ZON unless a compatibility test explicitly needs the legacy dialect.

4. **Machine-readable export contract**
   - M1.5 freezes a **single machine-readable export target** first: versioned JSON export.
   - Human-readable terminal reporting remains separate and is not itself the machine-readable contract.
   - Export payloads must include an explicit top-level schema/version marker, e.g. a contract equivalent to `schema = "zig-scheduler/report"` and `version = 1`.
   - Stability means consumers can rely on version `1`; it does **not** mean the format can never evolve.
   - Additive, backward-compatible fields may be introduced within the same version policy; breaking changes require a new version and explicit consumer update planning.

5. **Layer separation**
   - The roadmap distinguishes four responsibilities that should stay separable in code and docs:
     1. CLI argument contract,
     2. scenario source resolution/loading,
     3. versioned report/export data model,
     4. human renderer / terminal presentation.
   - M4 may depend on item 3 only; it must not depend on item 4 or on engine-private structures.

### M2 semantic package decision
M2 is narrowed to **weighted single-core fairness** as the sole semantic package for that milestone:
- add a per-task weight/nice-style input to the scenario model,
- deepen the CFS-inspired policy around deterministic weight-aware fairness on a single CPU,
- keep FCFS and Round Robin valid under the expanded scenario contract,
- defer sleep/wakeup, multi-burst behavior, and interactive/I/O-state modeling to later work rather than bundling them into M2.

This package is the most repo-realistic next step because it maps cleanly to the repo’s existing CFS-inspired policy and `docs/linux-mapping.md` omissions without forcing a larger state-machine redesign before M3.

---

## Sequential milestone plan

### M1.5 — CLI / scenario I/O / report-export polish
**Goal**
Make the simulator easier to drive and easier to consume by formalizing public scenario-file input and a versioned machine-readable export surface without changing simulator identity or scheduler semantics.

**Scope**
- Extend the CLI in `src/main.zig` from built-in-name-only workflow to the explicit public contract:
  - `--scenario <builtin-name>` for built-ins,
  - `--scenario-file <path>` for direct file input,
  - mutual exclusivity between the two.
- Keep CLI argument parsing, scenario source resolution, report/export modeling, and human rendering as distinct documented concerns.
- Freeze object-style ZON as the canonical scenario-file dialect.
- Preserve backward-compatible read support for current legacy line-oriented fixtures while documenting them as compatibility format, not the forward-looking canonical dialect.
- Introduce a single versioned JSON export contract for machine-readable output while preserving the current human-readable report path.
- Update docs and examples to show built-in scenario use, file-path scenario use, canonical object-style scenario files, and export invocation.
- Add fixture-driven smoke coverage that exercises file-path loading via the public CLI.

**Non-goals**
- No scheduler semantic changes.
- No SMP behavior.
- No GUI, browser app, or interactive TUI.
- No Linux integration.
- No second machine-readable export target in this milestone.

**Likely files / areas**
- `src/main.zig`
- `src/cli/*`
- `src/sim/scenario.zig`
- `src/root.zig`
- `src/tests/cli_smoke_test.zig`
- `src/tests/scenario_test.zig`
- `src/tests/scenarios_test.zig`
- `README.md`
- `docs/phase1-simulator.md`
- `docs/phase1-verification-checklist.md`
- `scenarios/basic/*`

**Acceptance criteria**
- Public CLI supports `--scenario <builtin-name>` and `--scenario-file <path>` as the documented entrypoints, with mutual-exclusion validation.
- Canonical scenario-file documentation points to object-style ZON, while legacy line-oriented fixtures remain readable and explicitly documented as backward-compatible input.
- The versioned JSON export contract is documented, deterministic, and suitable for later M4 consumption.
- Export stability is defined by explicit versioning rules rather than by claiming the format will never change.
- Existing Phase 1 report sections remain available in human-readable output.
- README quick-start examples include at least one built-in scenario run, one file-path scenario run, and one machine-readable export example.

**Verification commands / checks**
- `zig build test --summary all`
- CLI smoke for built-in path (current behavior remains green).
- CLI smoke for file-path scenario input against `scenarios/basic/short-vs-long.zon` or its canonical migrated equivalent.
- Contract test that export output includes the expected schema/version fields.
- Repeated-run check that versioned machine-readable export remains deterministic across repeated runs on the same scenario/policy.
- Compatibility tests covering both canonical object-style ZON and legacy line-oriented fixtures.
- Docs review: wording still says simulator-only / Linux-inspired.

**Dependencies**
- Depends only on the current Phase 1 green baseline.

**Preferred execution mode**
- **ralph** if handled as a focused single-owner contract pass.
- **team** only if splitting CLI, export, and docs/tests lanes in parallel after the contract above is accepted.

**Recommended team-parallel lanes inside M1.5**
- Lane A: CLI argument contract and source-resolution wiring.
- Lane B: versioned export model and deterministic contract tests.
- Lane C: canonical-vs-legacy scenario-format docs, compatibility tests, and example refresh.

---

### M2 — weighted single-core fairness semantics
**Goal**
Deepen the simulator’s single-core teaching value by adding one concrete semantic package: deterministic weight-aware fairness on a single CPU.

**Scope**
- Extend the scenario model so tasks can carry a weight/nice-style fairness input in addition to arrival and burst data.
- Deepen the simplified CFS-inspired policy into a clearer deterministic weighted-fairness model.
- Keep FCFS and Round Robin valid under the expanded scenario format, even if they ignore the new weight field.
- Expand docs to clearly distinguish “still simplified” from Linux while explaining how the weight input influences fairness outcomes.
- Keep the milestone intentionally narrow: no sleep/wakeup, no multi-burst workloads, no new blocked/runnable lifecycle beyond the existing single-burst model.

**Non-goals**
- No per-CPU queues.
- No task migration.
- No sleep/wakeup semantics.
- No multi-burst or I/O-blocking model.
- No cgroups/group scheduling yet.

**Likely files / areas**
- `src/sim/types.zig`
- `src/sim/scenario.zig`
- `src/sim/engine.zig`
- `src/sim/trace.zig`
- `src/sim/metrics.zig`
- `src/policies/fcfs.zig`
- `src/policies/round_robin.zig`
- `src/policies/cfs_like.zig`
- `src/tests/policies_test.zig`
- `src/tests/scenario_test.zig`
- `src/tests/scenarios_test.zig`
- `src/tests/simulator_test.zig`
- `README.md`
- `docs/phase1-simulator.md` (or successor semantics doc)
- `docs/linux-mapping.md`
- `scenarios/basic/*` plus new weighted single-core fixtures

**Acceptance criteria**
- A documented weighted single-core semantic contract exists and is tested.
- The scenario format can represent task weights in a way that remains compatible with M1.5’s canonical file contract.
- The CFS-inspired policy demonstrates deterministic weight-aware fairness that is meaningfully richer than Phase 1.
- FCFS and Round Robin still run correctly against scenarios containing the weight field.
- Determinism is preserved across repeated runs.
- Existing Phase 1 scenarios continue to work or receive an explicit documented migration path if fixture normalization is performed.

**Verification commands / checks**
- `zig build test --summary all`
- Exact tests for the weighted single-core contract, including parser/schema coverage for task weights.
- Repeated-run determinism checks for at least one weighted scenario under each policy.
- Regression checks for current golden scenarios or their documented migrated equivalents.
- Docs review against `docs/linux-mapping.md` wording guardrails.

**Dependencies**
- Requires M1.5 scenario/export contract to be in place first.

**Preferred execution mode**
- **ralph** if the weighted package stays tightly scoped.
- **team** if scenario-schema, policy, and docs/test lanes are split in parallel after the package above is frozen.

**Recommended team-parallel lanes inside M2**
- Lane A: scenario/type/schema evolution for weight input.
- Lane B: engine/metrics/trace updates needed for deterministic weighted fairness.
- Lane C: policy adjustments plus golden/invariant tests.
- Lane D: docs mapping and migration notes.

---

### M3 — multicore / SMP simulation
**Goal**
Add deterministic multicore simulation so the repo can teach per-CPU queues, migration pressure, and load-balancing tradeoffs without changing its simulator-only identity.

**Scope**
- Introduce an explicit CPU/core topology model for simulation.
- Add per-CPU runnable state and deterministic core-selection rules.
- Define migration/load-balancing semantics at a simulator level.
- Extend the versioned export payload and trace/metrics surfaces to show CPU/core affinity, migration, and multicore utilization behavior.
- Update policy behavior for SMP-aware selection where appropriate.
- Add multicore scenario fixtures and docs that explain what is and is not Linux-faithful.

**Non-goals**
- No real parallel execution.
- No kernel scheduler-class interoperability.
- No NUMA, cgroups, or real-time class modeling unless explicitly split into a later milestone.
- No attempt to mimic exact Linux scheduler internals.

**Likely files / areas**
- `src/sim/types.zig`
- `src/sim/engine.zig`
- `src/sim/trace.zig`
- `src/sim/metrics.zig`
- `src/policies/*`
- `src/cli/output.zig`
- `src/tests/policies_test.zig`
- `src/tests/scenarios_test.zig`
- `src/tests/simulator_test.zig`
- `README.md`
- `docs/linux-mapping.md`
- new SMP-focused docs under `docs/*`
- new multicore scenario fixtures under `scenarios/*`

**Acceptance criteria**
- Simulator can execute at least one deterministic multicore fixture and report per-core activity.
- Versioned exported data clearly identifies core assignment and migration.
- Single-core mode remains supported and regression-safe.
- Documentation explicitly explains SMP/per-CPU queue simplifications vs Linux.
- Multicore balancing behavior is deterministic and test-covered.

**Verification commands / checks**
- `zig build test --summary all`
- Deterministic multicore fixture tests with repeated-run equivalence.
- Invariant tests that no task can run on two cores in the same tick.
- Invariant tests that the sum of per-core executed ticks matches each task’s total executed ticks and the scenario’s total executed work.
- Regression test ensuring M1.5/M2 single-core fixtures still pass unchanged or via documented migration.
- CLI/export smoke showing multicore-specific fields in both human-readable and versioned machine-readable output.
- Docs review for SMP terminology and boundary wording.

**Dependencies**
- Requires M2 weighted single-core semantics first.

**Preferred execution mode**
- **team** by default; this milestone naturally spans engine, policy, trace/export, docs, and test lanes.

**Recommended team-parallel lanes inside M3**
- Lane A: core/topology + engine runtime data structures.
- Lane B: SMP-aware policy behavior and balancing rules.
- Lane C: export/trace/metrics contract extensions and invariants.
- Lane D: scenario fixtures, regression tests, and docs.

---

### M4 — analysis + visualization from versioned exports only
**Goal**
Turn the stable simulation/export surfaces from M1.5–M3 into comparison, analysis, and visualization artifacts that make policy behavior easier to inspect across scenarios without coupling analysis to engine internals.

**Scope**
- Add analysis/reporting surfaces that compare policies and/or scenarios using only the versioned export contract established in M1.5 and extended compatibly through M3.
- Add deterministic visualization outputs appropriate for a repo-first workflow (for example: structured tables, ASCII timelines, or generated static artifacts) without assuming a GUI.
- Expand aggregate metrics and comparison docs only where backed by versioned exported data.
- Add workflow examples that show how to generate analysis artifacts from built-in and custom scenarios through exports, not by linking directly to engine-private data structures.

**Non-goals**
- No live dashboard requirement.
- No web app unless separately approved.
- No Linux-facing instrumentation.
- No direct consumption of engine internals, trace internals, or unversioned in-process structures by analysis code.

**Likely files / areas**
- `src/cli/*`
- `src/main.zig`
- analysis/visualization code under `src/*` or `tools/*` as chosen later
- `src/tests/cli_smoke_test.zig`
- `src/tests/scenarios_test.zig`
- `README.md`
- analysis/visualization docs under `docs/*`
- exported example artifacts if the repo chooses to check them in

**Acceptance criteria**
- At least one stable analysis workflow compares multiple policies or scenarios from versioned exported data.
- At least one deterministic visualization artifact can be reproduced from repo fixtures.
- Analysis code consumes only the versioned export contract, not engine internals or ad hoc in-memory structures.
- Docs explain how to generate and interpret the new analysis outputs.

**Verification commands / checks**
- `zig build test --summary all`
- Reproducibility checks for generated analysis/visualization artifacts.
- CLI smoke covering export generation plus comparison/report generation from those exports.
- Contract tests proving the analysis path rejects or gates unsupported export versions.
- Manual review that visualization wording still respects simulator-only identity.

**Dependencies**
- **Strictly requires the versioned export contract from M1.5.**
- Follows M3 in the primary sequence so analysis can target the fuller single-core + SMP export surface.

**Preferred execution mode**
- **team** if analysis and rendering/report lanes can run in parallel.
- **ralph** is acceptable only if the visualization surface is intentionally narrow.

**Recommended team-parallel lanes inside M4**
- Lane A: export-driven comparison/analysis computation.
- Lane B: deterministic visualization/rendering format.
- Lane C: CLI UX/examples/docs and reproducibility/contract-version tests.

---

### M5-optional — Linux-facing work only after an explicit identity-change decision
**Goal**
Keep any Linux-facing expansion behind a conscious product/identity decision rather than letting it leak into the simulator roadmap by accident.

**Scope**
- First, create an explicit decision record stating whether the project remains a simulator/teaching tool or becomes Linux-facing in a stronger sense.
- If and only if the identity changes, scope a new phase for Linux-adjacent work such as workload replay, observability import/export, or stronger Linux-semantic mapping.
- Rename docs/README claims as needed before implementing Linux-facing features.

**Non-goals**
- Not part of the default roadmap.
- No kernel integration by default.
- No production/system tool claims without a new charter.

**Likely files / areas**
- `README.md`
- `docs/linux-mapping.md`
- new ADR/phase docs under `docs/*`
- only later, any implementation areas explicitly approved by that decision

**Acceptance criteria**
- A documented go/no-go identity decision exists before code work starts.
- If the answer is “stay simulator-only,” this milestone closes with no implementation work.
- If the answer is “change identity,” a new milestone plan supersedes this roadmap from that point onward.

**Verification commands / checks**
- Architect/product review of the identity ADR.
- README/docs wording audit.
- No implementation work begins until the ADR is approved.

**Dependencies**
- Intentionally deferred until M1.5–M4 are complete or intentionally pre-empted by a conscious re-charter.

**Preferred execution mode**
- **ralph** for the decision/ADR.
- **team** only if a later approved Linux-facing implementation phase is separately planned.

---

## Where team can parallelize without breaking sequence
Team use is best **inside** milestones, not **across** them.

Allowed parallelism:
- M1.5: CLI argument work, versioned export work, and docs/compatibility tests can run in parallel once the contract above is accepted.
- M2: scenario-schema work, weighted-fairness engine/policy work, and docs/test work can run in parallel once the weighted package is frozen.
- M3: engine topology, policy balancing, and export/test/docs lanes can run in parallel after the SMP contract is chosen.
- M4: export-driven analysis computation, rendering, and docs/example lanes can run in parallel after the artifact format is chosen.

Disallowed parallelism:
- Do **not** start M2 before M1.5 stabilizes public scenario/export contracts.
- Do **not** start M3 before M2 stabilizes weighted single-core semantics.
- Do **not** start M4 before M1.5’s versioned export surface exists; the primary path still keeps M4 after M3.
- Do **not** start Linux-facing implementation work unless M5’s identity gate is explicitly approved.

---

## Risks
1. **Export-contract churn risk**
   - If M1.5 ships a weak machine-readable contract, M4 will re-open it.
   - Mitigation: define explicit schema/version rules and keep analysis bound to that contract.

2. **Fixture-format migration risk**
   - Current mixed fixture dialects can create confusion if the canonical dialect is not frozen.
   - Mitigation: pick object-style ZON as canonical now and keep legacy line-oriented fixtures only as compatibility coverage.

3. **SMP state explosion risk**
   - Multicore scheduling multiplies trace volume, invariants, and failure modes.
   - Mitigation: enter M3 only after M2 determinism is strong and single-core regressions are frozen.

4. **Identity drift risk**
   - Linux-facing language can drift ahead of implementation reality.
   - Mitigation: keep README/docs wording audits as part of every milestone and preserve `docs/linux-mapping.md` guardrails.

5. **Docs lag risk**
   - The repo’s educational value depends on docs keeping up with semantics.
   - Mitigation: every milestone includes explicit docs acceptance and should reserve a docs lane in team mode.

---

## Sequencing rationale
- **M1.5 first** because the repo already has internal file loading in `src/sim/scenario.zig`; the next high-leverage step is exposing that capability cleanly on the public CLI and freezing a versioned export contract.
- **M2 second** because weighted single-core fairness is the most repo-realistic next step for the current CFS-inspired path without forcing a larger task-state redesign first.
- **M3 third** because SMP should extend an already-stable semantic model, not define it.
- **M4 fourth** because analysis/visualization must consume stable versioned exported data rather than forcing premature or private data-shape commitments.
- **M5 optional** because Linux-facing work is a strategic fork, not the default continuation of the current simulator identity.
