# PRD — Multi-Horizon Roadmap for zig-scheduler

## Status
Initial consensus draft for review — created 2026-04-20

## Planning baseline
Repo facts verified on 2026-04-20 / 2026-04-21:
- `README.md` and `docs/linux-mapping.md` still define the project as a deterministic, user-space, educational scheduler simulator rather than a kernel-faithful or production scheduler.
- The existing approved roadmap already freezes a short sequential spine through `M1.5 -> M2 -> M3 -> M4 -> optional M5`.
- The working tree currently contains an uncommitted M1.5-style CLI/scenario/export pass and `zig build test --summary all` passes with `21/21 tests passed`.
- The current simulator already has FCFS, Round Robin, and a simplified CFS-inspired policy, deterministic traces, scenario loading, and docs explaining Linux-inspired scope boundaries.
- `docs/linux-mapping.md` explicitly keeps nice weights, sleeper bonuses, SMP fidelity, cgroups, kernel integration, and daemon/service behavior out of current scope.

## Roadmap goal
Turn zig-scheduler from a good Phase-1 teaching simulator into a long-horizon scheduler laboratory roadmap with a **clear spine plus explicit optional branches**:
1. finish and harden the simulator contract,
2. deepen scheduler semantics in bounded stages,
3. grow from single-core to richer topology and workload modeling,
4. add reproducible analysis / visualization / teaching surfaces,
5. gate any Linux-facing, productized, or production-like identity changes behind explicit ADR decisions,
6. keep every milestone concrete enough for later `ralph` or `$team` execution.

---

## RALPLAN-DR Summary

### Principles
1. **Protect truthful identity.** The repo should remain explicit about what is simulated, what is Linux-inspired, and what is still out of scope.
2. **Advance one state-space jump at a time.** Freeze contracts before adding downstream consumers or multiplying scheduler complexity.
3. **Prefer executable proof over aspirational scope.** Each milestone must be bounded, testable, and reviewable in-repo.
4. **Use gates for identity changes.** Linux-facing, external-data, packaging, and production-ish branches need explicit approval boundaries.
5. **Keep the spine sequential; allow optional branches only when their dependencies are satisfied.**

### Decision Drivers
1. **State-space growth:** scheduler projects become untestable when semantics, topology, workloads, UX, and external integrations are expanded simultaneously.
2. **Teaching value:** the repo is strongest when each milestone teaches one new scheduling concept clearly.
3. **Execution fit:** the roadmap must be runnable by `ralph` for bounded milestones or by `$team` when parallel lanes are obvious and safe.

### Viable Options

#### Option A — Recommended: one long sequential spine with explicit optional branches and gates
**Pros**
- Fits the existing approved roadmap naturally.
- Lets `ralph` own small/medium milestones and `$team` own larger multi-lane expansions.
- Makes out-of-scope futures visible without forcing them into near-term work.

**Cons**
- Longer document with more gates to maintain.
- Some long-term milestones may remain dormant for a while.

#### Option B — Split into separate roadmaps now (core simulator vs Linux lab vs teaching/product)
**Pros**
- Cleaner separation of audiences.
- Avoids one long list.

**Cons**
- Premature for the current repo size.
- Risks duplicated milestones and inconsistent prerequisites.
- Harder for future `ralph`/`team` execution to know which spine owns the next step.

#### Option C — Keep only a near-term roadmap and defer all long-term thinking
**Pros**
- Lowest planning effort.
- Minimizes speculative detail.

**Cons**
- Fails the user request.
- Makes later identity decisions ad hoc.
- Hides major architecture pivots that would affect earlier contract choices.

### Chosen direction
**Option A wins.** Keep a single multi-horizon PRD with:
- a **core spine** for near-term and mid-term simulator evolution,
- **decision gates** before higher-risk identity changes,
- **optional long-term branches** for Linux-facing, productized, and teaching/distribution outcomes.

---

## ADR Snapshot

### Decision
Adopt a 29-milestone multi-horizon roadmap with a sequential core spine and explicit gates for Linux-facing, external-data, packaging, and production-like branches.

