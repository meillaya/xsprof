# zigsched minimal sched_ext policy

This directory contains the first real BPF policy artifact for the root Linux scheduler
path. It is intentionally a minimal `sched_ext_ops` policy for verifier and VM lab
work, not a host attach path and not a production scheduler.

Policy contract:

- `zigsched_minimal_ops` is emitted in a `struct_ops` section and sets
  `SCX_OPS_SWITCH_PARTIAL` only. Full-switch flags are intentionally absent.
- `init` creates one FIFO DSQ and one vtime DSQ. Failure is reported through event
  counters so verifier-only lab runs can explain init failures.
- `select_cpu` delegates to `scx_bpf_select_cpu_dfl()`, direct-inserts to
  `SCX_DSQ_LOCAL` when the kernel default selector says that is safe, and records
  fallback events if the selected CPU is unusable.
- `enqueue` inserts into either `ZIGSCHED_DSQ_FIFO` or `ZIGSCHED_DSQ_VTIME` based
  on the config map. The default zero config uses vtime mode.
- `dispatch` consumes FIFO first, then vtime, with `scx_bpf_dsq_move_to_local()`.
  This keeps custom DSQs drainable on kernels that require an explicit dispatch
  callback for custom DSQs.
- `zigsched_stats` and `zigsched_events` are bounded array maps of counters for
  lab/runtime observability.

Design references:

- Linux sched_ext documentation: <https://docs.kernel.org/scheduler/sched-ext.html>
- Upstream concept reference: <https://github.com/torvalds/linux/blob/master/tools/sched_ext/scx_simple.bpf.c>

Run:

```bash
zig build bpf --summary all
bash qa/bpf_static_check.sh
```

Expected output is either `zig-out/bpf/zigsched_minimal.bpf.o` or an explicit
`zig-out/bpf/zigsched_minimal.bpf.skip.txt` when the local toolchain cannot emit
BPF objects. A local compiler SKIP is developer-only evidence; release and VM
eligibility require object metadata and verifier evidence in later lab tasks. This
repository still exposes no host command that attaches or registers the scheduler.
Hazardous scheduler lifecycle work belongs in disposable VM lab steps, not in this
host build target.
## Ownership boundary

For the production-backend VM scheduler milestone, the kernel policy remains C/clang-owned. `bpf/zigsched_minimal.bpf.c` is compiled with clang for the `bpf` target because sched_ext `struct_ops`, verifier expectations, helper declarations, and kernel ABI compatibility are C/libbpf-shaped interfaces. Zig owns the orchestration around that artifact: `zig build bpf`, the future `zig build vm-lab-backend` entrypoint, metadata validation, VM evidence checks, packaging, and release gates. This boundary is intentional; do not rewrite the kernel BPF program in Zig or add a host attach path without a new explicit scope decision.
