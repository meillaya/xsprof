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
  rows, wakeup→switch flow arrows), openable in `chrome://tracing` and the Perfetto UI. Supports
  windowed replay (`--window start:end`) and chunked output (`--chunk-size N`) for large captures.
- **Performance Advisor** — detects false sharing, excessive locking, unnecessary wakeups, CPU
  affinity churn, poor NUMA placement, allocator fragmentation, and priority inversion. Emits
  `sched_setaffinity(...)` / NUMA placement **recommendations** (suggestions only — never
  auto-applied). All seven rules are wired to configurable named thresholds.
- **BPF CO-RE loader** — loads `sched_monitor` and `mem_monitor` BPF programs via libbpf CO-RE.
  The host build refuses to load (fail-closed); loading is VM-lab-only with audit-id + rollback-id
  + lab marker. When libbpf or BTF is unavailable, the loader reports `SKIP` instead of failing.
- **Daemon** — foreground stdio JSONL daemon with event replay, operator-action dispatch, and
  local Unix-domain-socket JSON-RPC. Every daemon event carries `host_mutation=false`. Replay
  validates schema, monotonic sequence, and rejects `host_mutation=true`.

## Safety model (preserved from the Zig project)

- **Read-only by default.** Observation never mutates scheduler or memory policy.
- **`host_mutation=false`** on every read-only record and every daemon replay record.
- **Unsafe verbs refuse** (`load`, `attach`, `enable`, `mutate`, `apply`, `sched-ext-attach`,
  `setaffinity`, `setpriority`, `bind`) with a non-zero exit.
- **VM-lab-only mutation** with audit-id + rollback-id + lab marker; the host build refuses.
- **Privacy filtering** — runtime samples never expose argv, environment, or secrets. Sensitive
  key=value pairs are redacted; comm is bounded to the kernel 15-char limit.
- **Fail-closed** — collectors that need privilege `probe()` and report `SKIP`/`REFUSE` instead of
  failing silently or auto-elevating. The safety gate refuses by default and never suggests
  privilege escalation.
- **Advisor recommendations are printed suggestions only — never auto-applied.**

## Build (Nix devshell: cmake + ninja + bear)

```bash
nix develop                                  # clang/llvm, cmake, ninja, bear, libbpf, catch2, ...
cmake -S . -B build -G Ninja
bear -- cmake --build build -j               # bear generates compile_commands.json for clangd/LSP
ctest --test-dir build --output-on-failure   # Catch2 suite (118 tests)
```

Non-flake fallback: `nix-shell ./shell.nix`. A Nix-independent smoke build also works:

```bash
g++ -std=c++20 -Iinclude -Isrc src/core/*.cpp src/safety/*.cpp src/collectors/*.cpp \
    src/viz/*.cpp src/advisor/*.cpp tests/selftest.cpp -o selftest && ./selftest
```

### clang-format

A `.clang-format` file (LLVM-based, 4-space indent, 100-col limit) is committed. CI enforces it:

```bash
nix develop --command bash -c 'find src include tests -name "*.cpp" -o -name "*.hpp" | grep -v bpf/vmlinux.h | xargs clang-format -i'
```

## CI

The GitHub Actions workflow [`.github/workflows/cpp-ci.yml`](.github/workflows/cpp-ci.yml) enters
the Nix dev environment and runs:

1. `cmake -S . -B build -G Ninja` — configure with the Ninja generator
2. `bear -- cmake --build build -j` — build + generate `compile_commands.json`
3. `ctest --test-dir build --output-on-failure` — run the full Catch2 suite
4. `clang-format --dry-run --Werror` — verify formatting on all `src/`, `include/`, `tests/` files

The existing [`manual-vm-proof.yml`](.github/workflows/manual-vm-proof.yml) remains for
reviewer-gated disposable VM proof (Zig-era governance surface).

## Usage

```bash
./build/xsprof --help
./build/xsprof preflight --json      # read-only host facts + capability probes (host_mutation=false)
./build/xsprof capabilities --json   # perf/tracepoint/BPF/PMU/sched_ext capability table
./build/xsprof advise --md           # Performance Advisor report (markdown)
./build/xsprof advise --json         # Performance Advisor report (JSON)
./build/xsprof timeline --input journal.jsonl   # Chrome Trace timeline
./build/xsprof timeline --input journal.jsonl --window 1000:5000 --chunk-size 100
./build/xsprof attach                # REFUSED (fail-closed), non-zero exit
```

## QA-gate parity

The C++ test suite re-expresses the Zig-era QA gates:

