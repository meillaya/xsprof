# Test Spec — M20 simulator-to-trace comparison summary

## Status
Draft for consensus review on 2026-04-22

## Scope under test
- comparison metric contract
- fixed-input reproducibility
- wording audit against overclaiming
- explicit separation from simulator export/report and analysis contracts
- one approved pairing only
- normalization contract for counts/order/span summaries only
- exact `zig-scheduler/observability-comparison` v1 payload shape
- library/docs/test-only entrypoint boundary

## Approved future proof surfaces
- `src/observability/comparison.zig`
- `src/tests/observability_comparison_test.zig`
- `docs/m20-simulator-to-trace-comparison.md`

## Required verification
1. approved M18/M19 gate audit
2. approved pairing-manifest audit for:
   - simulator scenario `scenarios/basic/sleep-wakeup.zon`
   - simulator policy `cfs_like`
   - M19 fixture manifest `fixtures/linux-observability/manifests/m19-tracefs-sched-demo.json`
   - pairing manifest `fixtures/linux-observability/pairings/m20-sleep-wakeup-vs-m19-tracefs-sched-demo.json`
   - contract `zig-scheduler/observability-comparison` v1
3. comparison metric tests for the approved metric set only
4. normalization-contract tests for counts/order/span summaries only:
   - `activation` = `arrival|wakeup` vs `sched_wakeup|sched_wakeup_new`
   - `selection` = `dispatch` vs `sched_switch`
   - `retirement` = `complete` vs `sched_process_exit`
   - no raw event-by-event alignment
   - no task↔PID/entity equivalence
   - unmapped approved-trace events are counted in raw totals but excluded from normalized family summaries
5. fixed-input reproducibility checks
6. comparison-contract-shape tests for:
   - `schema`
   - `version`
   - `pairing_id`
   - `simulator_source`
   - `observability_fixture_manifest`
   - `normalized_order_summary`
   - `metric_rows`
   - `caveats`
   - no additional top-level fields
   - exact nested shapes for:
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
     - `metric_rows`:
       - `metric_key`
       - `simulator_value`
       - `observability_value`
       - `delta`
       - `caveat_key`
     - `caveats`:
       - object keyed only by approved caveat keys
7. wording audit against replay/performance/fidelity/calibration overclaiming
8. boundary audit for `zig-scheduler/report`, `src/contract/report.zig`, `src/cli/report.zig`, and `src/analysis/*`
9. entrypoint audit proving M20 v1 is library/docs/tests only and exposes no CLI/report-export path
10. pairing-manifest-shape tests for:
   - `schema`
   - `version`
   - `pairing_id`
   - `simulator_scenario`
   - `simulator_policy`
   - `observability_fixture_manifest`
   - `approved_metric_set`
   - `required_caveat_keys`
   - `required_caveat_keys` may reference only the approved caveat-key registry
11. committed-input comparison smoke

## Minimum checks
- approved pairing-manifest validation
- comparison metric tests for exactly:
  - `activation_count_delta`
  - `selection_count_delta`
  - `retirement_count_delta`
  - `total_event_count_delta`
  - `cpu_cardinality_delta`
  - `actor_cardinality_delta`
  - `time_span_delta`
- normalization-contract tests for the exact mapping above
- exact first-seen normalized family order assertions
- explicit rejection tests for raw event alignment and task↔PID/entity equivalence
- explicit unmapped-event handling test
- fixed-input reproducibility checks
- comparison-contract-shape assertions for exact `zig-scheduler/observability-comparison` v1 top-level fields only
- comparison-contract-shape assertions for exact nested-field shapes
- approved caveat-key registry assertions:
  - `observability_only`
  - `units_not_equivalent`
  - `identity_not_equivalent`
  - `unmatched_events_present`
  - `not_fidelity`
- claim-rejection tests for unsupported labels:
  - `faithful`
  - `validated`
  - `kernel-accurate`
  - `replay match`
  - `performance baseline`
  - `calibrated against Linux truth`
- boundary audit proving no widening of `zig-scheduler/report`, `src/contract/report.zig`, `src/cli/report.zig`, or `src/analysis/*`
- entrypoint audit proving no CLI/report-export surface in the first cut
- exact pairing-manifest-shape assertions
- exact `required_caveat_keys` whitelist assertions
- exact `required_caveat_keys` assertions for the sole approved pairing
- exact per-metric caveat-key binding assertions
- exact numeric value-semantics assertions:
  - count/cardinality rows are integers
  - `time_span_delta` may be floating-point
- comparison smoke from committed simulator + M19 fixture inputs only

## Non-goals for this milestone
- replay-fidelity scoring
- Linux-performance benchmarking
- automatic equivalence scoring
- widening the main export/report contract
