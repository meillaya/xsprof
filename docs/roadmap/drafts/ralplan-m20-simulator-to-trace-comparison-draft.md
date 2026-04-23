# RALPLAN-DR Draft — M20 Simulator-to-Trace Comparison Summary

## Status
Initial consensus-planning draft for review on 2026-04-21.

## Scope anchor
This draft is bounded by:
- `docs/adr/0002-m18-linux-observability-gate.md`
- `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md`
- `docs/roadmap/test-spec-multi-horizon-zig-scheduler-roadmap.md`
- `docs/roadmap/m19/prd-m19-curated-linux-observability.md`
- `docs/roadmap/m19/test-spec-m19-curated-linux-observability.md`
- `docs/m19-curated-linux-observability.md`
- `src/observability/root.zig`
- `src/tests/linux_observability_test.zig`
- `docs/project-architecture-and-status.md`

M20 remains an **educational comparison summary** built on M19's existing narrow offline observability surface. It must keep metrics and caveats explicit, produce results reproducibly from committed inputs, and reject wording or outputs that imply unsupported replay fidelity, validation authority, kernel-faithful calibration, or Linux-performance authority.

---

## RALPLAN-DR

### Principles
1. **Educational, not authoritative.** M20 may compare simulator output to imported Linux-observability fixtures only as a teaching aid, never as proof of replay fidelity or kernel equivalence.
2. **Committed inputs only.** Every comparison result must be reproducible from committed simulator inputs plus committed M19 fixture/manifests.
3. **Metric caveats are part of the contract.** Every emitted metric must ship with its interpretation boundary and non-claim caveats.
4. **Separate surface, explicit boundary.** M20 must stay outside `zig-scheduler/report` and outside the existing `src/analysis` contract unless a later gate explicitly widens them.
5. **Fail closed on unsupported meaning.** If a requested metric or label implies unsupported fidelity, calibration authority, or Linux-performance meaning, the comparison surface must reject it.

### Decision drivers
1. Stay inside ADR 0002 and M19 truthfulness constraints.
2. Reuse the already-landed M19 observability loader/support-matrix boundary instead of inventing a broader ingest path.
3. Prefer deterministic, reviewable, fixture-backed comparisons over flexible but unverifiable analysis.
4. Keep the first M20 cut small enough that docs/tests can audit every supported metric and caveat.
5. Avoid widening the public simulator export/report identity while still making the optional branch educationally useful.

### Viable options

#### Option A — Docs-only comparison guidance
Ship metric definitions and caveats, but no executable comparison surface.
- **Pros:** lowest scope and lowest overclaiming risk.
- **Cons:** misses the roadmap's intended comparison/calibration value and leaves reproducibility mostly manual.

#### Option B — Separate reproducible comparison summary (recommended)
Add a dedicated observability-comparison surface that consumes committed simulator outputs plus committed M19 fixtures and emits a bounded comparison summary with explicit caveats.
- **Pros:** preserves M19/M18 boundaries, supports reproducible teaching outputs, and avoids widening `zig-scheduler/report`.
- **Cons:** requires a pairing contract and a tightly curated metric set.

#### Option C — Fold comparison into main report/analysis contract
Route Linux-observability comparison through `zig-scheduler/report` and downstream analysis surfaces.
- **Why rejected:** too easy to blur simulator-native reports with Linux-facing comparison semantics; expands the public contract before the branch has earned that complexity.

### Recommended narrow scope
Adopt **Option B** with a deliberately small first-cut comparison contract:

1. **One committed comparison pairing only**
   - One approved M19 fixture/manifest pair:
     - `fixtures/linux-observability/manifests/m19-tracefs-sched-demo.json`
   - One committed simulator scenario + policy tuple:
     - `scenarios/basic/sleep-wakeup.zon`
     - policy: `cfs_like`
   - One committed pairing manifest:
     - `fixtures/linux-observability/pairings/m20-sleep-wakeup-vs-m19-tracefs-sched-demo.json`
   - One comparison contract:
     - `zig-scheduler/observability-comparison` v1

2. **Summary-level overlap metrics only**
   Support only metrics that are already defensible from the repo's current surfaces:
   - `activation_count_delta`
   - `selection_count_delta`
   - `retirement_count_delta`
   - `total_event_count_delta`
   - `cpu_cardinality_delta`
   - `actor_cardinality_delta`
   - `time_span_delta`

   No additional derived metrics are part of v1.

   Normalization contract:
   - `activation`: simulator `arrival|wakeup` vs Linux `sched_wakeup|sched_wakeup_new`
   - `selection`: simulator `dispatch` vs Linux `sched_switch`
   - `retirement`: simulator `complete` vs Linux `sched_process_exit`
   - comparison is summary-level only; it is not raw event alignment or entity equivalence

   Explicitly out of scope for the first M20 cut:
   - event-by-event replay scoring
   - scheduler-faithful task matching
   - latency/fairness claim calibration against Linux truth
   - Linux-performance benchmarking
    - automatic equivalence scoring or any single-number “fidelity score”