### Drivers
- Existing roadmap already establishes a disciplined sequential style that should be preserved.
- The repo has enough shape now to benefit from a broader roadmap, but not enough maturity to blur all futures together.
- Long-term optional goals matter, yet they should not distort the current simulator-only truth.

### Alternatives considered
- Multiple disconnected roadmaps.
- Near-term-only planning.
- Immediate Linux-facing expansion after current simulator polish.

### Why this decision
It gives future execution modes a concrete backlog while still preventing scope drift across identity boundaries.

### Consequences
- Some milestones are intentionally gated and may never be executed.
- Docs and ADR checkpoints become first-class deliverables rather than afterthoughts.
- The roadmap stays useful both for conservative simulator work and for later ambitious branches.

### Follow-ups
- Revalidate milestone ordering at each gate.
- Keep the test spec synchronized whenever milestones are inserted, merged, or retired.

---

## Major gates that future execution must respect

### G1 — Contract stabilization gate
Before starting M4, the CLI, scenario dialect, trace taxonomy, and export contracts must be intentionally stable enough for downstream consumers. In practice, M2.5 is the milestone that satisfies this gate.

### G2 — Identity gate
Before M5 and any milestone that broadens the repo beyond “educational deterministic simulator,” require an explicit ADR that says whether the project remains simulator-only, becomes a broader scheduler lab, or grows Linux-facing branches.

### G3 — External evidence gate
Any branch that ingests real Linux traces, kernel data, or benchmark corpora from outside the repo must first pass the approval event defined by M18. M18 is the planning gate for this branch, not a downstream consumer of an earlier gate.

### G4 — Productionization gate
Any daemon/service/agent/automation branch must first pass the re-charter defined by M25. M25 is the planning gate for this branch, not a downstream consumer of an earlier gate.

---

## Horizon overview

### Near-term horizon
Finish simulator contract stabilization, richer semantics, multicore support, and first analysis surfaces.

### Mid-term horizon
Deepen workload realism, extensibility, topology modeling, and reproducible experimentation while staying simulator-first.

### Long-term horizon
Explore optional branches: Linux-facing observability, calibration, distribution, teaching products, and production-like orchestration — all explicitly gated.

## Track classification after M5 (approved by `docs/adr/0001-m5-project-identity.md`)
- **Mainline core branch:** `M6 -> M17`
- **Planning gates:** `M5`, `M18`, `M25`
- **Optional Linux-observability branch:** `M19 -> M20` after `M18` approval
- **Optional distribution / teaching branch:** `M21 -> M23` after core export-analysis maturity
- **Optional library branch:** `M22` when embedding/API goals justify it
- **Optional research branch:** `M24` once policy/testing boundaries are mature
- **Optional production branch:** `M26` only after `M25` re-charter

Future executors should treat the optional branches as **branch tracks**, not as mandatory serialized backlog after the core spine. `M5` is the identity/eligibility gate for all post-Phase-1 branch work; `M18` and `M25` add narrower gate checks for Linux-observability and productionization.

---

## Sequential multi-horizon milestone plan

## Near-term milestones

### M1.5 — CLI / scenario I/O / report-export polish
**Goal**
Finish stabilizing the public run contract already underway in the working tree.

**Acceptance criteria**
- `--scenario` and `--scenario-file` are the explicit documented run inputs and remain mutually exclusive.
- Object-style ZON is the canonical scenario dialect; legacy line-oriented input remains compatibility-only.
- Versioned JSON export is documented and deterministic.
- README/docs/examples align with actual CLI behavior.

**Dependencies**
- Current Phase 1 baseline only.

**Preferred execution mode**
- `ralph`.

### M2 — weighted single-core fairness semantics
**Goal**
Add deterministic weight-aware fairness on a single CPU.

**Acceptance criteria**
- Scenario model accepts a weight/nice-style field.
- CFS-like policy becomes meaningfully weight-aware.
- FCFS and RR remain valid under the expanded contract.
- Docs explain where the model is still simpler than Linux.

**Dependencies**
- M1.5.

**Preferred execution mode**
- `ralph` or small `$team`.

### M2.5 — trace and export contract hardening
**Goal**
Freeze the event taxonomy and export shape needed for richer later milestones.

