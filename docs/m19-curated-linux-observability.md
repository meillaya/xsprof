# M19 Curated Linux-observability snapshots

M19 is the first implementation milestone inside the optional Linux-observability
branch approved by `docs/adr/0002-m18-linux-observability-gate.md`. It adds a
fixture-first, offline import path for curated Linux scheduler snapshots while
keeping the simulator/report mainline unchanged.

## Contract summary

M19 is allowed to do only the following:

- load committed scrubbed fixtures from `fixtures/linux-observability/`
- validate a manifest plus support-matrix tuple before parsing a fixture
- parse the initial approved `tracefs-sched-snapshot` text snapshot format
- normalize imported data into an observability-only model
- render or test a bounded observability summary smoke path

M19 is explicitly not allowed to do the following:

- live tracing, trace capture, or capture automation in the repo
- replay-fidelity, calibration, or Linux-performance claims
- import `perf sched`, generic `perf.data`, `perf script`, `trace_pipe`, or
  non-`sched:*` tracepoint families in the initial cut
- widen `zig-scheduler/report`, `src/analysis`, or simulator-native scenario
  contracts

## Approved initial tuple

Only one literal tuple is approved for the initial M19 cut. Anything else must
fail closed until a later planning/approval pass widens the support matrix.

| field | approved value |
| --- | --- |
| `family` | `tracefs-sched-snapshot` |
| `kernel_release` | `linux-6.6` |
| `tool_version` | `tracefs-kernel-6.6` |
| `tracefs_root` | `/sys/kernel/tracing` |
| `capture_recipe` | `instance=m19-snapshot; events=sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit; snapshot=1` |
| `trace_clock` | `global` |
| `enabled_sched_events` | `sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit` |
| `scope` | `system-wide dedicated instance` |
| `mode` | `snapshot` |
| `time_window` | `single bounded snapshot` |
| `snapshot_format_version` | `tracefs-sched-text-v1` |
| `scrub_policy_version` | `linux-observability-scrub-v1` |

## Fixture and manifest policy

All Linux-facing artifacts introduced by M19 stay outside `scenarios/` and are
reviewed as committed evidence artifacts, not as simulator-native workloads.
The expected surfaces are:

- `fixtures/linux-observability/README.md`
- `fixtures/linux-observability/manifests/*.json`
- `fixtures/linux-observability/tracefs-sched-snapshot/*`
- `fixtures/linux-observability/support-matrix.json`

Every admitted fixture must carry provenance, redistribution basis, scrub-policy
version, and the exact approved tuple row used for loading.

## Boundary with the existing report/analyzer path

M19 stops before the existing `zig-scheduler/report` export contract. Imported
Linux fixtures do not route into `src/analysis`, do not become simulator-native
report fixtures, and do not widen the report schema. The M19 output is a
separate observability-only normalized summary boundary.

## Unsupported families in the initial cut

The initial M19 cut rejects these families or source classes by design:

- `perf sched`
- generic `perf.data`
- `perf script`
- `trace_pipe`
- non-sched tracepoints

If support for any of these is needed, that is a new planning decision rather
than a small follow-up inside the initial M19 scope.

## Proof surfaces

The repo must keep the following surfaces aligned whenever M19 changes:

- `docs/adr/0002-m18-linux-observability-gate.md`
- `README.md`
- `docs/project-architecture-and-status.md`
- this document
- governance/import smoke tests that verify wording, tuple enforcement, and the
  observability-summary boundary

The proof standard is intentionally governance-heavy: make every claim narrower
than the implementation can prove, and prefer rejected scope over overclaiming.
