# xsprof wire schemas

Canonical namespace: `xsprof/*`. Legacy `zig-scheduler/*` schemas live on
`archive/cpp-0.1.0` and are not served by this rewrite.

Key ordering is lexical and compact; required fields are validated at the
boundary, and every record carries `host_mutation=false`.

| File | Contract |
|---|---|
| `event.v1.schema.json` | One canonical scheduler/memory event |
| `journal.v1.schema.json` | Legacy wrapped journal |
| `aggregates.v1.schema.json` | Frozen advisor aggregate snapshot |
| `advisor-report.v1.schema.json` | Advisor findings/rules |
| `metrics.v1.schema.json` | Metrics, tasks, CPUs, wakeup pairs, ordering |
| `why.v1.schema.json` | `xsprof why` report |
| `history.v1.schema.json` | Sidecar history query |
| `capture-summary.v1.schema.json` | `record` stderr summary |
| `recorder-manifest.v1.schema.json` | Recorder session/segment index |
| `recorder-result.v1.schema.json` | Daemon result and overhead |
| `recorder-verify.v1.schema.json` | Read-only segment/state verification |
| `incident-summary.v1.schema.json` | Incident bundle summary |
| `incident-result.v1.schema.json` | Incident command result |
| `doctor.v1.schema.json` | Read-only environment diagnostics |
| `preflight.v1.schema.json` | Host facts/capability snapshot |
| `pressure.v1.schema.json` | PSI CPU/memory/IO stall counters |
| `cgroup.v1.schema.json` | Read-only cgroup attribution |
| `bpf-gate.v1.schema.json` | VM-marker-gated no-op BPF gate |
| `lab-scenario.v1.schema.json` | Bounded lab scenario |
| `lab-run.v1.schema.json` | Headless lab run result |
| `compare.v1.schema.json` | Baseline/candidate comparison |

`metrics.v1` adds `out_of_order`, `pairs_truncated`, and `wakeup_pairs`.
`recorder-manifest.v1` adds `history_interval_ms`/`history_retain_ms`, and the
additive `raw_codec`/segment `codec` fields (`ndjson` or `compact_v1`).
`capture-summary.v1` adds split `faults_major`/`faults_minor`, `lost`, and
`output`. Existing manifests without the history fields remain parseable.