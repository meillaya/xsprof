# zigsched BPF skeleton

This directory contains the first BPF build artifacts for the root Linux scheduler path.
The current object is a minimal `sched_ext_ops` skeleton for partial-switch lab work:

- `zigsched_minimal_ops` is emitted in a `struct_ops` section.
- `SCX_OPS_SWITCH_PARTIAL` is set; full-host switch flags are intentionally absent.
- `select_cpu`, `enqueue`, and `dispatch` callbacks are deliberately minimal and default-biased.
- A bounded array stats map is present for later observer work.

Run:

```bash
zig build bpf --summary all
bash qa/bpf_static_check.sh
```

Expected output is either `zig-out/bpf/zigsched_minimal.bpf.o` or an explicit
`zig-out/bpf/zigsched_minimal.bpf.skip.txt` when the local toolchain cannot emit
BPF objects. This repository still exposes no host command that attaches or
registers the scheduler. Hazardous scheduler lifecycle work belongs in the
disposable VM lab steps, not in this host build target.
