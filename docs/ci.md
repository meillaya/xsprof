# CI split: host-safe default checks and privileged VM lab checks

This repository separates ordinary unprivileged CI from opt-in privileged VM lab checks. The default lane must remain safe to run on a developer laptop or hosted CI runner. It must not load BPF programs, attach sched_ext, write cgroups, change affinity, change priorities, or mutate scheduler state.

## Default host-safe lane

The default lane is unprivileged and read-only with respect to host scheduler state. It should run on every push and pull request:

```bash
zig build test --summary all
zig build client-contract --summary all
zig build host-safe-gates --summary all
zig build vm-harness-matrix --summary all
zig build bpf --summary all
zig build linux-preflight -- --json
zig build run -- --help
bash qa/cli_help_contract.sh
bash qa/wording_audit.sh
bash qa/no_host_mutation.sh
bash qa/no_frontend_root.sh  # no frontend guard
bash qa/unsafe_cli_matrix.sh
bash qa/restructure_check.sh
git diff --check
zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print)
```


Default matrix and release-withheld gates are host-safe:

- `zig build client-contract` now runs the backend client API fixture pack, `matrix-run/v1` fixtures, runtime sample self-test, control schema drift check, and daemon golden transcript check.
- `zig build host-safe-gates` runs the workload catalog, root UI absence, no-host-mutation, wording/privacy, read-only security, Zig docs vendor, BPF ABI/repro, and release gate self-tests.
- `zig build vm-harness-matrix` runs only the host-safe fixture row by default. It writes ignored evidence under `evidence/lab/matrix/<run-id>` and validates the matrix contract without requiring QEMU, KVM, or a VM kernel.
- `qa/release_gate.sh --matrix-manifest evidence/lab/matrix/<run-id>/manifest.json ...` consumes a matrix manifest only after `qa/matrix_run_contract_check.py` proves every row has `host_mutation=false`, `release_eligible=false`, cleanup proof, rollback proof, host refusal proof, and safe relative artifact paths.

`SKIP` means a prerequisite is absent or unsupported in the selected lane and no unsafe proof was attempted. `REFUSE` means a required unsafe or invalid prerequisite was requested and the harness intentionally declined it. `FAIL` means a checker or runner contract was violated and must fail the lane. Default CI may accept documented `SKIP`/`REFUSE` rows from host-safe fixture or missing-prerequisite scenarios, but must not reinterpret them as VM-live success or release approval.

Required properties:

- `qa/no_host_mutation.sh` is mandatory in the default lane.
- `qa/restructure_check.sh` remains the integration smoke that proves the simulator package stays separate and the root operator remains fail-closed.
- `zig build bpf` may compile an object or emit a clean SKIP, but it must not load or attach anything.
- `zig build run -- --help` remains the fail-closed CLI boundary; it does not launch QEMU.
- VM scripts may run only in host-refusal mode unless the privileged VM gate is explicitly selected.

## Opt-in privileged-vm lane

The `privileged-vm` lane is not part of ordinary CI. It is opt-in and should be started only by an explicit label, manual dispatch, or environment variable such as `ZIG_SCHEDULER_RUN_PRIVILEGED_VM=1` on a runner dedicated to disposable VM experiments.

The lane must begin by printing its gate state:

```bash
if [ "${ZIG_SCHEDULER_RUN_PRIVILEGED_VM:-0}" != 1 ]; then
  echo "SKIP: privileged-vm gate not enabled"
  exit 0
fi
```

After the gate is enabled, it may run VM-only commands such as:

```bash
bash qa/vm/run_lab.sh --mode read-only-smoke --out evidence/lab/dev-smoke
bash qa/vm/verifier_only.sh --object zig-out/bpf/zigsched_minimal.bpf.o --out evidence/lab/verifier-dev
```

Required properties:

- The runner must use a disposable QEMU/KVM VM or a clearly marked VM fallback.
- Mutation-capable sched_ext attach work remains forbidden until later plan tasks add audit id, rollback id, cgroup allowlist, verifier evidence, and security review gates.
- Host refusal is a valid PASS for default CI; VM verifier evidence is valid only when `/run/zig-scheduler-vm-lab.marker` exists inside the disposable VM.
- Missing QEMU/KVM prints `SKIP: qemu unavailable` or `SKIP: kvm unavailable` and exits 0 with `host_mutation=false` evidence.
- Missing kernel image, missing Nix-busybox, or ambiguous VM config should surface as `REFUSE` with `host_mutation=false`, not as success.

## Future workflow mapping

If a `.github/workflows/` directory is added later, keep the names explicit:

- `host-safe.yml`: runs the default host-safe lane above.
- `privileged-vm.yml`: runs only on the explicit `privileged-vm` gate and prints SKIP when the gate is absent.

No future workflow may hide sched_ext attach, BPF load, cgroup writes, cpuset writes, affinity changes, priority changes, or scheduler state mutation inside ordinary host-safe checks.

## VM-lab evidence safety gates

Add these checks to the default/backend verification lane after schema and BPF build steps:

```bash
python3 qa/control_schema_drift_check.py --protocol src/control/protocol.zig --schemas schemas/control
python3 qa/bpf_abi_freeze_check.py --header bpf/include/zigsched_common.h --strategy docs/adr/0004-bpf-abi-strategy.md --metadata zig-out/bpf/zigsched_minimal.bpf.meta.json --skip-json zig-out/bpf/zigsched_minimal.bpf.skip.json
python3 qa/vm_mutation_contract_check.py --self-test
python3 qa/daemon_golden_transcript_check.py --daemon zig-out/bin/zig-scheduler-daemon --fixtures fixtures/control/golden
python3 qa/perf_calibration_evidence_check.py --self-test
```

On runners where QEMU KVM cannot initialize because of local resource limits, the disposable VM runner may be invoked with the explicit non-default fallback `--accel tcg --mem 1024M`. That still boots a marked disposable VM and still runs the same BPF verifier/register/unregister, runtime sample, rollback, cleanup, and mutation-evidence checks. It is not release approval and is not a real-host attach path.
