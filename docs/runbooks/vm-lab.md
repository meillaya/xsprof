# Disposable VM Lab Runbook

The VM lab is the only place where future sched_ext verifier and attach experiments may occur. The current harness is a read-only smoke skeleton and may return `SKIP: qemu unavailable` on ordinary developer hosts.

## Required properties

- VM-only: every evidence bundle must include a VM marker and lab tuple.
- The host path must not load BPF, attach sched_ext, write cgroups, or mutate scheduler state.
- Read-only smoke manifests must include git SHA, Zig version, kernel release, arch, BTF status, mode, and host_mutation false.
- Missing QEMU/KVM is a skip, not a failure of host safety.

## Operator command

```bash
bash qa/vm/run_lab.sh --mode read-only-smoke --out evidence/lab/dev-smoke
```

A passing host-safe run exits 0 and prints either `SKIP: qemu unavailable`, `SKIP: kvm unavailable`, or a future VM-only read-only smoke result. Any mutation-capable extension requires the governance gate, audit id, rollback id, pre/post sched_ext state checks, and security review.

## Verifier-only BPF evidence

The verifier-only flow is guarded by `/run/zig-scheduler-vm-lab.marker`. Running it on a normal host must produce an explicit refusal and must not attempt BPF verifier load, scheduler lifecycle, or cgroup writes.

Host-safe refusal check:

```bash
bash qa/vm/verifier_only.sh --object zig-out/bpf/zigsched_minimal.bpf.o --out evidence/lab/verifier-dev
```

Inside a disposable VM with the marker present, the script captures `bpf-verifier.log`, object SHA-256, pre/post `/sys/kernel/sched_ext/state`, pre/post `enable_seq`, and a cgroup membership digest. Any sched_ext state delta or cgroup membership delta fails the run.
