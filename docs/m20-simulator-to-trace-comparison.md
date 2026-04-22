# M20 simulator-to-trace comparison summary

M20 defines a narrow, reproducible comparison layer between one committed
simulator output and one committed M19 Linux-observability fixture.

This comparison surface is educational only. It is meant to help readers inspect
where a simulator scenario and an offline scheduler trace summary differ at the
level of normalized event families, counts, cardinalities, and trace-clock-
caveated span summaries. It is **not** a replay-fidelity, kernel-accuracy,
performance, or calibration surface.

## Scope

The first M20 cut is intentionally limited to:
- one approved simulator scenario + policy pairing only
- one approved M19 fixture manifest only
- one committed pairing manifest only
- one separate `zig-scheduler/observability-comparison` v1 payload only
- library + docs + tests proof surfaces only

M20 explicitly does **not**:
- widen `zig-scheduler/report`
- widen `src/analysis/*`
- introduce a CLI or report-export surface for the comparison path
- attempt raw event-by-event alignment
- match simulator tasks to Linux PIDs/entities
- claim replay fidelity, Linux truth, or Linux-performance meaning

## Approved first-cut pairing

| field | value |
| --- | --- |
| simulator scenario | `scenarios/basic/sleep-wakeup.zon` |
| simulator policy | `cfs_like` |
| M19 fixture manifest | `fixtures/linux-observability/manifests/m19-tracefs-sched-demo.json` |
| pairing manifest | `fixtures/linux-observability/pairings/m20-sleep-wakeup-vs-m19-tracefs-sched-demo.json` |
| comparison contract | `zig-scheduler/observability-comparison` v1 |

No additional simulator/fixture combinations are part of v1.

## Approved metric set

The first cut supports exactly these metric keys:
- `activation_count_delta`
- `selection_count_delta`
- `retirement_count_delta`
- `total_event_count_delta`
- `cpu_cardinality_delta`
- `actor_cardinality_delta`
- `time_span_delta`

No additional derived metrics, ratios, percentages, or single-number fidelity
scores are part of v1.

## Exact normalization mapping

M20 compares only this normalized family table:

| normalized family | simulator source | Linux-observability source |
| --- | --- | --- |
| `activation` | `arrival`, `wakeup` | `sched_wakeup`, `sched_wakeup_new` |
| `selection` | `dispatch` | `sched_switch` |
| `retirement` | `complete` | `sched_process_exit` |

Additional rules:
- family order is derived only as the first-seen normalized family order
- raw event-by-event alignment is out of scope
- simulator task identity and Linux PID/entity identity are not equivalent
- approved but unmapped Linux trace events still count toward raw totals and are
  excluded from normalized family summaries

## Comparison contract boundary

The comparison output is a separate payload contract. It does **not** widen the
existing simulator report/export surface.

Exact top-level fields for `zig-scheduler/observability-comparison` v1:
- `schema`
- `version`
- `pairing_id`
- `simulator_source`
- `observability_fixture_manifest`
- `normalized_order_summary`
- `metric_rows`
- `caveats`

No additional top-level fields are part of v1.

Exact nested shapes:
- `simulator_source`
  - `scenario_path`
  - `policy`
  - `report_schema`
  - `report_version`
- `observability_fixture_manifest`
  - `manifest_path`
  - `family`
  - `kernel_release`
  - `snapshot_format_version`
  - `scrub_policy_version`
- `normalized_order_summary`
  - `simulator_families`
  - `observability_families`
- `metric_rows[]`
  - `metric_key`
  - `simulator_value`
  - `observability_value`
  - `delta`
  - `caveat_key`
- `caveats`
  - object keyed only by approved caveat keys

Value semantics:
- `simulator_value`, `observability_value`, and `delta` are numeric in every row
- count/cardinality rows use integers
- `time_span_delta` may use floating-point values

## Approved caveats

The first cut allows only these caveat keys:
- `observability_only`
- `units_not_equivalent`
- `identity_not_equivalent`
- `unmatched_events_present`
- `not_fidelity`

The sole approved pairing requires exactly that caveat-key set.

Per-metric caveat bindings are fixed to:
- `activation_count_delta` → `not_fidelity`
- `selection_count_delta` → `not_fidelity`
- `retirement_count_delta` → `not_fidelity`
- `total_event_count_delta` → `not_fidelity`
- `cpu_cardinality_delta` → `not_fidelity`
- `actor_cardinality_delta` → `identity_not_equivalent`
- `time_span_delta` → `units_not_equivalent`

## Proof surfaces

The approved future proof surfaces for the first cut are:
- `src/observability/comparison.zig`
- `src/tests/observability_comparison_test.zig`
- `docs/m20-simulator-to-trace-comparison.md`

This keeps the first cut inside a library/docs/tests boundary. It intentionally
exposes no CLI entrypoint, no report-export widening, and no `src/analysis/*`
integration.

## Reproducibility and wording guardrails

The comparison must remain reproducible from committed repo inputs only:
- committed simulator scenario input
- committed M19 fixture manifest + payload
- committed pairing manifest
- committed caveat registry and metric bindings

Unsupported wording must be rejected. In particular, M20 must not present the
comparison as:
- `faithful`
- `validated`
- `kernel-accurate`
- `replay match`
- `performance baseline`
- `calibrated against Linux truth`

## Relationship to M19

M19 remains the upstream observability import boundary:
- offline, observability-only fixtures
- one approved tracefs sched snapshot family
- one approved literal tuple
- a separate observability summary path in `src/observability/root.zig`

M20 builds on that bounded input surface without converting it into replay or
Linux-performance authority.
