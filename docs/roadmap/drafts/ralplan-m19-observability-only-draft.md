# RALPLAN-DR Draft — M19 Offline Linux-Observability Snapshots

## Status
Initial consensus-planning draft for review on 2026-04-21.

## Scope anchor
This draft is bounded by:
- `docs/adr/0002-m18-linux-observability-gate.md`
- `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md`
- `docs/roadmap/test-spec-multi-horizon-zig-scheduler-roadmap.md`
- `docs/project-architecture-and-status.md`
- `docs/roadmap/gates/prd-m18-linux-observability-gate.md`
- `docs/roadmap/gates/test-spec-m18-linux-observability-gate.md`

M19 remains **offline, observability-only, version-pinned, scrubbed-fixture only**. No live capture, no in-repo tracing workflows, no replay-fidelity claims, no Linux-performance or calibration claims.

---

## RALPLAN-DR

### Principles
1. **Offline-only truthfulness.** M19 admits only committed scrubbed snapshot fixtures plus manifests; it does not execute capture workflows.
2. **Observability, not replay.** Imported artifacts are teaching/comparison inputs only and must never imply kernel-faithful replay or performance meaning.
3. **Version tuples are part of the contract.** Supported fixture families are approved only as explicit kernel/tool/format/scrub-policy tuples.
4. **Fixture provenance is a first-class surface.** Every admitted fixture must be redistributable, scrubbed, manifested, and caveated.
5. **Separation protects mainline identity.** Linux-observability assets stay visibly separate from simulator-native scenarios, exports, and claims.

### Decision drivers
1. Satisfy ADR 0002’s narrow GO charter without reopening any banned M18 scope.
2. Keep M19 small enough to verify via docs/tests/manifests rather than live-system behavior.
3. Make approved capture families and supported tuples explicit, auditable, and unsupported-by-default.
4. Preserve repo messaging that the implementation today remains simulator-first.
5. Leave M20 blocked by default; do not smuggle comparison/calibration semantics into M19.

### Viable options

#### Option A — Governance-only M19
Ship only fixture manifests, fixture storage layout, wording, and tests; no import parser yet.
- **Pros:** lowest scope and lowest overclaiming risk.
- **Cons:** weak utility; does not satisfy the roadmap’s “import real scheduler trace snapshots” goal.

#### Option B — Recommended narrow M19
Add a minimal offline fixture-ingest lane that reads only committed scrubbed snapshot fixtures from an approved fixture directory, validates manifests/tuple support, and produces a bounded observability-only normalized view for existing downstream analysis surfaces.
- **Pros:** meets M19’s roadmap goal while staying inside ADR 0002.
- **Cons:** still adds governance + parser surface that must be tightly fenced.

#### Option C — Broad ingest/comparison M19
Combine fixture import, normalization, replay-ish mapping, and simulator comparison in one milestone.
- **Why rejected:** collapses M19 into M20 and violates the M18 narrowness band.

### Recommended narrow implementation shape
Adopt **Option B** with a strict three-surface scope:

1. **Committed fixture corpus (new branch-local data surface only)**
   - Separate Linux-observability fixtures from simulator scenarios.
   - Admit only scrubbed committed snapshots with per-fixture manifests.
   - Initial approved capture family:
     - `tracefs-sched-snapshot`
   - Meaning:
     - dedicated tracefs instance
     - only `sched:*` events enabled
     - captured via `snapshot`
     - stored as offline text snapshots plus manifests
   - Explicitly deferred:
     - `perf sched`
     - generic `perf.data`
     - `perf script`
     - trace_pipe/live streams
     - non-sched tracepoints
     - latency tracers and other ftrace tracer families

2. **Version-pinned manifest gate**
   - Each fixture must declare an explicit approved tuple:
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
   - Unsupported tuples fail closed.

3. **Observability-only import boundary**
   - Parse only the committed scrubbed fixture representations needed for offline observability inspection.
   - Normalize only the minimum fields needed to inspect scheduler-event sequences.
   - **Do not widen `zig-scheduler/report` in M19.**
   - Use a separate observability-specific normalized model / summary path for M19 smoke verification.
   - Ban any code paths or wording that imply replay fidelity, calibration, or Linux performance meaning.

### Proposed initial approved tuple set for the draft
Keep the first approval set intentionally tiny:

