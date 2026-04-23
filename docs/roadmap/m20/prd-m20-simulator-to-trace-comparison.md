# PRD — M20 simulator-to-trace comparison summary

## Status
Draft for consensus review on 2026-04-22

## 1) Task framing and assumption check

### Framing
M20 adds a narrow educational comparison layer between simulator outputs and the offline Linux-observability fixtures admitted by M19.

### Assumption check
The working assumption is valid from repo evidence:
- ADR 0002 allows only offline, observability-only, version-pinned snapshot fixtures.
- M19 already imported one tracefs-sched-snapshot family through `src/observability/root.zig` without widening `zig-scheduler/report` or `src/analysis/*`.
- The roadmap requires M20 comparison metrics and caveats to be explicit, reproducible from committed inputs, and bounded against overclaiming.
- Official Linux tracing docs justify comparison at the level of observed event ordering/patterns, trace-clock-caveated timing, and aggregate counts, not replay fidelity.

### Scope boundary
This milestone may produce:
- a separate observability-comparison summary path
- one committed simulator/observability pairing manifest
- a tiny approved metric set with inline caveats
- reproducible comparison outputs from committed repo inputs only

This milestone must not produce:
- replay-fidelity claims
- Linux-performance benchmarking
- widening of `zig-scheduler/report`
- widening of `src/analysis/*`
- event-by-event replay scoring or automated equivalence scores
- task↔PID identity matching

---

## 2) Principles
1. Comparison is educational, not authoritative replay.
2. Reproducibility beats breadth.
3. Every metric carries its caveat and basis inline.
4. Keep the comparison surface separate from simulator export/report contracts.
5. Reject any comparison output that implies unsupported fidelity or performance meaning.

---

## 3) Decision drivers
1. Stay inside M18/M19 truthfulness boundaries.
2. Reuse the existing M19 observability surface rather than inventing a broader ingest path.
3. Prefer one approved comparison pairing and one tiny metric set before widening support.
4. Preserve the simulator-first mainline contract and keep Linux-facing semantics explicitly optional and bounded.
5. Make every supported comparison auditable in tests and docs.

---

## 4) Viable options

### Option A — docs-only comparison guidance
Define metrics/caveats in prose only.

**Pros**
- lowest implementation risk
- minimal chance of overclaiming

**Cons**
- weak educational value
- leaves reproducibility largely manual

### Option B — separate reproducible comparison summary (recommended)
Add a dedicated observability-comparison summary surface that consumes committed simulator outputs plus committed M19 fixtures and emits a bounded comparison summary with explicit caveats.

**Pros**
- preserves M19/M18 boundaries
- provides reproducible teaching outputs
- avoids widening `zig-scheduler/report`

**Cons**
- requires a careful pairing contract and tiny approved metric set

### Option C — fold comparison into the main report/analysis contract
Integrate Linux-observability comparison into `zig-scheduler/report` and downstream analysis.

**Why not recommended**
- blurs simulator-native and Linux-facing semantics
- expands a stable public contract too early
- increases overclaiming risk

---

## 5) Recommendation
Recommend **Option B**.

### Definition of “comparison” in M20
For this milestone, comparison means:
- juxtaposing one committed simulator trace summary against one committed M19 observability summary
- at the level of normalized event-family/order summaries, aggregate counts, CPU/actor cardinalities, and trace-clock-caveated span/rate-style timing summaries
- with caveats attached inline to every metric

It does **not** mean:
- replay validation
- calibration authority against Linux truth
- kernel-faithful entity matching
- Linux-performance benchmarking

### Approved comparison boundary for the first cut
- one committed simulator scenario + policy pairing only
- one committed M19 fixture/manifest only
- one committed pairing manifest naming both inputs and the allowed metric set
- one separate comparison summary contract only
- no change to `zig-scheduler/report`
- no reuse of `src/analysis/*` for the comparison path
- no changes to `src/contract/report.zig` or `src/cli/report.zig`

