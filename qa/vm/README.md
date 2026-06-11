# QEMU VM Lab Harness

This directory contains the disposable VM-only lab skeleton for future sched_ext evidence.

Current behavior is intentionally fail-closed:

- `qa/vm/run_lab.sh --mode read-only-smoke --out <dir>` exits 0 with `SKIP: qemu unavailable` when QEMU is not installed.
- If QEMU exists but no boot image is configured, the script also exits 0 with an explicit skip manifest.
- The script does not attach sched_ext, load BPF, write cgroups, change affinity, or mutate host scheduler state.
- Any future VM boot path must preserve VM-only markers and emit a manifest containing kernel release, arch, git SHA, Zig version, and BTF status.

The cloud-init files are placeholders for a future disposable VM image. They mark the VM as a read-only smoke environment only.

## One-command run-all harness

`qa/vm/run_all_lab.sh` is the top-level lab orchestrator. It writes a summary under `evidence/lab/run-all/<name>/summary.json` and records every stage as `PASS`, `SKIP`, or `REFUSE` with `host_mutation=false` for host-safe fallback runs.

```bash
bash qa/vm/run_all_lab.sh --mode host-safe --out evidence/lab/run-all/manual --release-version 0.1.0-lab-runall
bash qa/vm/run_all_lab.sh --mode vm-required --out evidence/lab/run-all/manual-vm --release-version 0.1.0-lab-runall
bash qa/vm/run_all_lab.sh --mode auto --out evidence/lab/run-all/manual-auto --release-version 0.1.0-lab-runall
```

Mode contract:

- `host-safe`: never treats the host as a lab VM; VM-only stages emit `SKIP` or `REFUSE` evidence.
- `vm-required`: fails closed with `VM_CONFIG_REQUIRED` unless the disposable VM marker is present.
- `auto`: runs with available explicit VM marker/config and otherwise behaves like host-safe fallback.

The run-all harness composes the existing lab scripts rather than bypassing them: `run_lab.sh`, `verifier_only.sh`, `partial_attach.sh`, `rollback_drill.sh`, `cgroup_race.sh`, `dsq_policy_smoke.sh`, `stress_chaos.sh`, `observe_partial.sh`, and `release_gate.sh`.
