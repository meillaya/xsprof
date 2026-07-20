# BPF CO-RE Live Load Validation

**Status:** PASS — the BPF CO-RE loader loads, attaches, and captures real events in the VM lab.

## What this proves

The deeper review noted the BPF CO-RE live load was unexercised: the userspace
loader was a stub (`libbpf_linked()` false; load path "not implemented") and the
BPF objects had never been loaded into a kernel. This implements the real libbpf
load path and validates it in the disposable microVM.

## Implementation

- `src/bpf/loader.cpp`: real `capture()` — `bpf_object__open_file` -> `bpf_object__load`
  -> `bpf_program__attach` (per program) -> `ring_buffer__new`/`ring_buffer__poll`
  -> convert `sched_event`/`mem_event` to `RawEvent`. Still fail-closed: refuses
  without a full VM-lab audit context; SKIP when BTF or libbpf is absent.
- `bpf/sched_monitor.bpf.c`: fixed the wakeup handler to use
  `struct trace_event_raw_sched_wakeup_template` (the name this kernel's BTF emits).
- `bpf/mem_monitor.bpf.c`: fixed copy-paste ctx types (page_fault -> `void*`,
  fork -> `struct trace_event_raw_sched_process_fork`).
- Build: `XSPROF_ENABLE_LIBBPF` CMake option (OFF by default -> host build stays
  fail-closed; ON for the VM-lab build that links libbpf).
- `qa/vm-cpp/build_bpf.sh`: generates a full `vmlinux.h` from BTF and compiles the
  CO-RE objects with `clang -target bpf` (unwrapped clang; the nix cc-wrapper's
  hardening flags are unsupported for the bpf target).
- CLI: `xsprof record --bpf <obj> --allow-mutate --vm-lab --audit-id <id>
  --rollback-id <id>` drives the BPF capture.

## VM-lab result (linux 6.18.38, KVM, paranoid lowered to -1)

```
loading + attaching sched_monitor.bpf.o via libbpf...
{"capability":"loaded","events_captured":60,"sched_switches":40,"sched_wakeups":20,
 "source":"bpf_core","host_mutation":false}
```

BPF-captured events (real, via the BPF ring buffer):

```json
{"comm":"swapper/0","cpu":0,"event":"sched_switch","host_mutation":false,"pid":0,"ts_ns":2256993777}
{"comm":"xsprof","cpu":0,"event":"sched_switch","host_mutation":false,"pid":103,"ts_ns":2257020227}
```

For comparison, the perf-tracepoint path in the same run captured 634 events
(`source":"perf_tracepoint"`). Both paths preserve `host_mutation=false`.

## Invariants preserved

- BPF load refuses on the host without a full VM-lab audit context (tested).
- `host_mutation=false` on every BPF-captured record.
- Host build compiles the loader WITHOUT libbpf (fail-closed); 118/118 tests pass.

## Reproduce

```bash
nix develop --command bash qa/vm-cpp/build_bpf.sh bpf-objects      # compile CO-RE objects
nix develop --command bash -c 'cmake -S . -B /tmp/xsprof-bpf-build -G Ninja -DXSPROF_ENABLE_LIBBPF=ON && cmake --build /tmp/xsprof-bpf-build -j'
bash qa/vm-cpp/run_vmlab.sh                                        # boot VM + run both captures
```
