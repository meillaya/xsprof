# M20 simulator-to-trace comparison summary

M20 adds a **narrow comparison-summary layer** between one committed simulator
input and one committed offline Linux-observability fixture admitted under M19.

## Scope

The first M20 cut is intentionally limited to:
- one approved pairing manifest at
  `fixtures/linux-observability/pairings/m20-sleep-wakeup-vs-m19-tracefs-sched-demo.json`
- one simulator input only:
  `scenarios/basic/sleep-wakeup.zon` with policy `cfs_like`
- one M19 observability fixture manifest only:
  `fixtures/linux-observability/manifests/m19-tracefs-sched-demo.json`
- one comparison contract only: `zig-scheduler/observability-comparison` v1
- library/docs/tests-only implementation boundaries

M20 v1 does **not**:
- widen `zig-scheduler/report`
- widen `src/analysis/*`
- create a CLI or report-export surface for comparison summaries
- align raw events one-by-one
- match simulator task identity to Linux PID identity
- treat the M19 fixture as replay or performance authority

## Approved pairing

| field | value |
| --- | --- |
| `pairing_id` | `m20-sleep-wakeup-vs-m19-tracefs-sched-demo` |
| `simulator_scenario` | `scenarios/basic/sleep-wakeup.zon` |
| `simulator_policy` | `cfs_like` |
| `observability_fixture_manifest` | `fixtures/linux-observability/manifests/m19-tracefs-sched-demo.json` |

The approved metric set is fixed to exactly:
- `activation_count_delta`
- `selection_count_delta`
- `retirement_count_delta`
- `total_event_count_delta`
- `cpu_cardinality_delta`
- `actor_cardinality_delta`
- `time_span_delta`

The required caveat keys for the sole approved pairing are fixed to exactly:
- `observability_only`
- `units_not_equivalent`
- `identity_not_equivalent`
- `unmatched_events_present`
- `not_fidelity`

## Normalization contract

M20 compares only this normalized family mapping:

| normalized family | simulator source | observability source |
| --- | --- | --- |
| `activation` | `arrival`, `wakeup` | `sched_wakeup`, `sched_wakeup_new` |
| `selection` | `dispatch` | `sched_switch` |
| `retirement` | `complete` | `sched_process_exit` |

Additional normalization rules:
- summaries stay at family/order/count/span level only
- normalized order is the first-seen family order from each input
- unmapped approved-trace events remain in raw totals and stay out of the
  normalized family summaries
- no hidden family derivations outside the table above

## Comparison contract v1

`zig-scheduler/observability-comparison` v1 is frozen to these top-level keys
only:
- `schema`
- `version`
- `pairing_id`
- `simulator_source`
- `observability_fixture_manifest`
- `normalized_order_summary`
- `metric_rows`
- `caveats`

Nested shape is frozen to:
- `simulator_source`: `scenario_path`, `policy`, `report_schema`, `report_version`
- `observability_fixture_manifest`: `manifest_path`, `family`, `kernel_release`,
  `snapshot_format_version`, `scrub_policy_version`
- `normalized_order_summary`: `simulator_families`, `observability_families`
- `metric_rows[]`: `metric_key`, `simulator_value`, `observability_value`,
  `delta`, `caveat_key`
- `caveats`: object keyed only by the approved caveat-key registry

Per-metric caveat binding is fixed to:
- `activation_count_delta` → `not_fidelity`
- `selection_count_delta` → `not_fidelity`
- `retirement_count_delta` → `not_fidelity`
- `total_event_count_delta` → `not_fidelity`
- `cpu_cardinality_delta` → `not_fidelity`
- `actor_cardinality_delta` → `identity_not_equivalent`
- `time_span_delta` → `units_not_equivalent`

## Reproducibility

The first-cut pairing is reproducible from committed repo inputs only.

Simulator-side input can be regenerated locally with:

```bash
zig build sim -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs_like --format json
```

Observability-side input stays fixed to the committed M19 manifest + scrubbed
snapshot already stored under `fixtures/linux-observability/`.

## Approved implementation surfaces

M20 approval is limited to these comparison-summary surfaces:
- `src/observability/comparison.zig`
- `src/tests/observability_comparison_test.zig`
- `docs/m20-simulator-to-trace-comparison.md`

Supporting proof artifacts may document or verify the approved surface, but they
must not create additional public comparison entrypoints.
