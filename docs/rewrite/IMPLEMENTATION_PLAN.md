# IMPLEMENTATION_PLAN — Phased C++ Rewrite

Research deliverable for mission `cpp-sched-mem-profiler`. The rewrite is delivered in phases so a
building, tested increment exists at every milestone. Phase 1 compiles and runs read-only collection
on the current host (fail-closed), satisfying rubric criterion F.

## 0. Repository transition

- New C++ tree lives at the repo root: `src/` (C++), `include/xsprof/` (public headers), `bpf/`
  (CO-RE objects), `tests/`, `nix/`, `flake.nix`, `CMakeLists.txt`.
- The Zig sources are moved to `legacy/zig/` (preserved, not deleted) so the safety contract and
  schemas remain referenceable; `simulator/` is left untouched per its own guidance.
- `schemas/control/` JSON schemas and `fixtures/` are kept and re-expressed as C++ enums + golden
  tests to preserve contract lockstep.

## 1. Phases & milestones

### Phase 1 — Skeleton + read-only core (FIRST BUILDING INCREMENT)
- `flake.nix`/`shell.nix` + `CMakeLists.txt` (cmake+ninja, clang).
- `core`: `RawEvent` variant, ring buffer, JSON writer, `PrivacyFilter`, time base.
- `safety`: `SafetyGate` (refuse-by-default), `SafePath`, capability detection.
- `collectors/proc`: read-only `/proc/stat`, `/proc/meminfo`, `/proc/buddyinfo`, `/proc/<pid>/numa_maps`
  (own proc), `/sys/kernel/sched_ext` state, `/sys/kernel/mm/hugepages`.
- `cli`: `xsprof preflight --json`, `xsprof --help`; unsafe verbs refuse non-zero.
- `tests`: Catch2 unit tests for JSON writer, privacy filter, safe-path, proc parsers; golden fixture.
- **Acceptance**: `nix develop --command cmake --build build` succeeds; `ctest` green;
  `xsprof preflight --json` emits read-only facts with `host_mutation=false`; unsafe verbs refuse.

### Phase 2 — Scheduler collectors (capability-gated)
- `collectors/sched`: tracepoint `sched_switch`/`sched_wakeup`/`sched_migrate_task` via
  `perf_event_open`, with `probe()` -> `SKIP (perf_event_paranoid=2)` when unprivileged.
- run-queue sampling from `/proc/schedstat` + `/proc/stat`.
- pipeline correlation: wakeup->switch chains, per-thread run/wait, per-CPU occupancy.
- **Acceptance**: with `CAP_PERFMON` (or paranoid<=1) the sched timeline populates; without it the
  capability table shows `SKIP` and the run still succeeds (fail closed).

### Phase 3 — Memory collectors
- `collectors/memory`: `perf_event_open` software page faults; HW_CACHE dTLB/LLC misses; AMD IBS
  `ibs_op` path; hugepages/buddyinfo/numa_maps pollers.
- optional `libxsprof_alloc` LD_PRELOAD shim for malloc hotspots (opt-in).
- **Acceptance**: page-fault + cache-miss samples appear under privilege; degrade to SKIP otherwise.

### Phase 4 — Visualization timeline
- `viz`: Chrome Trace Event Format exporter (CPU lanes, thread lanes, flow events for wakeup/migration,
  instant markers for faults, sample-loss markers), `--window`, chunked output, replay-from-journal.
- **Acceptance**: a recorded journal exports to a valid `trace.json` openable in chrome://tracing /
  Perfetto; lost/gapped streams render as explicit unsafe markers.

### Phase 5 — Performance Advisor
- `advisor`: rule engine + the seven detection rules + `sched_setaffinity`/NUMA recommendation
  synthesis; `report.json` + `report.md`.
- **Acceptance**: rules fire on stressed golden fixtures and stay silent on healthy baselines;
  recommendations are printed, never auto-applied.

### Phase 6 — BPF (CO-RE) + daemon parity
- `bpf`: CO-RE sched + memory BPF objects, libbpf skeleton loading gated to VM-lab only.
- `daemon`: foreground stdio JSONL + local UDS JSON-RPC + replay, mirroring the Zig daemon contract.
- **Acceptance**: BPF load refuses on host; daemon replay reproduces a golden transcript with
  `host_mutation=false` on every record.

### Phase 7 — QA gate parity + docs
- Re-express `no_host_mutation`, `unsafe_cli_matrix`, `path_safety`, `runtime_sample` privacy as C++
  tests/scripts; update README/WORKLOG/AGENTS to describe the C++ posture.
- **Acceptance**: the full gate suite passes; docs match behavior.

## 2. Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| Unprivileged host can't open tracepoints/PMU (paranoid=2) | capability-gated collectors; Phase 1 works read-only; document `CAP_PERFMON` |
| BPF CO-RE needs vmlinux.h per kernel | generate from `/sys/kernel/btf/vmlinux`; SKIP if absent |
| Tracepoint ABI varies by kernel | read field layout from `events/.../format` or CO-RE; no hardcoded offsets |
| Scope creep beyond vision | phase acceptance criteria + advisor prints suggestions only |
| Breaking the safety contract | `safety` module + golden `host_mutation=false` tests in every phase |

## 3. Definition of done (whole mission)

- The C++ project builds with cmake+ninja inside `nix develop` and `ctest` is green.
- `xsprof preflight --json` works read-only on the host; unsafe verbs refuse non-zero.
- Scheduler + memory collectors populate under privilege and fail closed without it.
- A Chrome-Trace timeline and an advisor report can be generated from a capture/fixture.
- The fail-closed, evidence-led, privacy-preserving posture is preserved and tested.
- Docs (README/WORKLOG/AGENTS + `docs/rewrite/*`) match the implemented behavior.

## 4. Evidence vs. inference

Grounded: phase acceptance criteria reference probed host capabilities (paranoid=2, BTF present,
libbpf 1.7.0) and the Zig contract files. Assumption (labeled): phases 2/3 full-fidelity collection is
validated under elevated privilege in the VM lab; on the unprivileged host they are exercised in their
fail-closed SKIP path, which is itself a tested behavior.