3. **Explicit claim-rejection layer**
   - Comparison output must embed caveats inline.
   - Unsupported labels such as “validated”, “faithful”, “kernel-accurate”, “replay match”, “performance baseline”, or “calibrated against Linux truth” are rejected by contract/tests.
   - If a metric cannot be explained from committed inputs and current M19 summary fields, it stays out of scope.

### Touchpoints

**Planning / governance artifacts**
- update: `docs/roadmap/m20/prd-m20-simulator-to-trace-comparison.md`
- update: `docs/roadmap/m20/test-spec-m20-simulator-to-trace-comparison.md`
- new: `docs/roadmap/drafts/ralplan-m20-simulator-to-trace-comparison-draft.md`

**Supporting proof-surface updates**
- update: `README.md`
- update: `docs/project-architecture-and-status.md`
- new: `docs/m20-simulator-to-trace-comparison.md`
- maybe update: `docs/m19-curated-linux-observability.md` only to add the explicit handoff boundary into M20

**Supporting code / contract touchpoints**
- update or split from: `src/observability/root.zig`
- likely new: `src/observability/comparison.zig`
- new comparison schema/constants for a separate contract (for example `zig-scheduler/observability-comparison`)
- no widening of `src/contract/report.zig`, `src/cli/report.zig`, or `src/analysis/*` in the first cut

**Supporting test / fixture touchpoints**
- update: `src/tests/linux_observability_test.zig`
- likely new: `src/tests/observability_comparison_test.zig`
- new committed pairing manifest: `fixtures/linux-observability/pairings/m20-sleep-wakeup-vs-m19-tracefs-sched-demo.json`

**Exact future implementation surfaces to approve**
- `src/observability/comparison.zig`
- `src/tests/observability_comparison_test.zig`
- `docs/m20-simulator-to-trace-comparison.md`

No other new public comparison surface is approved in the first cut.

### Verification shape
1. **Gate audit**
   - confirm M18 and M19 boundaries are still cited in docs/tests before M20 comparison code is considered valid
2. **Pairing reproducibility audit**
   - the same committed simulator scenario/policy + committed M19 fixture reproduce byte-stable or field-stable comparison output
3. **Metric-contract audit**
   - every emitted metric has a documented meaning, units/basis, and caveat text
4. **Claim-rejection audit**
   - tests reject unsupported labels and wording implying fidelity, validation, kernel accuracy, or Linux-performance authority
5. **Boundary audit**
   - `zig-scheduler/report` and existing `src/analysis/*` surfaces remain unchanged for the first M20 cut
6. **Determinism smoke**
   - committed pairing -> simulator run/export -> observability load -> comparison summary succeeds reproducibly from repo contents only

### Available agent types
- `planner` — finalize PRD/test-spec wording and acceptance criteria
- `architect` — lock the narrow comparison contract and separation boundary
- `critic` — challenge metric overreach and unsupported claim language
- `writer` — docs, caveat tables, and comparison-contract documentation
- `executor` — implement the separate comparison surface after approval
- `test-engineer` — reproducibility, claim-rejection, and boundary tests
- `verifier` — evidence pass across docs/tests/contracts before handoff completion

### Suggested execution mode
- **Now:** stay in `ralplan` / consensus-planning mode until the M20 PRD + test spec are explicitly approved.
- **Recommended execution mode after approval:** **`$team`**.
  - Lane 1: pairing manifest + comparison contract + caveat schema
  - Lane 2: observability comparison implementation (`src/observability/*` only)
  - Lane 3: docs/proof-surface wording and boundary updates
  - Lane 4: reproducibility + claim-rejection + boundary verification

### ADR handoff summary
**Decision:** pursue a narrow M20 as a separate reproducible observability-comparison summary, not as a widened simulator report contract.

**Drivers:** truthfulness, reproducibility from committed inputs, explicit caveats, and preservation of the simulator-first public contract.

**Alternatives considered:** docs-only guidance, separate comparison summary, or mainline report-contract integration.

**Why chosen:** the separate summary path is the smallest useful surface that adds educational comparison value without overstating what M19/M20 can prove.

**Consequences:**
- M20 remains a carefully bounded teaching/comparison layer rather than a replay-validation system.
- The first M20 cut should compare only a tiny approved metric set over one committed pairing.
- Any attempt to add event-level replay scoring, broader pairing flexibility, or stronger fidelity/performance language should trigger a new planning decision rather than slip into this milestone.
