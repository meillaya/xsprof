# Worklog

## Current posture (C++ rewrite — all phases complete)

- `main` is the **C++ rewrite** of the project as `xsprof`, a Linux Scheduler & Memory Profiler.
- The complete historical Zig project is preserved on the **`archive/zig-historical`** branch.
- All implementation phases (1 through 7) are complete and verified.

## Phase completion record

### Phase 1 — Skeleton + read-only fail-closed core
- Nix devshell (cmake + ninja + bear + clang + libbpf + catch2).
- `libxsprof_core`, the `xsprof` CLI, read-only `/proc`+`/sys` collection, capability probing.
- Privacy filter, fail-closed safety gate, Chrome-Trace exporter, Performance Advisor skeleton.

### Phase 1.5 — Frozen contracts
- Pipeline header, golden fixtures, per-module CMake, VM harness.

### Phase 2 — Scheduler collectors (G002)
- Context switches, wakeups, migrations, run-queue sampling via `/proc/schedstat`.
- Wakeup-to-switch correlation with configurable window.
- Capability-gated SKIP when `perf_event_paranoid=2` (fail-closed, never auto-elevate).

### Phase 3 — Memory collectors (G003)
- Page faults, TLB misses, cache misses, buddyinfo fragmentation, hugepages, NUMA maps.
- AMD IBS probe (read-only).
- Capability-gated SKIP when unprivileged.

### Phase 4 — Chrome-Trace timeline
- Window selection (`--window start:end`), chunked output (`--chunk-size N`).
- Replay from recorded JSONL journal.
- Lost/gapped streams render as explicit unsafe markers (never interpolated).

### Phase 5 — Performance Advisor (G005)
- Seven detection rules: false sharing, excessive locking, unnecessary wakeups, CPU affinity churn,
  poor NUMA placement, allocator fragmentation, priority inversion.
- All rules wired to configurable named thresholds.
- Recommendations are printed suggestions only — never auto-applied.

### Phase 6 — BPF CO-RE loader (G006) + daemon parity (G007)
- BPF loader refuses on host (fail-closed); SKIP without libbpf/BTF.
- Daemon: foreground stdio JSONL, event replay with schema/monotonic-seq validation,
  operator-action dispatch, local UDS JSON-RPC.
- Every daemon event carries `host_mutation=false`.

### Phase 6b — Safety hardening
- Unsafe-verb matrix re-expressed in C++ tests (all 9 verbs refuse non-zero).
- Privacy and safety tests re-expressed and green.

### Phase 7 — QA-gate parity + CI + docs (G008)
- QA-gate parity confirmed: `no_host_mutation`, `unsafe_cli_matrix`, `path_safety`,
  `runtime_sample privacy`, `capability SKIP`, `advisor never auto-applies`, `BPF host refusal`
  all re-expressed in C++ tests (115 Catch2 tests, all green).
- CLI integration tests added (`tests/cli_tests.cpp`): actual binary refuses unsafe verbs with
  non-zero exit, read-only commands succeed with `host_mutation=false`.
- GitHub Actions CI workflow (`.github/workflows/cpp-ci.yml`): Nix devshell → cmake + Ninja →
  bear → ctest → clang-format check.
- `.clang-format` committed (LLVM-based, 4-space indent, 100-col limit); all source formatted.
- README, WORKLOG, and AGENTS guidance finalized for the completed C++ posture.

## Verified on this host

- `perf_event_paranoid=2` and `/sys/kernel/tracing/events/sched` permission-denied → perf/tracepoint
  collectors report `SKIP` (fail-closed) without privilege.
- `btf`, `sched_ext`, and `pmu` (incl. AMD `ibs_op`/`ibs_fetch`) report `READY` for read-only use.
- 115 Catch2 tests pass; clang-format check clean; bear generates `compile_commands.json`.

## Future-agent notes

- Keep observation read-only and fail-closed; do not auto-elevate or mutate the host.
- Do not touch `simulator/` unless explicitly scoped.
- The Zig reference (schemas, daemon contract, safety scripts) lives on `archive/zig-historical`.
- `.omx/`/`.omo/` are local workflow state, not repository behavior.
- Run `nix develop --command bash -c 'cmake -S . -B build -G Ninja && bear -- cmake --build build -j && ctest --test-dir build --output-on-failure'` to verify.
