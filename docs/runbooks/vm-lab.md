# Disposable VM Lab Runbook

The VM lab is the only place where future sched_ext verifier and attach experiments may occur. The current root harness is fail-closed on ordinary developer hosts and may return `SKIP` or `REFUSE` instead of claiming success.

## Required properties

- VM-only: every evidence bundle must include a VM marker and lab tuple.
- The host path must not load BPF, attach sched_ext, write cgroups, or mutate scheduler state.
- QEMU is launched only through trusted fixed-argv lab scripts or daemon actions.
- Read-only smoke manifests must include git SHA, Zig version, kernel release, arch, BTF status, mode, and `host_mutation=false`.
- Missing QEMU/KVM/Nix/bpftool/kernel input is a fail-closed skip or refusal, not a success.

## Operator commands

Inspect the root fail-closed CLI:

```bash
zig build run -- --help
```

Run host-safe VM/lab checks directly:

```bash
bash qa/vm/run_lab.sh --mode read-only-smoke --out evidence/lab/vm-smoke
bash qa/vm/verifier_only.sh --object zig-out/bpf/zigsched_minimal.bpf.o --out evidence/lab/verifier-dev
```

A passing host-safe run exits 0 and prints either a `SKIP` reason such as `SKIP: qemu unavailable` or `SKIP: kvm unavailable`, or a `REFUSE` reason such as `REFUSE: VM_CONFIG_INVALID`, `REFUSE: VM_CONFIG_AMBIGUOUS`, or `REFUSE: nix_busybox_unavailable`. Any mutation-capable extension requires the governance gate, audit id, rollback id, pre/post sched_ext state checks, and security review.

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
- Missing Nix-busybox fetches in the live microVM path are refused as `nix_busybox_unavailable` so the run never masquerades as success.

## Disposable VM execution contract and fixture harness

The execution contract lives at `qa/vm/execution_contract.json` and is validated by `bash qa/vm/contract_check.sh`. It requires explicit inputs, allowlisted copy-in/copy-out, guest marker proof, bounded timeouts, teardown receipts, and `host_mutation=false` in every artifact.

At T16 and later, attestation evidence is validated by:

```bash
python3 qa/vm/attestation_check.py --input evidence/lab/task-T15-vm/attestation.json
python3 qa/vm/attestation_check.py --self-test
```

The attestation must be copied out from the guest/fixture transcript, include `/run/zig-scheduler-vm-lab.marker`, match the current git SHA, satisfy the supported kernel tuple gates, and avoid host `/sys` source paths.


## Backend VM input and ownership contract

Task 3 fixes the contract before any downstream VM implementation depends on worker judgment. The current machine-readable source is `qa/vm/execution_contract.json`; the canonical current validator is `bash qa/vm/contract_check.sh`. The future Python checker named in the production-backend plan is intentionally absent at this point, so the shell checker remains authoritative until a later task replaces it.

### Backend entrypoint name

The backend operator surface is named now but is implemented later: `zig build vm-lab-backend`. Its VM-required form is:

```bash
zig build vm-lab-backend -- --mode vm-required --out evidence/lab/<run-id>
```

Until Task 8 wires that target into `build.zig`, any implementation must remain fail-closed and must not attach or load a scheduler on the host. The default release evidence directory for the final backend run is `evidence/lab/vm-backend-final`; run-all summaries belong under `evidence/lab/run-all/vm-backend-final/summary.json`; release current-run gate evidence belongs under `evidence/releases/0.2.0-lab-runall/current`.

### Exact VM inputs and tuple gates

Trusted QEMU discovery is limited to `qemu-system-x86_64` resolved by `qa/vm/qemu_discovery.sh`. Accepted canonical paths are `/usr/bin/qemu-system-x86_64`, `/run/current-system/sw/bin/qemu-system-x86_64`, and `/nix/store/*/bin/qemu-system-x86_64`. Overrides from `--qemu` or `ZIG_SCHEDULER_QEMU_BIN` must be absolute, canonical, executable, and outside writable/user/repo scratch paths. Untrusted candidates are refused before execution with qemu/refusal incident text.

VM-required release evidence requires an x86_64 KVM tuple with `/dev/kvm`, a readable kernel image (`--kernel` or `ZIG_SCHEDULER_VM_KERNEL` for the microVM path), an explicit VM image for image-backed execution (`--image` or `ZIG_SCHEDULER_VM_IMAGE`), trusted Nix for busybox/initramfs assembly when the microVM live runner is used, `/sys/kernel/btf/vmlinux`, cgroup v2 at `/sys/fs/cgroup`, and sched_ext state files under `/sys/kernel/sched_ext/`. Kernel evidence must cover `CONFIG_SCHED_CLASS_EXT`, `CONFIG_BPF`, `CONFIG_BPF_SYSCALL`, `CONFIG_BPF_JIT`, and `CONFIG_DEBUG_INFO_BTF`. Missing inputs or unsupported tuple facts are deterministic `REFUSE`/incident outcomes, not success.

### Evidence and event schema names

Every VM backend evidence bundle must preserve `host_mutation=false` and copy out at least `manifest.json`, `attestation.json`, `transcript.jsonl`, `bpf-verifier.log`, `runtime-samples.jsonl`, `rollback-result.json`, `cleanup-receipt.json`, `audit-ledger.jsonl`, and `summary.json`. The schema names reserved for downstream implementation are:

- `zig-scheduler/vm-transcript-index/v1`
- `zig-scheduler/vm-lab-lifecycle-event/v1`
- `zig-scheduler/vm-lab-incident/v1`
- `zig-scheduler/runtime-sample/v1`
- `zig-scheduler/audit-ledger/v1`
- `zig-scheduler/run-all-lab/v1`

### BPF ownership boundary

The kernel BPF policy program remains C/clang-owned for kernel ABI, verifier, `struct_ops`, and libbpf/bpftool compatibility. Zig owns orchestration, the build graph, metadata validation, the `vm-lab-backend` entrypoint, evidence schema checks, packaging, and release gates. Host attach remains forbidden; attach/register/unregister experiments require the disposable VM marker, verifier success, audit id, rollback id, and tuple gates.

## Final current-run release evidence

For final verification after a live VM bundle has been produced from the current `HEAD`, run the release gate in current-run mode instead of refreshing the tracked release snapshot:

```bash
bash qa/release_gate.sh --version 0.2.0-lab --current-run
```

Tracked `evidence/releases/<version>/` evidence remains a curated historical snapshot. Refresh and commit that snapshot only as an intentional release-history update, not as part of final live-bundle freshness proof.
