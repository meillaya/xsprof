# ARCHITECTURE — C++ Rewrite of zig-scheduler as a Linux Scheduler & Memory Profiler

Status: research deliverable (autoresearch-goal mission `cpp-sched-mem-profiler`).
This is the component architecture for the complete C++ rewrite/refactor.

## 1. Intent and product identity

The project (working name **exasphere**, CLI `xsprof`) becomes a userspace framework that
visualizes and analyzes Linux scheduling and memory behavior in real time. It combines ideas
from `perf`, `htop`, `bpftrace`, Intel VTune, and FlameGraph, while adding cross-cutting
analyses those tools do not provide directly: a single event model that correlates scheduler
events with memory events, and a Performance Advisor that turns correlated evidence into
concrete `sched_setaffinity(...)` and NUMA placement recommendations.

The rewrite is **complete**: the Zig sources under `src/` are superseded by a modern C++ (C++23)
codebase. The deterministic Zig simulator under `simulator/` is left untouched (separate guidance)
but its scenario vocabulary informs the synthetic-fixture test path.

## 2. Top-level component diagram

```
                         +---------------------------------------------+
   tracefs / perf FDs --> |                Collectors                  |
   /proc, /sys, BTF   --> |  sched | memory | proc-topology | bpf      |
                         +-------------------+-------------------------+
                                             | RawEvent (typed variant)
                                             v
                         +---------------------------------------------+
                         |            Core event pipeline             |
                         |  ring buffer -> correlate -> aggregate      |
                         +-------------------+-------------------------+
                                             |
              +------------------------------+------------------------------+
              v                              v                              v
   +---------------------+      +------------------------+     +------------------------+
   | Visualization sink  |      |   Performance Advisor  |     |   Evidence / journal   |
   | Chrome Trace JSON   |      | rule engine + reports  |     | append-only, privacy   |
   | (interactive tl)    |      | affinity/NUMA hints    |     | filtered, fail-closed  |
   +---------------------+      +------------------------+     +------------------------+
                                             ^
                         +-------------------+-------------------------+
                         |          Safety / capability gate           |
                         |  read-only default, opt-in mutation, refuse |
                         +---------------------------------------------+
```

## 3. Module boundaries

| Module | Path | Responsibility | Depends on |
| --- | --- | --- | --- |
| `core` | `src/core/` | Event model (typed variant), ring buffer, correlation IDs, time base (CLOCK_MONOTONIC + perf clock), JSON writers, privacy filter | fmt, nlohmann/json |
| `collectors` | `src/collectors/` | Read kernel interfaces into `RawEvent`s; each collector reports a capability + degrade reason | core, libbpf, libperf wrappers |
| `bpf` | `bpf/`, `src/bpf/` | CO-RE BPF objects (sched + memory), skeleton loading via libbpf, ringbuf drain | libbpf, libelf, libzstd, clang/bpf |
| `advisor` | `src/advisor/` | Rule engine over aggregates; emits findings + recommendations | core |
| `viz` | `src/viz/` | Chrome Trace Event Format exporter; scrubber metadata (per-thread/per-CPU rows) | core |
| `safety` | `src/safety/` | Capability detection, fail-closed gating, refusal/incident records, path safety | core |
| `cli` | `src/cli/` | Argument parsing, subcommands (`preflight`, `record`, `report`, `advise`, `daemon`) | all libs |
| `daemon` | `src/daemon/` | Foreground stdio JSONL + local UDS JSON-RPC, replay (mirrors Zig daemon contract) | core, safety |

Dependency rule: `core` and `safety` depend on nothing internal; every other module depends on
`core`; mutation-capable code paths depend on `safety`. No collector may write scheduler or memory
policy without going through `safety` (which refuses by default).

## 4. Data model

A single tagged variant is the spine of the system:

```cpp
enum class EventKind : uint16_t {
  // scheduler
  SchedSwitch, SchedWakeup, SchedMigrate, RunqueueSample, PriorityInversion, LockContention,
  // memory
  PageFault, TlbMiss, CacheMiss, HugePage, NumaBalance, AllocSample, MallocHotspot,
  // control / lifecycle
  Marker, Capability, Refusal, Incident, RuntimeSample,
};

struct RawEvent {
  EventKind kind;
  uint64_t ts_ns;        // perf-clock nanoseconds
  int32_t  cpu;
  int32_t  pid, tid;
  uint64_t a, b, c;      // kind-specific packed payloads
  // correlation: wakeup->switch chain via (pid,tid) and prev/next comm
};
```

