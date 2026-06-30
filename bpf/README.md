# zigsched minimal sched_ext policy

This directory contains the first real BPF policy artifact for the root Linux scheduler
path. It is intentionally a minimal `sched_ext_ops` policy for verifier and VM lab
work, not a host attach path and not a production scheduler.

Policy contract:

- `zigsched_minimal_ops` is emitted in a `struct_ops` section and sets
  `SCX_OPS_SWITCH_PARTIAL` only. Full-switch flags are intentionally absent.
- `init` creates one FIFO DSQ and one vtime DSQ. Failure is reported through event
  counters so verifier-only lab runs can explain init failures.
- `select_cpu` delegates CPU selection to `scx_bpf_select_cpu_dfl()`, records
  callback attempts, increments the local-direct counter when the kernel helper
  direct-inserts, and records fallback events when enqueue/dispatch remains in
  the custom DSQ path.
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

## Build metadata contract

`zig build bpf` emits `zig-out/bpf/zigsched_minimal.bpf.meta.json` for a built object, or `zig-out/bpf/zigsched_minimal.bpf.skip.json` when local clang/BPF prerequisites are absent. Both forms preserve the VM-only boundary with `host_mutation=false`, `host_attach_allowed=false`, and `vm_marker_required=/run/zig-scheduler-vm-lab.marker`. Built metadata includes `policy_name`, `object_hash`, `tuple`, `tool_versions`, and `struct_ops` fields so VM-only verifier stages can reject stale or mismatched artifacts before attempting any BPF verifier work.

## ABI compatibility freeze

The current BPF ABI is frozen as v3 for VM-only cgroup-aware policy metadata:

- `ZIGSCHED_ABI_VERSION=3u`.
- `zigsched_stats`: array map, `u32` key, `u64` value, `ZIGSCHED_MINIMAL_NR_STATS=13u` entries. New cgroup counters record init, exit, move, set-weight, and weight-observed callbacks.
- `zigsched_events`: array map, `u32` key, `u64` value, `ZIGSCHED_MINIMAL_NR_EVENTS=6u` entries. New cgroup events record move observation and weight observation.
- `zigsched_policy_config`: single-entry array map keyed by `u32`, value `struct zigsched_policy_config` with `fifo_dsq`, `vtime_dsq`, `starvation_ns_max`, `mode`, and `cgroup_knob_support` as ordered `zigsched_u64` fields.
- `zigsched_cgroup_policy`: single-entry array map keyed by `u32`, value `struct zigsched_cgroup_policy` with `last_weight`, `weight_generation`, `move_generation`, `callback_observed_knobs`, `observed_knobs`, and `deferred_knobs`. It is VM-lab evidence metadata, not a host attach surface.
- ABI v3 accepts the active callbacks `select_cpu`, `init`, `cgroup_init`, `cgroup_exit`, `cgroup_prep_move`, `cgroup_move`, `cgroup_cancel_move`, `cgroup_set_weight`, `enqueue`, and `dispatch`; metadata records `abi_contract.abi_v3_source_status=implemented`. `cgroup_set_bandwidth`, `cgroup_set_idle`, host attach/register, and full-switch remain unaccepted.
- Cgroup knob semantics are exact: `cpu.weight` is **callback-observed** through scheduler-visible `cgroup_set_weight` callbacks and the `zigsched_cgroup_policy` metadata; `cpuset.cpus`, `cpuset.cpus.effective`, and `cpu.pressure` are **observed-only** through runtime/lab evidence and do not change placement; `cpu.max` and uclamp are **deferred/refused** for scheduler-owned behavior until executable VM evidence and a future ABI explicitly accept them.
- Full-switch remains prohibited; metadata must keep `vm_only=true`, `host_mutation=false`, `host_attach_allowed=false`, `verification_claimed=false`, and the VM marker requirement. Live proof is VM-lab-only and pinned to the supported tuple reference in `docs/releases/supported-kernel-tuples.md`.

`tools/bpf_metadata.sh` emits this contract in metadata under `abi_contract`, including header/source hashes, map layouts, enum names, counter/event counts, v3 accepted callbacks, cgroup knob semantics, and the tuple reference. `qa/bpf_abi_freeze_check.py` rejects stale metadata, object/source/header hash mismatches, malformed SKIP/object metadata, unsafe VM-only flags, or any unversioned layout/count/config/source drift. A future ABI must bump `ZIGSCHED_ABI_VERSION`, update ADR 0004 and the checker fixtures, and keep host attach forbidden unless a separate approval explicitly changes that boundary.

The freeze checker does not trust metadata alone for the source ABI. It re-reads
`bpf/zigsched_minimal.bpf.c`, strips C comments, and derives the contract from the
source patterns this policy owns:

- every `struct { ... } <name> SEC(".maps");` map declaration, including
  `__uint(type, ...)`, `__uint(max_entries, ...)`, `__type(key, ...)`, and
  `__type(value, ...)`;
- every BPF program `SEC("...")` section outside the recognized `.maps`,
  `.struct_ops`, and `license` data sections;
- the designated initializer fields used by
  `struct sched_ext_ops zigsched_minimal_ops SEC(".struct_ops")`.

Adding a map, adding a BPF program section, or using a new project-owned
`sched_ext_ops` field beyond the ABI-v3 callback set is therefore rejected under
`ZIGSCHED_ABI_VERSION=3u` even when metadata and source hashes have been
regenerated. That extraction is a documented source-contract parser for the
minimal policy shape, not a general C parser or a host attach path.