| Gate | C++ test coverage |
|------|-------------------|
| `no_host_mutation` | `daemon_tests.cpp`, `privacy_tests.cpp`, `schema_tests.cpp`, `pipeline_tests.cpp`, `sched_collector_tests.cpp`, `memory_collector_tests.cpp`, `advisor_tests.cpp` — every serialized record carries `host_mutation=false` |
| `unsafe_cli_matrix` | `safety_tests.cpp` (unit) + `cli_tests.cpp` (integration: all 9 unsafe verbs refuse with non-zero exit) |
| `path_safety` | `safety_tests.cpp` — `SafePath::under` confines to state dir, rejects absolute and `../` traversal |
| `runtime_sample privacy` | `privacy_tests.cpp` — redacts secrets, bounds comm, sanitizes events; `event_to_json` applies privacy |
| `capability SKIP` | `sched_collector_tests.cpp`, `memory_collector_tests.cpp` — probes return SKIP/REFUSE when unprivileged |
| `advisor never auto-applies` | `advisor_tests.cpp` — recommendations are suggestions only |
| `BPF host refusal` | `bpf_loader_tests.cpp` — loader refuses on host, SKIP without libbpf/BTF |

## Layout

```
include/xsprof/   public headers (json, event, ring_buffer, privacy, safety, proc, chrome_trace, advisor, daemon, bpf_loader, pipeline, sched_collector, memory_collector)
src/              core / safety / collectors / viz / advisor / bpf / daemon / pipeline / sched / memory / cli
bpf/              CO-RE BPF objects (VM-lab-only load)
tests/            Catch2 suite (118 tests) + Nix-independent selftest + fixtures
nix/, flake.nix   reproducible dev environment
.github/workflows/  cpp-ci.yml (build+test+format) + manual-vm-proof.yml (VM governance)
docs/             ADRs, runbooks, rewrite research, CI docs, security
schemas/, fixtures/, evidence/, qa/   contract + governance carried over from the Zig project
simulator/        archived deterministic simulator (separate guidance)
```

## Validation evidence

The profiling pipeline is validated end-to-end in a disposable microVM (QEMU + KVM,
linux 6.18.38, `perf_event_paranoid` lowered inside the VM). The host stays fail-closed.

- **Live capture (perf tracepoints):** `xsprof record` captured real scheduler/memory
  events (e.g. 634 events: sched_switch, wakeup, migrate, page faults) via
  `perf_event_open` ring buffers (`source: perf_tracepoint`).
- **Live capture (BPF CO-RE):** the libbpf loader loaded `sched_monitor.bpf.o`,
  attached to the sched tracepoints, and streamed real events through the BPF ring
  buffer (e.g. 60 events; `source: bpf_core`). See [`evidence/bpf-live-validation.md`](evidence/bpf-live-validation.md).
- **Streaming timeline stress test:** a 2M-event / 312 MB journal exports with bounded
  memory — **12.4 GB → 107–502 MB** (tunable via `--chunk-size`). See
  [`evidence/timeline-streaming-stress.md`](evidence/timeline-streaming-stress.md).
- **Independent code review:** a separate reviewer agent returned APPROVE WITH COMMENTS
  (all seven safety invariants verified to hold); the high-severity findings (perf
  ring-buffer bounds checks) were fixed. See [`evidence/independent-code-review.md`](evidence/independent-code-review.md).

Reproduce the VM validation:

```bash
nix develop --command bash qa/vm-cpp/build_bpf.sh bpf-objects   # compile CO-RE objects
nix develop --command bash -c 'cmake -S . -B /tmp/xsprof-bpf-build -G Ninja -DXSPROF_ENABLE_LIBBPF=ON && cmake --build /tmp/xsprof-bpf-build -j'
bash qa/vm-cpp/run_vmlab.sh                                     # boot VM + run perf + BPF captures
```

## Status

All seven implementation phases are complete:

1. **Phase 1** — Skeleton + read-only fail-closed core (JSON, event model, privacy, safety, proc)
2. **Phase 1.5** — Frozen contracts (pipeline header, golden fixtures, per-module CMake, VM harness)
3. **Phase 2** — Scheduler collectors with capability-gated SKIP
4. **Phase 3** — Memory collectors with capability-gated SKIP
5. **Phase 4** — Chrome-Trace timeline with window selection and chunked output
6. **Phase 5** — Performance Advisor with seven configurable detection rules
7. **Phase 6** — BPF CO-RE loader (VM-lab-only) + daemon parity (stdio JSONL, replay, JSON-RPC)
8. **Phase 6b** — Safety hardening (unsafe-verb matrix, privacy tests re-expressed)
9. **Phase 7** — QA-gate parity (C++ test suite), CI (GitHub Actions + Nix), docs finalization