**Acceptance criteria**
- Trace event kinds and exported fields are documented as public contract.
- Event/version compatibility rules exist.
- Later analysis consumers can depend on export stability rather than engine internals.

**Dependencies**
- M2.

**Preferred execution mode**
- `ralph`.

### M3 — multicore / SMP simulation
**Goal**
Extend the simulator from single-core scheduling to deterministic multicore behavior.

**Acceptance criteria**
- Core identity exists in the simulation state and exported traces.
- No task can execute on two cores in the same tick.
- Migration / balancing semantics are explicit and deterministic.
- Docs clearly bound SMP simplifications.

**Dependencies**
- M2.5.

**Preferred execution mode**
- `$team`.

### M3.5 — multicore invariant suite and fixture corpus
**Goal**
Strengthen proof, not features, for the new multicore state space.

**Acceptance criteria**
- A committed fixture corpus exists for key multicore patterns.
- Invariant tests cover no-double-run, work conservation, and per-core totals.
- Regression coverage distinguishes single-core and multicore guarantees.

**Dependencies**
- M3.

**Preferred execution mode**
- `ralph`.

### M4 — analysis + visualization from versioned exports only
**Goal**
Add reproducible analysis artifacts that consume the versioned export contract only.

**Acceptance criteria**
- Analysis tooling reads exported JSON rather than engine internals.
- At least one deterministic chart/report path exists.
- Unsupported export versions fail clearly.

**Dependencies**
- M2.5 and M3.5.

**Preferred execution mode**
- `$team`.

### M4.5 — reproducible benchmark harness and baseline comparisons
**Goal**
Add a controlled benchmark layer for simulator policies and fixtures.

**Acceptance criteria**
- A repeatable harness measures run cost and/or output size over representative fixtures.
- Baselines are documented and reproducible.
- Benchmark output is explicitly simulator-local, not a Linux performance claim.

**Dependencies**
- M4.

**Preferred execution mode**
- `ralph` or `$team`.

### M5 — [Planning gate] identity ADR: simulator-only vs broader scheduler lab
**Goal**
Make the first explicit charter decision before the roadmap leaves pure simulator hardening.

**Acceptance criteria**
- A written ADR decides whether the project remains simulator-only, becomes a broader scheduler laboratory, or opens explicit external-facing branches.
- README/docs language is updated if identity changes.
- Downstream milestones are re-labeled as mainline or optional based on the decision.

**Dependencies**
- M4.5.

**Preferred execution mode**
- `ralph` planning/doc lane or architect-led `$team`.

**Approved outcome**
- ADR `docs/adr/0001-m5-project-identity.md` approves a broader scheduler laboratory roadmap with a simulator-only mainline and explicitly gated optional branches.

### M6 — [Mainline core branch] sleep / wakeup / blocked-state semantics
**Goal**
Move beyond arrival-only workloads into explicit runnable/blocked transitions.

**Acceptance criteria**
- Scenario model can express sleep/wakeup transitions deterministically.
- Trace and metrics account for blocked states.
- Docs clearly separate educational model from Linux wakeup complexity.

**Dependencies**
- M5 approval.

**Preferred execution mode**
- `$team`.

### M7 — [Mainline core branch] multi-burst and I/O-phase workload modeling
**Goal**
Represent alternating CPU and wait phases for the same task.

**Acceptance criteria**
- Scenario format supports multi-phase workloads.
- Engine and metrics handle multi-burst completion correctly.
- Existing single-burst fixtures still work or have a documented migration.

**Dependencies**
- M6.

**Preferred execution mode**
- `$team`.

## Mid-term milestones

### M8 — [Mainline core branch] richer fairness experiments: starvation, aging, and latency probes
**Goal**
Add explicit fairness/latency experiment fixtures and metrics across policies.

**Acceptance criteria**
- Scenario/test corpus includes starvation-prone and latency-sensitive workloads.
- Metrics and docs explain fairness tradeoffs clearly.
- Educational claims stay evidence-based.

**Dependencies**
- M7.

**Preferred execution mode**
- `ralph`.

### M9 — [Mainline core branch] scheduling-class architecture
**Goal**
Refactor policy handling so multiple policy families can coexist cleanly.