### Exact approved pairing
- simulator scenario: `scenarios/basic/sleep-wakeup.zon`
- simulator policy: `cfs_like`
- M19 fixture manifest: `fixtures/linux-observability/manifests/m19-tracefs-sched-demo.json`
- pairing manifest: `fixtures/linux-observability/pairings/m20-sleep-wakeup-vs-m19-tracefs-sched-demo.json`
- comparison contract: `zig-scheduler/observability-comparison` v1

### Supported first-cut metric set
1. `activation_count_delta`
2. `selection_count_delta`
3. `retirement_count_delta`
4. `total_event_count_delta`
5. `cpu_cardinality_delta`
6. `actor_cardinality_delta`
7. `time_span_delta`

No additional derived metrics are part of v1.

### Exact normalization contract
M20 compares only this normalized mapping:

| normalized family | simulator source | Linux-observability source |
| --- | --- | --- |
| `activation` | `arrival`, `wakeup` | `sched_wakeup`, `sched_wakeup_new` |
| `selection` | `dispatch` | `sched_switch` |
| `retirement` | `complete` | `sched_process_exit` |

Summary-level only:
- no raw event-by-event alignment
- no entity equivalence between tasks and PIDs
- no hidden family derivations outside this table
- order is derived from raw parsed events and emitted only as the first-seen normalized family order
- unmapped approved-trace events are counted in raw totals but excluded from normalized family summaries

### Explicitly out of scope in the first cut
- event-by-event replay scoring
- scheduler-faithful entity matching
- latency/fairness calibration claims against Linux truth
- single-number fidelity score
- Linux-performance baseline wording
- labels such as `faithful`, `validated`, `kernel-accurate`, `replay match`, `performance baseline`, or `calibrated against Linux truth`

### Output boundary decision
M20 uses a **separate observability-comparison summary** contract.

It does not:
- widen `zig-scheduler/report`
- widen `src/analysis/*`
- widen `src/contract/report.zig`
- widen `src/cli/report.zig`
- convert Linux trace observations into simulator-export provenance

### Exact comparison contract v1
`zig-scheduler/observability-comparison` v1 is frozen to this top-level shape only:
- `schema`
- `version`
- `pairing_id`
- `simulator_source`
- `observability_fixture_manifest`
- `normalized_order_summary`
- `metric_rows`
- `caveats`

No additional top-level fields are part of v1.

Nested-shape rules:
- `normalized_order_summary` is family-level only
- `metric_rows` is the only metric container in v1
- every metric row carries its own caveat or a referenced shared caveat key
- no field may imply replay fidelity, validation authority, or Linux-performance meaning

Exact nested-shape freeze:
- `simulator_source`:
  - `scenario_path`
  - `policy`
  - `report_schema`
  - `report_version`
- `observability_fixture_manifest`:
  - `manifest_path`
  - `family`
  - `kernel_release`
  - `snapshot_format_version`
  - `scrub_policy_version`
- `normalized_order_summary`:
  - `simulator_families`
  - `observability_families`
- `metric_rows[]`:
  - `metric_key`
  - `simulator_value`
  - `observability_value`
  - `delta`
  - `caveat_key`
- `caveats`:
  - object keyed by approved caveat key only

### Approved caveat-key registry
The first cut allows only:
- `observability_only`
- `units_not_equivalent`
- `identity_not_equivalent`
- `unmatched_events_present`
- `not_fidelity`

### Exact `required_caveat_keys` for the approved pairing
The sole approved pairing must require exactly:
- `observability_only`
- `units_not_equivalent`
- `identity_not_equivalent`
- `unmatched_events_present`
- `not_fidelity`

### `metric_rows` value semantics
- `simulator_value`, `observability_value`, and `delta` are numeric in every row
- count/cardinality metrics use integers
- `time_span_delta` may use floating-point values
- no ratio/percentage/string-valued metrics are part of v1

