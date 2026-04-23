# PRD — M19 curated Linux-observability snapshots

## Status
Draft for consensus review on 2026-04-21

## 1) Task framing and assumption check

### Framing
M19 is the first implementation milestone inside the optional Linux-observability branch approved by M18. Its job is to add a narrow, observability-only import path for curated Linux scheduler trace snapshots without claiming replay fidelity, calibration meaning, or Linux-performance authority.

### Assumption check
The working assumption is valid from repo evidence:
- `docs/adr/0002-m18-linux-observability-gate.md` approved only an offline, observability-only, version-pinned, scrubbed snapshot-fixture path.
- `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md` defines M19 as import of curated real scheduler trace snapshots with observability-only labeling.
- `docs/roadmap/test-spec-multi-horizon-zig-scheduler-roadmap.md` requires documented bounded formats, provenance metadata, and separation from simulator-native fixtures.
- The repo currently contains no Linux trace import code, so M19 can still choose a minimal initial support surface.

### Scope boundary
This milestone may produce:
- a narrow parser/import path for approved offline snapshot fixtures
- committed scrubbed Linux-observability fixtures with manifests
- clear observability-only docs and tests

This milestone must not produce:
- live tracing or capture tooling
- in-repo execution of perf/ftrace/eBPF collection workflows
- replay-fidelity or calibration claims
- Linux-performance comparisons
- M20 comparison logic

---

## 2) Principles
1. Import only what can be documented, version-pinned, and verified.
2. Keep M19 observability-only: imported traces are evidence artifacts, not replay authorities.
3. Prefer one smallest approved capture family before widening support.
4. Keep imported fixtures clearly separated from simulator-native scenarios and reports.
5. Treat manifests and scrub policy as part of the contract, not auxiliary docs.
6. Fail closed on unknown tuples and unsupported formats.

---

## 3) Decision drivers
1. Minimize support burden by choosing one smallest approved import surface.
2. Keep provenance/privacy/licensing review practical and auditable.
3. Preserve the simulator-first public identity after importing Linux-facing artifacts.
4. Reuse stable repo patterns: committed fixtures, deterministic parsing, explicit contracts, strong tests.
5. Leave M20 room for later comparison work without smuggling it into M19.

---

## 4) Viable options

### Option A — Manifest-only branch, no in-repo fixture import
### Option B — Single capture-family, offline snapshot import (recommended)
### Option C — Multi-family import surface from the start

---

## 5) Recommendation
Recommend **Option B**: support one smallest approved capture family first, with explicit version tuples and committed scrubbed manifests.

### Chosen initial capture family for planning
`tracefs-sched-snapshot`

Meaning:
- a dedicated tracefs instance
- only `sched:*` events enabled
- captured via `snapshot`
- stored as offline text snapshots plus manifests

Explicitly out of scope for the first M19 cut:
- `perf sched`
- generic `perf.data`
- `perf script`
- live `trace_pipe` streams
- non-sched tracepoints
- latency tracers / function tracers / other ftrace families

### Required tuple fields
- `family`
- `kernel_release`
- `tool_version`
- `tracefs_root`
- `capture_recipe`
- `trace_clock`
- `enabled_sched_events`
- `scope`
- `mode`
- `time_window`
- `snapshot_format_version`
- `scrub_policy_version`

### Initial tuple policy
- approve **one concrete tuple only** for the first M19 cut
- unsupported tuples fail closed by default
- perf-based families are follow-on work, not part of the initial approval

### Proposed initial approved tuple row
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

If the first committed fixture cannot satisfy this exact tuple row, M19 must re-enter planning before widening support.

### Output boundary decision
M19 does **not** widen the existing `zig-scheduler/report` contract.

Instead, M19 ends at:
- fixture admission + manifest validation
- offline parsing of the approved tracefs snapshot format
- a separate observability-specific normalized model
- a bounded observability-summary smoke path

Deferred beyond M19:
- routing imported Linux snapshots into the existing export-only analysis contract
- any comparison/calibration logic reserved for M20

### Required sections to finalize during consensus
- fixture/manifest layout
- import contract and explicit non-goals
- docs/proof surfaces to update
- tests and audit rules
