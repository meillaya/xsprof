# exasphere / xsprof — Linux Scheduler & Memory Profiler

`xsprof` is a userspace framework that visualizes and analyzes Linux scheduling and memory
behavior, combining ideas from `perf`, `htop`, `bpftrace`, Intel VTune, and FlameGraph while adding
cross-cutting analyses those tools do not provide directly. It is a **complete C++ rewrite** of the
former Zig `zig-scheduler` operator project.

> The historical Zig project is preserved on the **`archive/zig-historical`** branch. This branch
> (`main`) is the C++ rewrite. The deterministic Zig simulator remains under [`simulator/`](simulator/)
> with its own guidance.

## Components

- **Scheduler tracking** — context switches, wakeups, migrations, NUMA placement, CPU utilization,
  run queues, priority inversion, lock contention (sched tracepoints + sched_ext + BPF CO-RE).
- **Memory tracking** — page faults, TLB misses, huge pages, cache misses, NUMA locality, allocator
  fragmentation, malloc hotspots (perf events + PMU/AMD IBS + `/proc`).
- **Visualization** — interactive Chrome-Trace-style timeline (per-thread / per-CPU / per-syscall
  rows, wakeup→switch flow arrows), openable in `chrome://tracing` and the Perfetto UI.
- **Performance Advisor** — detects false sharing, excessive locking, unnecessary wakeups, CPU
  affinity issues, poor NUMA placement, allocator inefficiencies, and emits `sched_setaffinity(...)`
  / NUMA placement **recommendations** (suggestions only — never auto-applied).

## Safety model (preserved from the Zig project)

- **Read-only by default.** Observation never mutates scheduler or memory policy.
- **`host_mutation=false`** on every read-only record.
- **Unsafe verbs refuse** (`load`, `attach`, `enable`, `mutate`, `apply`, …) with a non-zero exit.
- **VM-lab-only mutation** with audit-id + rollback-id + lab marker; the host build refuses.
- **Privacy filtering** — runtime samples never expose argv, environment, or secrets.
- **Fail-closed** — collectors that need privilege `probe()` and report `SKIP`/`REFUSE` instead of
  failing silently or auto-elevating.

## Build (Nix devshell: cmake + ninja + bear)

```bash
nix develop                                  # clang/llvm, cmake, ninja, bear, libbpf, catch2, ...
cmake -S . -B build -G Ninja
bear -- cmake --build build -j               # bear generates compile_commands.json for clangd/LSP
ctest --test-dir build --output-on-failure   # Catch2 suite
```

Non-flake fallback: `nix-shell ./shell.nix`. A Nix-independent smoke build also works:

```bash
g++ -std=c++20 -Iinclude -Isrc src/core/*.cpp src/safety/*.cpp src/collectors/*.cpp \
    src/viz/*.cpp src/advisor/*.cpp tests/selftest.cpp -o selftest && ./selftest
```

## Usage

```bash
./build/xsprof --help
./build/xsprof preflight --json      # read-only host facts + capability probes (host_mutation=false)
./build/xsprof capabilities --json   # perf/tracepoint/BPF/PMU/sched_ext capability table
./build/xsprof advise --md           # Performance Advisor report (markdown)
./build/xsprof timeline --input journal.jsonl --json   # Chrome Trace timeline (Phase-1 skeleton)
./build/xsprof attach                # REFUSED (fail-closed), non-zero exit
```

## Layout

```
include/xsprof/   public headers (json, event, ring_buffer, privacy, safety, proc, chrome_trace, advisor)
src/              core / safety / collectors / viz / advisor / cli
bpf/              CO-RE BPF objects (VM-lab-only load; Phase 6)
tests/            Catch2 suite + Nix-independent selftest
nix/, flake.nix   reproducible dev environment
docs/rewrite/     research deliverables (architecture, collectors, advisor, viz, safety, nix, plan)
schemas/, fixtures/, evidence/, qa/   contract + governance carried over from the Zig project
simulator/        archived deterministic simulator (separate guidance)
```

## Status

Phase 1 (skeleton + read-only fail-closed core) is implemented, building, and tested. See
[`docs/rewrite/IMPLEMENTATION_PLAN.md`](docs/rewrite/IMPLEMENTATION_PLAN.md) for the phased roadmap
(scheduler collectors → memory collectors → timeline → advisor → BPF/daemon → QA parity).
