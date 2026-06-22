# CI split: host-safe default checks and privileged VM lab checks

This repository separates ordinary unprivileged CI from opt-in privileged VM lab checks. The default lane must remain safe to run on a developer laptop or hosted CI runner. It must not load BPF programs, attach sched_ext, write cgroups, change affinity, change priorities, or mutate scheduler state.

## Default host-safe lane

The default lane is unprivileged and read-only with respect to host scheduler state. It should run on every push and pull request:

```bash
zig build test --summary all
zig build bpf --summary all
zig build linux-preflight -- --json
zig build run -- --help
bash qa/cli_help_contract.sh
bash qa/wording_audit.sh
bash qa/no_host_mutation.sh
bash qa/unsafe_cli_matrix.sh
bash qa/restructure_check.sh
git diff --check
zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print)
```

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
