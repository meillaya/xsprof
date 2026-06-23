# Scheduler backend next milestones after VM proof

Date: 2026-06-23
Scope: backend-only sched_ext scheduler infrastructure. Frontend/TUI/WebView work remains explicitly deferred. Real-host attach remains out of scope until separately approved with stricter security and rollback evidence.

## Sources and method

This synthesis was produced from an `omo:ultraresearch` pass over the current repository plus upstream scheduler, QEMU, BPF, tracing, and packaging references. Three independent research lanes completed (policy capability, VM/kernel/workload matrix, performance gates). Two local-code lanes hit context exhaustion and were replaced with direct repo inspection of `build.zig`, `src/control/*`, `tools/daemon_stdio_*`, `qa/*`, `docs/ci.md`, `docs/backend-capability-matrix.md`, `docs/security/*`, and `packaging/*`. A host-attach lane was intentionally kept advisory because real-host attach is not currently authorized.

Primary references:

- Linux sched_ext documentation: <https://docs.kernel.org/scheduler/sched-ext.html>
- Linux cgroup v2 documentation: <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- Linux EEVDF scheduler documentation: <https://docs.kernel.org/scheduler/sched-eevdf.html>
- Kernel scheduler statistics: <https://docs.kernel.org/scheduler/sched-stats.html>
- Kernel ftrace documentation: <https://docs.kernel.org/trace/ftrace.html>
- Kernel histogram triggers: <https://docs.kernel.org/trace/histogram.html>
- Kernel timerlat tooling: <https://docs.kernel.org/tools/rtla/rtla-timerlat-top.html>
- Kernel osnoise tooling: <https://docs.kernel.org/tools/rtla/rtla-osnoise.html>
- Kernel workload tracing guide: <https://docs.kernel.org/admin-guide/workload-tracing.html>
- QEMU system invocation: <https://www.qemu.org/docs/master/system/invocation.html>
- QEMU x86 CPU model guidance: <https://www.qemu.org/docs/master/system/i386/cpu.html>
- QEMU system introduction: <https://www.qemu.org/docs/master/system/introduction.html>
- libbpf overview: <https://docs.kernel.org/bpf/libbpf/libbpf_overview.html>
- Linux capabilities: <https://man7.org/linux/man-pages/man7/capabilities.7.html>
- `bpf(2)`: <https://man7.org/linux/man-pages/man2/bpf.2.html>
- systemd execution sandboxing (backend-only; no frontend): <https://www.freedesktop.org/software/systemd/man/systemd.exec.html>
- sched-ext/scx repository: <https://github.com/sched-ext/scx>
- Upstream `scx_simple` example: <https://github.com/torvalds/linux/blob/master/tools/sched_ext/scx_simple.bpf.c>

Local evidence inspected:

- `bpf/zigsched_minimal.bpf.c`
- `bpf/include/zigsched_common.h`
- `build.zig`
- `src/control/daemon_events.zig`
- `src/control/journal_tests.zig`
- `tools/daemon_stdio_test.sh`
- `tools/daemon_stdio_assert.py`
- `qa/live_behavior_check.py`
- `qa/partial_attach_check.py`
- `qa/bpf_artifacts.py`
- `qa/bpf_metadata_repro_check.py`
- `qa/release_gate.sh`
- `qa/package_manifest_check.py`
- `qa/live_bundle_freshness_check.py`
- `docs/backend-capability-matrix.md`
- `docs/ci.md`
- `docs/security/threat-model.md`
- `docs/security/review-checklist.md`
- `packaging/README.md`
- `packaging/build_package.sh`

## Executive synthesis

The backend milestone has crossed the important boundary from abstract simulator/dry-run work to a VM-lab proof path with concrete lifecycle events, rollback IDs, cleanup receipts, release gates, and BPF artifact provenance. The next backend phase should not be frontend work and should not be real-host attach. It should turn the VM proof into a production-grade scheduler backend by improving the policy itself, broadening VM/kernel/workload coverage, adding scheduler-behavior gates, hardening the daemon API contract, and making CI/release automation repeatable.