**Acceptance criteria**
- Policy API/module boundaries are explicit.
- New policies can be added without tangling engine core.
- Existing policies are migrated without changing semantics.

**Dependencies**
- M7.

**Preferred execution mode**
- `$team`.

### M10 — [Mainline core branch] real-time / deadline-inspired experimental policies
**Goal**
Add bounded experimental scheduling classes beyond fair/time-sliced baselines.

**Acceptance criteria**
- At least one deterministic RT/deadline-style teaching policy exists.
- Docs clearly avoid overclaiming Linux fidelity.
- Cross-policy comparisons are reproducible.

**Dependencies**
- M9 and M5 approval.

**Preferred execution mode**
- `ralph` or `$team`.

### M11 — [Mainline core branch] hierarchical / group scheduling model
**Goal**
Introduce group-level scheduling ideas analogous to cgroups/group fairness in a simulator-safe way.

**Acceptance criteria**
- Scenario model can express group membership and group weights/quotas.
- Engine/policy semantics for group scheduling are deterministic.
- Docs explain analogies vs omissions.

**Dependencies**
- M9 and M5 approval.

**Preferred execution mode**
- `$team`.

### M12 — [Mainline core branch] topology-aware simulation (NUMA/cache-domain aware simplifications)
**Goal**
Expand multicore modeling to simple topology concepts without pretending kernel fidelity.

**Acceptance criteria**
- Scenario/topology input can represent at least one higher-level topology distinction.
- Placement/migration rules are explicit and testable.
- Export surface captures topology-relevant events.

**Dependencies**
- M3.5 and M9.

**Preferred execution mode**
- `$team`.

### M13 — [Mainline core branch] scenario generator, shrinking, and fuzz/property-style testing
**Goal**
Systematically increase confidence in scheduler invariants.

**Acceptance criteria**
- There is a generator path for valid deterministic scenarios.
- Failures can be reduced or saved as regression fixtures.
- Property/invariant tests cover engine and export guarantees.

**Dependencies**
- M9 and M5 approval.

**Preferred execution mode**
- `ralph` or `$team`.

### M14 — [Mainline core branch] plugin-style scenario packs and policy extension boundary
**Goal**
Define a stable extension boundary for adding scenarios/policies without core rewrites.

**Acceptance criteria**
- Scenario pack layout or registry conventions exist.
- Policy extension boundary is documented and tested.
- Core package remains reviewable and not dependency-heavy.

**Dependencies**
- M9 and M13.

**Preferred execution mode**
- `$team`.

### M15 — [Mainline core branch] interactive TUI trace explorer
**Goal**
Add a local interactive teaching surface for stepping through traces.

**Acceptance criteria**
- A deterministic local TUI can inspect scenario runs and traces.
- It consumes exported/internal report models without rewriting engine semantics.
- Accessibility and non-interactive fallback behavior are documented.

**Dependencies**
- M4 and M5 approval.

**Preferred execution mode**
- `$team`.

### M16 — [Mainline core branch] reproducible lab notebooks / report pipeline
**Goal**
Make it easy to generate repeatable teaching or research artifacts from fixtures.

**Acceptance criteria**
- One command/path can regenerate chosen reports from committed fixtures.
- Analysis assets are versioned or regenerated deterministically.
- The pipeline is documented for future contributors.

**Dependencies**
- M4.5 and M5 approval.

**Preferred execution mode**
- `ralph`.

### M17 — [Mainline core branch] scenario corpus expansion and curriculum-grade examples
**Goal**
Build a richer canon of pedagogically useful workloads.

**Acceptance criteria**
- Scenario packs cover convoy effects, starvation, bursty I/O, balancing, and topology examples.
- Every canonical scenario has explanation docs or metadata.
- The corpus supports both manual demos and automated tests.

**Dependencies**
- M16 and M5 approval.

**Preferred execution mode**
- `ralph` or docs-heavy `$team`.

## Long-term milestones

### M18 — [Planning gate / optional Linux-observability branch] Linux-facing observability gate
**Goal**
Decide whether the repo may ingest or reference real Linux scheduler traces/data.

