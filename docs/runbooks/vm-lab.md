# Disposable VM Lab Runbook

The VM lab is the only place where future sched_ext verifier and attach experiments may occur. The first-class operator entrypoint is `zig build tui-live-vm`; the lower-level interactive form is `zig build tui -- --interactive --screen vm-lab ...`. The current harness is fail-closed on ordinary developer hosts and may return `SKIP` or `REFUSE` instead of claiming success.

## Required properties

- VM-only: every evidence bundle must include a VM marker and lab tuple.
- The host path must not load BPF, attach sched_ext, write cgroups, or mutate scheduler state.
- QEMU is launched only through the trusted daemon route that calls `qa/vm/run_microvm_live_lab.sh` with fixed argv.
- Read-only smoke manifests must include git SHA, Zig version, kernel release, arch, BTF status, mode, and `host_mutation=false`.
- Missing QEMU/KVM/Nix/bpftool/kernel input is a fail-closed skip or refusal, not a success.

## Operator commands

Inspect the root fail-closed CLI:

```bash
zig build run -- --help
```

Open the first-class live VM TUI:

```bash
zig build tui-live-vm
```

For a help/smoke/prerequisite contract without opening the TUI, run:

```bash
zig build tui-live-vm -- --help
```

Or launch the interactive VM-lab screen directly:

```bash
zig build tui -- --interactive --screen vm-lab --width 120 --height 30 --daemon-state-dir ".omo/evidence/tui-live-vm" --daemon-bin "./zig-out/bin/zig-scheduler-daemon"
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

## TUI-driven live lab lifecycle

The current user-facing lab path starts in the TUI and dispatches typed actions to `zig-scheduler-daemon`. Use it for operator-flow evidence before direct script shortcuts. The host never attaches sched_ext directly; the live attach runs only inside the disposable guest.

Build and run a host-safe TUI transcript:

```bash
zig build install
printf 'rviq' | ./zig-out/bin/zig-scheduler-tui \
  --interactive --test-mode \
  --fixture fixtures/lab/preflight-ready.json \
  --screen sched-ext --width 120 --height 30 \
  --daemon-bin "./zig-out/bin/zig-scheduler-daemon" \
  --daemon-state-dir ".omo/evidence/tui-daemon-state" \
  > ".omo/evidence/tui-driven-transcript.txt"
```

For a full disposable VM lab sequence, the intended key order is preflight/readiness, host-safe run, verifier, partial attach, observe, stress through the VM run-all harness, incident/rollback, then quit. In current test-mode notation that means using the action keys `r`, `v`, `p`, `o`, `i`, `m`, `b`, `b`, `q` as the flow matures.

The live VM key semantics are:

- `m` requests a fresh disposable microVM run through the daemon registry;
- `s` requests a safe stop;
- `b` confirms rollback for the current target;
- duplicate or stale target ids refuse instead of mutating host state.

Evidence paths to preserve for review:

- daemon journal: `.omo/evidence/tui-daemon-state/events.jsonl`;
- live TUI transcript: `.omo/evidence/tui-driven-transcript.txt`;
- live bundle summary: `evidence/lab/run-all/microvm-live-<run-id>/summary.json`;
- live bundle runtime samples: `evidence/lab/run-all/microvm-live-<run-id>/observe-partial/runtime-samples.jsonl`;
- live bundle daemon events: `evidence/lab/run-all/microvm-live-<run-id>/observe-partial/daemon-runtime-events.jsonl`;
- rollback audit ledger: `evidence/lab/run-all/microvm-live-<run-id>/rollback-drill/audit-ledger.jsonl`;
- cleanup/process-scan evidence: the `cleanup` block and process-scan files referenced by the live bundle summary.

If explicit VM config is missing, the run must SKIP or REFUSE with `host_mutation=false`. A SKIP is valid host-safe CI evidence only; it is not VM-live behavior proof.