### Per-metric caveat binding
- `activation_count_delta` → `not_fidelity`
- `selection_count_delta` → `not_fidelity`
- `retirement_count_delta` → `not_fidelity`
- `total_event_count_delta` → `not_fidelity`
- `cpu_cardinality_delta` → `not_fidelity`
- `actor_cardinality_delta` → `identity_not_equivalent`
- `time_span_delta` → `units_not_equivalent`

### First-cut entrypoint / surface
The first M20 cut is **library + docs + tests only**:
- comparison logic under `src/observability/comparison.zig`
- smoke and contract checks in tests
- proof surfaces in docs

No CLI or report-export integration is part of the first M20 cut.

### Required pairing artifact
A committed pairing artifact is required, and for the first cut its values are
fully fixed by the exact pairing and exact pairing-manifest contract below.

### Exact pairing-manifest contract
The first-cut pairing manifest is contract-tested and contains exactly:
- `schema`
- `version`
- `pairing_id`
- `simulator_scenario`
- `simulator_policy`
- `observability_fixture_manifest`
- `approved_metric_set`
- `required_caveat_keys`

No additional top-level fields are part of the first-cut pairing-manifest contract.
`required_caveat_keys` may reference only the approved caveat-key registry above.

---

## 6) Touchpoints

### Planning / governance
- `docs/roadmap/m20/prd-m20-simulator-to-trace-comparison.md`
- `docs/roadmap/m20/test-spec-m20-simulator-to-trace-comparison.md`
- `docs/roadmap/drafts/ralplan-m20-simulator-to-trace-comparison-draft.md`

### Supporting proof-surface updates
- `README.md`
- `docs/project-architecture-and-status.md`
- `docs/m20-simulator-to-trace-comparison.md`
- possibly `docs/m19-curated-linux-observability.md` for explicit handoff wording only
- `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md` wording note: older “comparison / calibration” phrasing is narrowed here to comparison-summary only, with no calibration authority

### Supporting code/test touchpoints
- new: `src/observability/comparison.zig`
- maybe update: `src/observability/root.zig` only for local helper reuse
- new test surface: `src/tests/observability_comparison_test.zig`
- new docs surface: `docs/m20-simulator-to-trace-comparison.md`
- no widening of `src/contract/report.zig`, `src/cli/report.zig`, or `src/analysis/*`

### Exact future implementation surfaces to approve
M20 approval is for these future surfaces only:
- library contract + comparison logic: `src/observability/comparison.zig`
- test surface: `src/tests/observability_comparison_test.zig`
- docs/proof surface: `docs/m20-simulator-to-trace-comparison.md`

No other **new public comparison surface** is approved in the first cut.
Supporting updates to existing proof surfaces such as `README.md`,
`docs/project-architecture-and-status.md`, `src/tests/identity_gate_test.zig`,
and `src/tests/linux_observability_test.zig` are allowed only to document or
verify the approved comparison surface; they do not create additional public
comparison entrypoints.

### Test / fixture surfaces
- new: `src/tests/observability_comparison_test.zig`
- update: `src/tests/identity_gate_test.zig`
- update: `src/tests/linux_observability_test.zig`
- new committed pairing manifest at `fixtures/linux-observability/pairings/m20-sleep-wakeup-vs-m19-tracefs-sched-demo.json`

---

## 7) Verification shape
1. M18/M19 gate audit
2. pairing reproducibility audit
3. metric-contract audit
4. claim-rejection audit
5. boundary audit for report/analysis contracts
6. committed-input comparison smoke

---

## 8) Available agent types
- `planner`
- `architect`
- `critic`
- `writer`
- `executor`
- `test-engineer`
- `verifier`

---

## 9) Suggested execution mode
- stay in `ralplan` until this package is approved
- after approval, use `$team`
  - lane 1: pairing manifest + comparison contract + caveat schema
  - lane 2: comparison implementation in `src/observability/*`
  - lane 3: docs/proof surfaces
  - lane 4: reproducibility + claim-rejection + boundary tests