**Acceptance criteria**
- ADR covers provenance, support burden, privacy/safety, and scope wording.
- No ingestion code starts before this decision is approved.

**Dependencies**
- M5 identity alignment.

**Execution note**
- This milestone is itself the approval event for the optional Linux-observability branch.

**Preferred execution mode**
- planning/architect lane.

**Approved outcome**
- `docs/adr/0002-m18-linux-observability-gate.md` approves only an
  **offline, observability-only, version-pinned snapshot-fixture path**.
- M19 remains blocked until milestone-specific PRD/test-spec artifacts exist.

### M19 — [Optional Linux-observability branch] import real scheduler trace snapshots (observability-only)
**Goal**
Allow optional import of curated real-world traces for comparison, without claiming replay fidelity.

**Acceptance criteria**
- Import path is clearly labeled observability-only.
- Provenance and supported formats are documented.
- Imported data is separated from simulator-native fixtures.

**Dependencies**
- M18.

**Preferred execution mode**
- `$team`.

### M20 — [Optional Linux-observability branch] simulator-to-trace comparison / calibration layer
**Goal**
Compare simulated behavior with imported traces as an educational calibration exercise.

**Acceptance criteria**
- Comparison metrics and caveats are explicit.
- Unsupported fidelity claims are rejected in docs/tests.
- Results remain reproducible from committed inputs.

**Dependencies**
- M19.

**Preferred execution mode**
- `$team`.

### M21 — [Optional distribution branch] simulator-first teaching surface polish
**Goal**
Strengthen the repo's local teaching/demo surface around the existing CLI, TUI,
snapshot, and report paths.

**Acceptance criteria**
- Canonical scenarios have clearer walkthrough/demo coverage.
- Deterministic TUI snapshot or golden proof surfaces exist for selected teaching cases.
- README/docs make the local teaching path easier to follow without hiding simulator truth.
- Local CLI/TUI workflows remain first-class and no browser/WASM path becomes required.

**Dependencies**
- M15, M16, M17, and M5 approval.

**Preferred execution mode**
- docs-heavy `$team` or `ralph`.

### M22 — [Optional library branch] library / SDK stabilization for embedders
**Goal**
Offer a more intentional reusable API for tools or teaching platforms.

**Acceptance criteria**
- Public library boundaries are documented and versioned.
- Engine/report APIs have compatibility promises.
- Example embedding usage exists.

**Dependencies**
- M14, M16, and M5 approval.

**Preferred execution mode**
- `ralph` or `$team`.

### M23 — [Optional teaching/distribution branch] packaged teaching distribution and courseware
**Goal**
Turn the project into a stronger learning kit: labs, walkthroughs, exercises, and guided outputs.

**Acceptance criteria**
- There is a documented teaching path from beginner scenarios to advanced labs.
- Packaging/docs make onboarding easier without hiding simulator truth.
- Example assignments or exercises are reproducible.

**Dependencies**
- M17 and M5 approval.

**Preferred execution mode**
- docs-heavy `$team`.

### M24 — [Optional research branch] research sandbox branch for new policies / experiments
**Goal**
Allow fast experimental policy work without destabilizing the core teaching spine.

**Acceptance criteria**
- Sandbox boundaries are documented.
- Experimental work can be marked unstable without polluting stable contracts.
- Promotion path from experiment to supported milestone exists.

**Dependencies**
- M9, M13, and M5 approval.

**Preferred execution mode**
- `ralph` or `$team`.

### M25 — [Planning gate / optional production branch] productionization gate: daemon / service / automation branch
**Goal**
Decide whether the project should ever become an operational service or automation system.

Decision artifact:
- `docs/adr/0003-m25-productionization-gate.md`

**Acceptance criteria**
- Explicit re-charter says whether this branch is rejected, deferred indefinitely, or approved with constraints.
- If approved, scope separates clearly from the simulator core.

**Dependencies**
- None before the gate review itself.

**Execution note**
- This milestone is itself the re-charter event for the optional production branch.

**Preferred execution mode**
- planning/architect lane only until approved.

### M26 — [Optional production branch] scheduler-driven automation prototype
**Goal**
If the project is re-chartered, prototype a service/daemon/agent that uses scheduler concepts operationally.