Aggregates (per-CPU run-queue occupancy, per-thread wait/run time, per-VMA fault rates,
per-alloc-site hotspot counts) are derived in the pipeline and feed both the advisor and the
visualization metadata.

## 5. Threading model

- **One collector thread per source** (sched ringbuf, memory ringbuf, perf mmap, /proc poller).
- **Single pipeline thread** owns correlation + aggregation (SPSC ring buffers feed it) to avoid
  locks on the hot path.
- **Sink threads** for viz export and journal append are downstream and batched.
- Backpressure: when a ring buffer is > high-watermark, drop oldest and emit a `Marker`
  (sample-loss) event; the viz/advisor treat loss as an explicit unsafe/incomplete signal, never
  silently interpolated (mirrors the Zig "lost/gapped stream is unsafe" rule).

## 6. Data flow for the headline analyses

- **Context switch / run queue**: `sched_switch` tracepoint (or BPF raw_tracepoint) -> per-CPU
  prev/next intervals -> run-queue occupancy timeline + per-thread run/wait.
- **Wakeups + unnecessary wakeup detection**: `sched_wakeup`/`sched_waking` correlated to the next
  `sched_switch` for the woken task; wakeups that do not lead to a switch within a window are
  flagged by the advisor.
- **Migrations + NUMA placement**: `sched_migrate_task` + `numa_balancing` tracepoints + per-task
  current node from `/proc/<pid>/numa_maps`; advisor compares placement vs. memory locality.
- **Priority inversion**: detect a high-prio task blocked on a lock held by a low-prio task that is
  itself preempted (BPF lock-owner tracking + `sched_switch`).
- **Memory**: `perf_event_open` for page faults (software), dTLB-load-misses, LLC/cache misses,
  plus AMD IBS (`ibs_op`) where present; huge-page and fragmentation from `/proc/meminfo`,
  `/sys/kernel/mm/hugepages`, `/proc/buddyinfo`.
- **malloc hotspots / allocator fragmentation**: optional `LD_PRELOAD` shim (`libxsprof_alloc`)
  records alloc/free size+stack into a ringbuf; offline this feeds hotspot + fragmentation analysis.

## 7. Output contracts

- **Chrome Trace Event Format** (`viz`): `{"traceEvents":[...], "metadata":...}` with per-CPU and
  per-thread rows, flow events for wakeup->switch arrows, and a scrubber-friendly time axis. This is
  the interactive-timeline artifact (openable in `chrome://tracing` / Perfetto UI).
- **Evidence journal** (append-only JSONL): every record keeps `host_mutation=false` for read-only
  collection; mutation attempts emit `refusal`/`incident` records. Privacy filter strips argv, env,
  and anything matching secret/key/token/password patterns from runtime samples.
- **Advisor report** (JSON + human markdown): findings with severity, the evidence rows that back
  each finding, and concrete recommendations (`sched_setaffinity(pid, mask)`, NUMA bind/migrate
  hints), each labeled evidence-backed vs. heuristic.

## 8. Why C++ (and why this shape)

- eBPF/perf tooling (libbpf, perf_event_open, PMU/IBS) is C-ABI native; C++23 gives RAII over raw
  FDs, `std::variant` for the event model, and zero-cost abstractions for the hot pipeline.
- CMake + Ninja inside a Nix devshell gives a reproducible build that pins clang/llvm (for BPF
  CO-RE), libbpf, libelf, libzstd, fmt, nlohmann_json, and a test framework.
- The library-first layout (`libxsprof`) lets the same collectors be driven by the CLI, the daemon,
  and tests, mirroring the Zig project's contract-first discipline.

## 9. Evidence vs. inference

Grounded on this host (source: live probes recorded in `docs/rewrite/NIX_DEV_ENV.md` and
`SAFETY.md`): `CONFIG_SCHED_CLASS_EXT=y`, `/sys/kernel/sched_ext` present, BTF at
`/sys/kernel/btf/vmlinux`, libbpf 1.7.0, clang 22 with a `bpf` target, AMD `ibs_op`/`ibs_fetch`
PMUs, `perf_event_paranoid=2` and `/sys/kernel/tracing/events/sched` permission-denied for the
unprivileged user. Assumption (labeled): full tracepoint/PMU collection requires `CAP_PERFMON`/
`CAP_SYS_ADMIN` or `perf_event_paranoid<=1`; without it the framework fails closed to SKIP/REFUSE.
