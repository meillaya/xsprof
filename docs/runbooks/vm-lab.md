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

## Explicit VM configuration contract

`run_lab.sh` accepts VM boot inputs only through explicit operator-supplied config:

```bash
bash qa/vm/run_lab.sh --mode read-only-smoke --image /path/to/lab.qcow2 --out evidence/lab/vm-smoke
bash qa/vm/run_lab.sh --mode read-only-smoke --kernel /path/to/bzImage --out evidence/lab/vm-smoke
bash qa/vm/run_lab.sh --mode read-only-smoke --env-file qa/vm/lab.env --out evidence/lab/vm-smoke
```

Supported env-file keys are `ZIG_SCHEDULER_VM_IMAGE`, `ZIG_SCHEDULER_VM_KERNEL`, `ZIG_SCHEDULER_VM_DRIVER`, and `ZIG_SCHEDULER_VM_TEST_FIXTURE`. The file is parsed as data and is not sourced as shell code.

Fail-closed outcomes:

- Missing image/kernel/env-file paths produce `REFUSE: VM_CONFIG_INVALID` and a manifest with `host_mutation=false`.
- Conflicting CLI and env-file values produce `REFUSE: VM_CONFIG_AMBIGUOUS`.
- No explicit image/kernel produces `SKIP: qemu boot image unavailable`.
- Missing QEMU/KVM remains a host-safe `SKIP`, with `qemu_available` and `kvm_available` recorded.

The read-only skeleton records explicit config and availability only. It must not use host `/sys` as VM evidence.

## Disposable VM execution contract and fixture harness

T07 adds the execution contract before any VM boot implementation. The contract lives at `qa/vm/execution_contract.json` and is validated by `bash qa/vm/contract_check.sh`.

The contract requires future VM execution to be disposable and evidence-first:

1. **Inputs:** image/kernel paths come only from explicit CLI arguments or `ZIG_SCHEDULER_VM_IMAGE` / `ZIG_SCHEDULER_VM_KERNEL` in an env file parsed as data, not sourced as shell.
2. **Copy-in:** the VM receives only allowlisted lab artifacts such as the minimal BPF object and `qa/vm/{verifier_only,partial_attach,observe_partial,rollback_drill}.sh`.
3. **Marker:** guest-side `/run/zig-scheduler-vm-lab.marker` is mandatory before attach, observe, rollback, or `vm-live` evidence.
4. **Allowlist:** guest commands are selected by fixed argv entries from the contract; mutation-capable commands require guest marker, audit id, and/or rollback id as declared.
5. **Timeouts:** boot, command, teardown, and overall run timeouts are declared up front.
6. **Copy-out:** transcript index, verifier log, runtime samples, rollback result, and cleanup receipt must be copied out and hashed.
7. **Teardown:** teardown is mandatory and must record whether QEMU/temp roots remain; orphan QEMU is a failed run.
8. **Artifact manifest:** every VM-live bundle must preserve `host_mutation=false`, git SHA, VM marker, kernel tuple, command-allowlist hash, copy-in/out hashes, transcript path, and cleanup receipt.

At T15 and later, `bash qa/vm/run_lab.sh --mode execute --out <dir>` must fail closed unless explicit VM config is supplied. The tracked `qa/vm/lab.env` fixture exercises copy-in, marker probing, attestation, transcript creation, copy-out, and teardown receipts with `vm_kind=vm-configured-fixture`; that fixture is not VM-live and is not release-eligible proof. Real QEMU/KVM execution remains explicit-config-only and must never fall back to host `/sys` evidence.

At T16 and later, attestation evidence is validated by:

```bash
python3 qa/vm/attestation_check.py --input evidence/lab/task-T15-vm/attestation.json
python3 qa/vm/attestation_check.py --self-test
```

The attestation must be copied out from the guest/fixture transcript, include `/run/zig-scheduler-vm-lab.marker`, match the current git SHA, satisfy the supported kernel tuple gates, and avoid host `/sys` source paths.