**Acceptance criteria**
- The branch does not masquerade as the original simulator milestone stream.
- Operational concerns (config, lifecycle, observability, failure modes) are specified.
- The repo structure or sibling package split is deliberate.

**Dependencies**
- Future explicit re-charter approval after M25.

**Preferred execution mode**
- `$team` only.

---

## Where future `$team` parallelization is especially valuable
- **M3 / M12**: split engine state, trace/export, fixtures/invariants, and docs.
- **M4 / M15 / M21**: split data model, rendering/UI, golden artifacts, and verification.
- **M6 / M7 / M11**: split scenario/schema, engine semantics, policy changes, and docs/tests.
- **M19 / M20**: split import adapters, provenance/docs, comparison logic, and verification.
- **M23 / M26**: split docs/UX, packaging, examples, and validation.

## Available agent types for follow-up execution
- `architect` — ADRs, boundaries, dependency checks, identity-gate review
- `planner` — milestone slicing, revisions, sequencing updates
- `executor` — implementation for code-bearing milestones
- `test-engineer` — fixture design, invariant suites, regression hardening
- `verifier` — acceptance evidence, claim validation, artifact auditing
- `writer` — README/docs/courseware/report pipelines
- `critic` — challenge milestone scope or gate decisions before execution
- `explore` — fast repo lookup during milestone prep or execution
- `researcher` — only when later milestones depend on official docs/external formats

## Suggested reasoning levels by lane
- Architecture / ADR / identity gates: **high**
- Milestone planning updates: **medium**
- Repo-local file/symbol lookup: **low**
- Code implementation: **high** for state-model milestones, **medium** for bounded contract passes
- Verification / acceptance review: **high**
- Documentation refresh: **medium**

## Execution guidance for `ralph` vs `$team`

### Use `ralph` when
- the milestone is mostly sequential and bounded,
- the write surface is small or medium,
- the verification story is straightforward,
- the milestone is contract hardening, docs, test corpus work, or focused semantics.

Best `ralph` candidates: `M1.5`, `M2`, `M2.5`, `M3.5`, `M4.5`, `M8`, `M13`, `M16`, `M17`, `M22`, `M24`.

### Use `$team` when
- the milestone touches engine + schema + export + docs simultaneously,
- the state-space jump is large,
- parallel lanes are obvious and disjoint enough,
- a dedicated verification lane adds value before merge.

Best `$team` candidates: `M3`, `M4`, `M6`, `M7`, `M9`, `M11`, `M12`, `M14`, `M15`, `M19`, `M20`, `M21`, `M23`, `M26`.

## Explicit launch hints
- `ralph`: `\$ralph Execute milestone M2 from docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md and verify against docs/roadmap/test-spec-multi-horizon-zig-scheduler-roadmap.md.`
- `team`: `\$team Execute milestone M3 from docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md and verify against docs/roadmap/test-spec-multi-horizon-zig-scheduler-roadmap.md with lanes for engine/core-state, export/trace, fixtures/tests, and docs.`
- Shell form when desired: `omx team run --task "Execute milestone M7 from docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md and verify against docs/roadmap/test-spec-multi-horizon-zig-scheduler-roadmap.md"`
- Planning gates: use `\$ralplan` for `M5`, `M18`, and `M25`; do **not** launch direct implementation for those milestones before the ADR/gate outcome is approved.

## Concrete team verification path
For any `$team` milestone, keep a dedicated verification lane that:
1. re-reads the milestone acceptance criteria,
2. maps every claim to a specific command/test/doc artifact,
3. reruns the required checks,
4. audits wording against `README.md` and `docs/linux-mapping.md`,
5. blocks completion until evidence exists for every acceptance criterion.

---

## Recommended immediate next handoff path
1. Finish and commit the current M1.5 working-tree changes.
2. Use `ralph` for `M2` unless the semantic package widens beyond weighted single-core fairness.
3. Re-enter `ralplan` at `M5`, `M18`, and `M25` before any identity-band change.
4. Prefer `$team` starting at `M3` or earlier only when the implementation naturally splits into disjoint engine/schema/tests/docs lanes.