The correct order is:

1. Expand policy capability from `zigsched_minimal` into an explicitly topology-, metadata-, fairness-, latency-, and observability-aware sched_ext policy.
2. Define a VM evidence matrix so every policy change runs against known kernel, QEMU, topology, and workload tuples.
3. Add performance and correctness gates before claiming scheduler quality.
4. Stabilize daemon/control API schemas as the future integration surface; no frontend is built in this backend-only milestone.
5. Automate host-safe CI, opt-in privileged VM CI, evidence bundling, and release gating.
6. Only after all of that, write a separate real-host attach plan with explicit approval, capability isolation, rollback drills, and security review.

## 1. Expand scheduler policy capability beyond the minimal proof policy

Current local posture is still a proof policy. `bpf/zigsched_minimal.bpf.c` has a compact DSQ policy with FIFO/vtime behavior and partial switching. That is enough to prove verifier/load/attach/rollback mechanics in a disposable VM, but it is not a production scheduler.

Next capabilities:

- CPU placement and topology:
  - implement `select_cpu` behavior rather than relying only on enqueue/dispatch;
  - add local, global, per-LLC, and per-NUMA-domain DSQ design;
  - handle offline/invalid CPUs without stranding runnable tasks;
  - record topology manifest data in every VM evidence bundle.
- Metadata-aware scheduling:
  - ingest cgroup v2 `cpu.weight`, `cpu.max`, `cpu.idle`, and `cpu.uclamp.{min,max}`;
  - track task class/state for latency-sensitive, batch, background, and service workloads;
  - model cgroup moves and property updates as runtime events.
- Fairness and anti-starvation:
  - evolve vtime into per-class or per-domain lag/budget accounting;
  - define starvation budgets and fail if any class violates them;
  - handle infeasible weight mixes without leaving cores idle.
- Latency classes:
  - separate interactive/wakeup-heavy tasks from throughput/batch work;
  - add slice, wakeup, and preemption/kick behavior that can be measured;
  - document each tradeoff as policy behavior, not generic scheduler magic.
- Policy observability:
  - expose per-policy counters, queue depths, fallback/reject counters, dispatch latency, fairness state, and task/cgroup class counts;
  - add dump hooks or structured logs that make incidents debuggable.

Acceptance evidence:

- policy-specific tests for topology placement, cgroup weights, cgroup moves, uclamp/bandwidth, fairness, starvation, latency classes, and offline CPU fallback;
- BPF metadata reproducibility still passes;
- VM-only host-mutation proof remains false;
- rollback remains PASS for every policy cell.

## 2. Run broader VM/kernel/workload matrices

Do not create an uncontrolled Cartesian product. Use a targeted cube with pairwise coverage and deliberate corner cases.

Recommended axes:

- Kernel axis:
  - Linux 6.12.x baseline because sched_ext is upstream from 6.12;
  - current supported stable kernel;
  - tip-of-tree or scx/backports tuple to catch API drift.
- VM axis:
  - KVM + `host-passthrough` + `q35` for realistic performance runs;
  - KVM + named CPU model + `q35` for reproducibility;
  - TCG fallback for no-host-dependency functional checks;
  - explicit topology variants: 1 socket, SMT on/off, 2 sockets/NUMA, cache/LLC variants.
- Workload axis:
  - throughput/IPC: `hackbench`, `perf bench sched messaging`, `perf bench sched pipe`;
  - wakeup latency: `schbench`, `rtla timerlat`, optionally `cyclictest`;
  - mixed pressure: `stress-ng` scheduler/cpu/vm/fork/io classes;
  - read-only/synthetic I/O: `fio --readonly` or disposable synthetic FS;
  - real-world bundle smoke tests only after core gates are stable.
