# observability curated Linux-observability snapshots

observability adds a narrow offline import boundary for curated Linux scheduler
observability fixtures.

## Scope

The observability implementation is intentionally limited to:
- committed scrubbed fixtures under `fixtures/linux-observability/`
- manifest validation against `fixtures/linux-observability/support-matrix.json`
- one approved literal tuple only
- offline parsing of `tracefs-sched-snapshot` text fixtures
- a separate observability-only normalized summary path in `src/observability/root.zig`

observability explicitly does **not**:
- run live capture tooling
- execute `perf`, tracefs, ftrace, or eBPF workflows in the repo
- support `perf sched`, generic `perf.data`, `perf script`, `trace_pipe`, or
  non-sched tracepoints
- widen `zig-scheduler/report`
- widen `src/analysis`
- make replay, calibration, or Linux-performance claims

## Approved tuple

| field | value |
| --- | --- |
| `family` | `tracefs-sched-snapshot` |
| `kernel_release` | `linux-6.6` |
| `tool_version` | `tracefs-kernel-6.6` |
| `tracefs_root` | `/sys/kernel/tracing` |
| `capture_recipe` | `instance=tracefs-snapshot; events=sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit; snapshot=1` |
| `trace_clock` | `global` |
| `enabled_sched_events` | `sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit` |
| `scope` | `system-wide dedicated instance` |
| `mode` | `snapshot` |
| `time_window` | `single bounded snapshot` |
| `snapshot_format_version` | `tracefs-sched-text-v1` |
| `scrub_policy_version` | `linux-observability-scrub-v1` |

Unsupported tuples fail closed by default.

## Repo surfaces

- Loader + normalized summary: `src/observability/root.zig`
- Governance + smoke tests: `src/tests/linux_observability_test.zig`
- Fixture manifest: `fixtures/linux-observability/manifests/tracefs-sched-demo.json`
- Fixture payload: `fixtures/linux-observability/tracefs-sched-snapshot/tracefs-sched-demo.trace`
- Support matrix: `fixtures/linux-observability/support-matrix.json`
- TUI observability lane: `zig-out/bin/zig-scheduler --observability` or `--observability-manifest <path>`

## Summary boundary

The summary output is intentionally observability-only. It reports fixture
identity, approved tuple fields, event counts, CPUs seen, PID presence, and
bounded timestamp span. It does not claim scheduler replay fidelity, calibration
meaning, or Linux-performance interpretation.