1. **Tuple T1**
   - `family`: `tracefs-sched-snapshot`
   - `kernel_release`: `linux-6.6`
   - `tool_version`: `tracefs-kernel-6.6`
   - `tracefs_root`: `/sys/kernel/tracing`
   - `capture_recipe`: `instance=m19-snapshot; events=sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit; snapshot=1`
   - `trace_clock`: `global`
   - `enabled_sched_events`: `sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit`
   - `scope`: `system-wide dedicated instance`
   - `mode`: `snapshot`
   - `time_window`: `single bounded snapshot`
   - `snapshot_format_version`: `tracefs-sched-text-v1`
   - `scrub_policy_version`: `linux-observability-scrub-v1`

Draft rule: approve **one concrete tuple only** in the first M19 cut. Tuple expansion and any perf-based family support are follow-on work, not part of initial scope.

### Concrete file / artifact touchpoints

**Planning / governance artifacts**
- new: `docs/roadmap/m19/prd-m19-curated-linux-observability.md`
- new: `docs/roadmap/m19/test-spec-m19-curated-linux-observability.md`
- update: `docs/roadmap/open-questions.md` only if tuple/family decisions remain unresolved

**Docs / proof surfaces**
- update: `README.md`
- update: `docs/project-architecture-and-status.md`
- new: `docs/m19-curated-linux-observability.md` (fixture policy, tuple table, scrub policy, caveats)
- maybe update: `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md` only if M19 wording needs tighter alignment

**Fixture / manifest surfaces**
- new: `fixtures/linux-observability/README.md`
- new: `fixtures/linux-observability/manifests/*.json`
- new: `fixtures/linux-observability/tracefs-sched-snapshot/*`
- new: `fixtures/linux-observability/support-matrix.json`

**Code / test surfaces (narrowest useful cut)**
- new: `src/import/` or `src/observability/` boundary for offline fixture loading only
- update: `src/root.zig` / build wiring only as needed
- new: `src/tests/linux_observability_test.zig`
- update: `src/tests/identity_gate_test.zig`
- no widening of `src/analysis/*` or the `zig-scheduler/report` contract in M19

### Verification shape
1. **Gate audit**
   - confirm M18 approval is referenced before any M19 fixture/code path is active
2. **Fixture admission audit**
   - every committed fixture has a manifest, scrub-policy version, redistribution basis, and approved tuple
3. **Support-matrix audit**
   - only explicitly listed tuples load; unknown tuples fail closed
4. **Boundary audit**
   - no live capture commands, no perf/ftrace/eBPF execution workflow, no capture automation surfaces in repo
   - no `perf sched`, generic `perf.data`, `perf script`, non-sched tracepoints, or `trace_pipe` import path in the initial M19 cut
5. **Observability-only wording audit**
   - README/docs/tests reject replay-fidelity, calibration, and Linux-performance claims
6. **Import smoke**
   - committed fixture -> manifest validation -> normalized offline observability model -> observability-summary smoke
7. **Separation audit**
   - imported Linux fixtures remain segregated from `scenarios/` and simulator-native regression fixtures

### Agent roster
- `planner` — finalize M19 PRD + test spec and lock acceptance criteria
- `architect` — define the narrow import boundary and fixture/manifests separation
- `critic` — challenge scope creep and claim wording
- `writer` — docs/proof-surface updates and scrub/manifest documentation
- `verifier` — governance, wording, tuple, and fixture-admission audits
- `executor` — implementation only after the M19 PRD/test-spec are approved
- `test-engineer` — fixture-admission tests, support-matrix tests, smoke coverage

### Suggested execution mode
- **Now:** remain in `ralplan` / consensus-planning mode until M19 PRD + test spec are approved.
- **For execution after approval:** use **`$team`**.
- Lane 1: manifests + support matrix + fixture layout
- Lane 2: offline tracefs-sched-snapshot loader / bounded normalization
- Lane 3: docs + proof-surface wording
- Lane 4: governance + import smoke tests

### ADR handoff summary
**Decision:** pursue a narrow M19 that is fixture-first, manifest-gated, tuple-pinned, and observability-only.

**Consequences:**
- M19 should land as a governance-heavy offline import milestone, not as trace capture or calibration work.
- M20 stays blocked until M19 proves the fixture/import boundary can remain truthful.
- Any requested tuple expansion, new capture family, or stronger comparison claim should be treated as a new planning decision, not as “small follow-up” within the initial M19 cut.
