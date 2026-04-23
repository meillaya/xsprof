# Test Spec — Sequential Milestones Roadmap for zig-scheduler

## Status
Revised draft — architect feedback incorporated on 2026-04-20

## Purpose
Define milestone-by-milestone verification expectations so roadmap execution stays deterministic, repo-specific, simulator-scoped, and safe for `ralph` / `team` handoff.

## Baseline verification snapshot
Verified on 2026-04-20:
- `zig build test --summary all` -> PASS (`20/20 tests passed`)
- Phase 1 acceptance status documented in `docs/phase1-signoff-report.md`

---

## Milestone verification matrix

### M1.5 — CLI / scenario I/O / report-export polish
**Required verification**
- Preserve current Phase 1 behavior for built-in scenarios and current human-readable report sections.
- Add CLI coverage for the explicit public contract:
  - `--scenario <builtin-name>`
  - `--scenario-file <path>`
  - mutual-exclusion validation.
- Add schema/version assertions for the new machine-readable export contract.
- Add scenario-format migration/back-compat checks covering both canonical object-style ZON and current legacy line-oriented fixtures.
- README/docs examples must be executable against repo fixtures.

**Minimum checks**
- `zig build test --summary all`
- built-in scenario smoke command passes
- file-path scenario smoke command passes
- CLI validation test rejects ambiguous/mutually-exclusive source selection
- export schema/version assertion passes
- repeated-run export equality check passes
- mixed-fixture parser/back-compat checks pass
- wording audit: still simulator-only / Linux-inspired

### M2 — weighted single-core fairness semantics
**Required verification**
- Freeze the weighted-fairness semantic contract before coding and test that contract directly.
- Repeated runs under all policies remain deterministic.
- Current golden scenario coverage is retained or explicitly migrated.
- Docs explain how task weights affect fairness and where the model remains simplified.

**Minimum checks**
- `zig build test --summary all`
- weighted-scenario parser/schema tests
- engine/metrics tests for deterministic weight-aware accounting
- policy regression tests for FCFS / RR / CFS-inspired under weighted inputs
- repeated-run determinism checks for weighted fixtures
- docs/README wording audit

### M3 — multicore / SMP simulation
**Required verification**
- Deterministic multicore fixtures with per-core assertions.
- Single-core regression safety remains intact.
- Trace/export surfaces expose CPU/core identity and migration where applicable.
- Core invariants are enforced programmatically:
  - no task can run on two cores in the same tick,
  - per-core execution sums match each task’s total executed ticks,
  - aggregate executed work matches the scenario’s expected task totals.
- Docs explicitly bound SMP simplifications.

**Minimum checks**
- `zig build test --summary all`
- repeated-run multicore determinism tests
- invariant tests for no-double-run-per-tick
- invariant tests for per-core and per-task execution totals
- single-core regression suite passes unchanged or with documented fixture migration
- CLI/export smoke for multicore output
- docs audit for SMP wording

### M4 — analysis + visualization
**Required verification**
- Generated analysis artifacts are reproducible from committed fixtures.
- Visualization outputs are deterministic and documented.
- Analysis consumes versioned exported data only, not engine internals or unversioned in-process structures.
- Contract-version checks prove the analysis path accepts only supported export versions or fails clearly on unsupported ones.

**Minimum checks**
- `zig build test --summary all`
- artifact reproducibility check
- export -> analysis/report CLI smoke
- contract test proving analysis rejects or gates unsupported export versions
- code-path audit/test proving analysis reads exported contract data rather than engine internals
- docs/examples audit

### M5-optional — Linux-facing identity gate
**Required verification**
- ADR/decision review before code work.
- README/docs wording audit before any Linux-facing implementation begins.

**Minimum checks**
- approval of the identity ADR
- audit confirming no Linux-facing implementation started before approval

---

## Cross-milestone regression expectations
- Every milestone reruns `zig build test --summary all`.
- Existing scenario fixtures remain valid unless a milestone explicitly includes a documented migration.
- Mixed fixture dialect support remains tested until the roadmap explicitly removes legacy compatibility.
- README and `docs/linux-mapping.md` wording must be reviewed at each milestone boundary.
- New trace/export event kinds should be asserted programmatically, not only via manual CLI reading.
- M4 and later consumers must treat the versioned export contract as the only supported integration surface.