- Negative axis:
  - KVM unavailable;
  - QEMU unavailable;
  - stale `vmlinux.h` or toolchain mismatch;
  - verifier rejection;
  - lost stream/timeout;
  - SysRq-S or process exit rollback;
  - CPU offline during dispatch;
  - rollback failure;
  - cleanup residue;
  - duplicate or stale target/action IDs.

Evidence bundle schema should become stable and include:

- immutable run manifest: git SHA, policy object hash, kernel release/config/BTF, QEMU version, accel, machine type, CPU model, topology, workload, tool versions;
- state proof: `/sys/kernel/sched_ext/state`, root ops, `enable_seq`, `bpftool struct_ops list`;
- workload logs and metrics;
- runtime samples and daemon events;
- rollback/audit ledger;
- cleanup receipt;
- release-gate decision.

## 3. Add performance/latency correctness gates for real scheduler behavior

A production scheduler cannot be gated by “it loaded” or “throughput did not obviously fail.” The gate stack should be layered:

1. State correctness:
   - expected sched_ext state is enabled inside the disposable VM during measurement;
   - expected policy name is active;
   - `enable_seq` does not drift during steady-state;
   - partial-switch behavior is exactly what the policy claims.
2. sched_ext native counters:
   - fail on unexpected `SCX_EV_SELECT_CPU_FALLBACK`, dispatch-offline, reenq-repeat, bypass, insert-not-owned, or skip-migration deltas unless a test explicitly expects them.
3. Tail-latency gates:
   - collect `perf sched timehist`, ftrace wakeup/switch histograms, and `rtla timerlat`;
   - enforce p95/p99/max budgets per workload class.
4. Noise and repeatability gates:
   - record `rtla osnoise` or equivalent;
   - isolate CPUs for benchmark runs where possible;
   - fail on excessive run-to-run variance.
5. Fairness gates:
   - define fairness per policy: equal share, weighted share, cgroup share, or latency-priority share;
   - gate using `/proc/<pid>/schedstat`, `/proc/schedstat`, policy counters, and workload accounting.
6. Migration/locality gates:
   - record migrations per work unit and unexpected migration of pinned/isolated work;
   - fail when migration rate rises without a corresponding latency improvement.
7. Trace contract gates:
   - require traces for `sched_switch`, `sched_wakeup`, `sched_migrate_task`, and any `sched_ext_dump` in clean runs;
   - hard-fail clean runs on unexpected dump/fallback events.

Important caveats:

- `/proc/schedstat` is versioned; parsers must include kernel-version awareness.
- `bpf_stats_enabled`, schedstats, and tracing can perturb performance; keep telemetry and benchmark modes explicit.
- Fairness is policy-specific. Do not hardcode one universal fairness metric as “correct” for all schedulers.

## 4. Harden daemon/control APIs as the stable integration surface; no frontend work

The current daemon surface is already a good seed: it emits `zig-scheduler/daemon-event/v1`, tracks active targets, refuses duplicate/stale targets, and has journal replay tests for rollback/cleanup. The next milestone is to make it a formal API contract independent of any UI.

Next hardening tasks:

- Publish event and action schemas:
  - JSON Schema for `zig-scheduler/operator-action/v1` and `zig-scheduler/daemon-event/v1`;
  - stable enum list for lifecycle, runtime sample, rollback, cleanup, validation, refusal, and incident events;
  - explicit versioning/deprecation rules.
- Golden transcript tests:
  - maintain fixture transcripts for queued, booting, verifier, attached, observing, rollback-ready, rollback-active, cleaned, and incident paths;
  - assert monotonic sequence, action ID linkage, target ID linkage, rollback ID linkage, artifact presence, and `host_mutation=false`.
- Replay and backpressure:
  - bound journal size and stream output;
  - make lost-stream and timeout first-class incident rows;
  - define resume-from-sequence semantics as a backend contract; no frontend is implemented here.
- Idempotent controls:
  - stop and rollback must remain active-target operations only;
  - stale/duplicate target IDs remain visible refusals;
  - failed rollback/cleanup must keep target active or incident-visible until explicitly handled.
