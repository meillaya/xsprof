# Worklog

## Current posture (C++ rewrite)

- `main` is the **C++ rewrite** of the project as `xsprof`, a Linux Scheduler & Memory Profiler.
- The complete historical Zig project is preserved on the **`archive/zig-historical`** branch.
- Phase 1 is implemented and verified: Nix devshell (cmake + ninja + bear + clang + libbpf + catch2),
  `libxsprof_core`, the `xsprof` CLI, read-only `/proc`+`/sys` collection, capability probing,
  privacy filter, fail-closed safety gate, Chrome-Trace exporter, and the Performance Advisor.
- Build is green: `cmake -G Ninja` + `bear -- cmake --build` + `ctest` (21 Catch2 cases, all pass);
  `bear` emits `compile_commands.json` for clangd/LSP.
- The fail-closed, evidence-led, privacy-preserving posture is preserved: every read-only record
  carries `host_mutation=false`; unsafe verbs refuse non-zero; mutation is VM-lab-only.

## Verified on this host

- `perf_event_paranoid=2` and `/sys/kernel/tracing/events/sched` permission-denied → perf/tracepoint
  collectors report `SKIP` (fail-closed) without privilege.
- `btf`, `sched_ext`, and `pmu` (incl. AMD `ibs_op`/`ibs_fetch`) report `READY` for read-only use.

## Future-agent notes

- Keep observation read-only and fail-closed; do not auto-elevate or mutate the host.
- Follow `docs/rewrite/IMPLEMENTATION_PLAN.md` for the next phases.
- Do not touch `simulator/` unless explicitly scoped.
- The Zig reference (schemas, daemon contract, safety scripts) lives on `archive/zig-historical`.
- `.omx/`/`.omo/` are local workflow state, not repository behavior.