- Security/privacy:
  - keep command-line and environment privacy filters mandatory;
  - validate artifacts are inside expected evidence roots and not symlink escapes;
  - keep host mutation false in all ordinary host-safe daemon modes.

The goal is that any later integration client can be thin: no frontend is implemented here, and future clients should render authoritative daemon state rather than reconstructing scheduler state themselves.

## 5. Add CI/release automation for the VM proof path

Current `docs/ci.md` already splits host-safe CI from opt-in privileged VM checks. That split should be implemented as automation, not just documentation.

Recommended lanes:

- Host-safe lane on every push/PR:
  - `zig build test --summary all`;
  - BPF compile/metadata check in compile-or-SKIP mode only;
  - preflight JSON and CLI help contract;
  - unsafe CLI refusal matrix;
  - no-host-mutation checks;
  - no-frontend-root and simulator untouched checks (no frontend artifacts);
  - vendor Zig docs check;
  - package manifest/defaults checks.
- Privileged VM lane, opt-in only:
  - gated by label/manual dispatch/environment flag;
  - runs only on a runner dedicated to disposable VM experiments;
  - emits SKIP with `host_mutation=false` if QEMU/KVM/kernel inputs are missing;
  - runs verifier-only, partial attach, runtime observation, rollback, cleanup, and incident drills inside the VM path.
- Release proof lane:
  - consumes the latest VM evidence bundle;
  - validates freshness against current git SHA;
  - checks bundle schemas, rollback/audit, cleanup, security review, package manifest, and no frontend/simulator payload;
  - produces artifact hash manifest and signed/owner approval only for controlled-lab candidates.

Automation gaps to close:

- add machine-readable evidence manifest schema;
- add artifact hashing for every release bundle;
- add workflow or script wrappers that never hide privileged mutation in ordinary CI;
- add package build checks for symlink/path escape and inert defaults;
- archive VM evidence separately from source-controlled docs.

## 6. Guarded real-host attach, later only

Real-host attach should remain deferred. When/if explicitly approved later, prerequisites should include:

- a separate threat model and security review for real-host mutation;
- clear Linux capability requirements (`CAP_BPF`, `CAP_PERFMON`, potentially `CAP_SYS_ADMIN` depending on kernel/tooling path);
- systemd hardening with least privilege, no auto-start, constrained filesystem access, and explicit operator activation;
- canary cgroup or partial-switch-only first rollout;
- tested rollback via normal detach, sched_ext watchdog/revert, process-exit revert, and SysRq-S fallback;
- operator audit IDs and rollback IDs for every mutation;
- live incident handling for lost stream, timeout, rollback failure, and cleanup residue;
- a dedicated “stop now” path that is tested under load;
- owner approval separate from VM-lab approval.

Until those prerequisites are satisfied, real-host attach should remain a refusal path, not an experimental hidden flag.

## Final recommended next implementation plan

1. Write `docs/scheduler-policy-roadmap.md` and `docs/vm-evidence-matrix.md` from this synthesis.
2. Add JSON schema files for daemon actions/events and evidence manifests.
3. Add VM matrix runner scaffolding that can enumerate kernels, QEMU accel/cpu/topology, and workload cells without mutating the host.
4. Implement topology-aware policy iteration 1: CPU selection, local/global/per-domain DSQs, fallback counters, and policy telemetry.
5. Add correctness gates: sched_ext state, sched_ext events, timerlat/osnoise, perf sched, fairness/migration checks.
6. Wire those gates into opt-in privileged VM CI and release-gate evidence.
7. Only after repeated VM evidence is green, plan the separate real-host attach safety program.

## Deferred and non-goals

- No frontend, TUI, WebView, browser, desktop, theme, or animation work.
- No simulator changes.
- No production readiness claim.
- No ordinary host attach, BPF load, cgroup/cpuset/affinity/priority mutation, or scheduler mutation outside the disposable VM lab path.
