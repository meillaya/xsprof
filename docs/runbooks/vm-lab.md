# Disposable VM Lab Runbook

The VM lab is the only place where sched_ext verifier and attach experiments may occur for the VM/lab backend milestone. The current root harness is fail-closed on ordinary developer hosts and may return `SKIP` or `REFUSE` instead of claiming success.

## Required properties

- VM-only: every evidence bundle must include a VM marker and lab tuple.
- The host path must not load BPF, attach sched_ext, write cgroups, or mutate scheduler state.
- QEMU is launched only through trusted fixed-argv lab scripts or daemon actions.
- Read-only smoke manifests must include git SHA, Zig version, kernel release, arch, BTF status, mode, and `host_mutation=false`.
- Missing QEMU/KVM/Nix/bpftool/kernel input is a fail-closed skip or refusal, not a success.
- Package installs are inert: daemon and mutation-capable units are disabled or
  condition-refusing by default and require VM marker, config marker, approval
  evidence, audit id, rollback id, and security review before lab use.
- Release evidence must include cleanup proof for QEMU/tmux/temp-root residue and
  must not include frontend/root UI or simulator changes.

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

The backend operator surface is `zig build vm-lab-backend`. It is a fail-closed disposable VM runner: host-side code stages the BPF object, metadata, and guest scripts, validates trusted QEMU/KVM/kernel prerequisites, emits `daemon-events.jsonl`, and refuses missing VM prerequisites without host mutation. Its VM-required form is:

```bash
zig build vm-lab-backend -- --mode vm-required --out evidence/lab/<run-id>
python3 qa/daemon_event_contract_check.py --input evidence/lab/<run-id>/daemon-events.jsonl --require-lifecycle --require-task9-lifecycle
```

The target is wired through `build.zig` and remains fail-closed on the host: any attach/register/unregister work must occur only after the disposable VM marker and tuple gates are observed inside the VM. The default release evidence directory for the final backend run is `evidence/lab/vm-backend-final`; run-all summaries belong under `evidence/lab/run-all/vm-backend-final/summary.json`; release current-run gate evidence belongs under `evidence/releases/0.2.0-lab-runall/current`.

### Live action audit linkage

Live microVM dispatch requires the operator action to carry explicit `action_id`, `target_id`, `audit_id`, and `rollback_id` fields before launch. The daemon validates the audit identifier shape (`AUD-YYYYMMDDTHHMMSSZ-<lowercase-git-7-to-12>-<lowercase-hex-6>`) and refuses missing or malformed audit linkage before emitting live runner start events. Do not rely on generated audit IDs for live dispatch or `partial_attach`; create and record the audit ID in the operator workflow before submitting the action.

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

### Stable VM-live proof contract

`qa/vm/execution_contract.json` also carries the stable live-proof semantics
that validators and operators must agree on before a run-all `summary.json` can
be treated as VM-live proof. A live bundle must be explicitly marked
`evidence_mode=vm-live`, `vm_kind=qemu-vm`, `host_mutation=false`,
`release_eligible_live_proof=false`, `vm_marker_path=/run/zig-scheduler-vm-lab.marker`,
`vm_marker_present=true`, and `rollback_result=PASS`.

The stable cleanup receipt contract is equally explicit: `qemu_leftovers=false`,
`tmux_leftovers=false`, `process_group_reaped=true`, `temp_dirs_removed=true`,
and the cleanup timeout result must not be timeout rc `124`. These fields are
release-withheld lab evidence only; they are not a production or arbitrary-host
approval.

The live summary must include artifact paths for the runtime behavior and event
proofs, including:

- `partial-attach/partial-attach-evidence.json`
- `observe-partial/summary.json`
- `observe-partial/runtime-samples.jsonl`
- `observe-partial/daemon-runtime-events.jsonl`
- `rollback-drill/audit-ledger.jsonl`

The observe summary is required to expose `runtime_samples`,
`daemon_runtime_events`, `sample_count`, `workload_alive_all_samples`,
`final_ops`, `final_state`, `final_state_disabled_or_rolled_back`,
`private_command_lines_sampled=false`, `release_eligible_live_proof=false`, and
`evidence_mode=vm-live`. Partial attach evidence must expose
`ops_during_attach=zigsched_minimal`, `switch_mode=SCX_OPS_SWITCH_PARTIAL`, an
allowlisted target cgroup under `/sys/fs/cgroup/zig-scheduler-lab.slice/`, a
non-zero 64-character SHA-256 object hash, rollback linkage, `rollback_status=PASS`,
`host_mutation=false`, and `release_eligible_live_proof=false`.

Runtime sample JSONL rows are committed to the
`zig-scheduler/runtime-sample/v1` shape with `schema`, `sequence`, `ops`,
`state`, `events`, `workload_alive`, `private_command_lines_sampled`,
`cgroup_membership_digest`, and `cgroup_membership_status`. Daemon runtime
event JSONL rows are committed to the `zig-scheduler/daemon-event/v1` shape
with `event=runtime_sample`, `ops`, and `host_mutation=false`.

The static contract deliberately does **not** duplicate runtime-order,
counter-growth, cgroup digest, or daemon-event occurrence proofs. Those remain
in `qa/live_behavior_check.py` and `src/control/lab_runner/live_summary.zig`,
where the checker can compare actual before/during/after samples and reject
forged success output.

Task 9 VM-required evidence additionally requires a real `qemu-vm` run with `boot`, `marker`, `verifier`, `attach`, `runtime_sample`, `rollback`, `cleanup`, `validation`, and `incident` daemon events. The verifier event must point at copied-out verifier evidence from the VM, the runtime sample must show `zigsched_minimal`, rollback must restore the VM scheduler to disabled/previous state, and validation/incident events must visibly refuse stale target and duplicate rollback IDs with `host_mutation=false`.

### BPF ownership boundary

The kernel BPF policy program remains C/clang-owned for kernel ABI, verifier, `struct_ops`, and libbpf/bpftool compatibility. Zig owns orchestration, the build graph, metadata validation, the `vm-lab-backend` entrypoint, evidence schema checks, packaging, and release gates. Host attach remains forbidden; attach/register/unregister experiments require the disposable VM marker, verifier success, audit id, rollback id, and tuple gates.

### ABI-v3 cgroup-aware policy semantics

The cgroup-aware scheduler policy capability is VM-lab-only and ABI-gated by
`ZIGSCHED_ABI_VERSION=3u`. Host paths still refuse attach/load/mutation and must
not write host cgroups, cpusets, affinities, priorities, `/sys`, or `/proc`.

Supported and refused knobs are deliberately split:

| Knob / callback family | ABI-v3 status | Exact semantics |
| --- | --- | --- |
| `cpu.weight` / `cgroup_set_weight` | **callback-observed** | In a marked disposable VM, sched_ext may call `cgroup_set_weight`; the BPF policy records the latest weight and generation in `zigsched_cgroup_policy`, increments weight-observed counters, and exposes metadata for VM evidence. This is not a production fairness claim. |
| cgroup lifetime and move callbacks | **observed** | `cgroup_init`, `cgroup_exit`, `cgroup_prep_move`, `cgroup_move`, and `cgroup_cancel_move` are accepted to account lifecycle/move observations and populate cgroup policy metadata. They do not authorize host cgroup writes. |
| `cpuset.cpus` and `cpuset.cpus.effective` | **observed-only** | Runtime/lab evidence may report stable redacted cpuset facts. ABI v3 does not let the scheduler own cpuset writes or placement changes from those values. |
| `cpu.pressure` | **observed-only** | Pressure is telemetry/calibration input only. It does not drive a scheduler-owned control loop in ABI v3. |
| `cpu.max` / `cgroup_set_bandwidth` | **deferred/refused** | Bandwidth callbacks and quota control are not accepted by ABI v3. Host and VM fixture paths must refuse scheduler-owned `cpu.max` behavior unless a later ABI adds executable VM proof. |
| uclamp | **deferred/refused** | uclamp mutation is not accepted by ABI v3 and remains a future VM-only research item. |
| `cgroup_set_idle` | **deferred/refused** | Idle-state callbacks are not wired into `zigsched_minimal_ops` in ABI v3. |

ABI metadata must record `abi_contract.cgroup_knob_semantics` with those exact
callback-observed / observed-only / deferred statuses. `qa/bpf_abi_freeze_check.py`
rejects unversioned cgroup maps, unaccepted cgroup callbacks such as
`cgroup_set_bandwidth`, stale metadata, and any metadata that enables host attach.

## Final current-run release evidence

For final verification after a live VM bundle has been produced from the current `HEAD`, run the release gate in current-run mode instead of refreshing the tracked release snapshot:

```bash
bash qa/release_gate.sh --version 0.2.0-lab --current-run
```

If the current-run VM-live bundle is missing or stale, the gate writes a SKIP
summary and exits non-zero. Tracked `evidence/releases/<version>/` evidence
remains a curated historical snapshot. Refresh and commit that snapshot only as
an intentional release-history update, not as part of final live-bundle freshness
proof.

## VM mutation-family evidence proof

The backend VM evidence story requires every mutation family to be represented as both host refusal and VM-only proof:

```bash
zig build vm-lab-backend -- --mode host-safe --accel tcg --mem 1024M --timeout 300 --out evidence/lab/run-all/<run-id>
for m in cgroup.weight cpu.max uclamp topology.offline_cpu; do
  python3 qa/vm_mutation_contract_check.py --mode host-refusal --mutation "$m" --path evidence/lab/run-all/<run-id>/mutation-refusals/$m.json
done
python3 qa/vm_mutation_contract_check.py --mode vm-evidence --summary evidence/lab/run-all/<run-id>/summary.json
python3 qa/perf_calibration_evidence_check.py --bundle evidence/lab/run-all/<run-id>/live/summary.json --out evidence/lab/run-all/<run-id>/perf-calibration-evidence.json
python3 qa/benchmark_output_check.py --fixtures fixtures/benchmark-output --schema schemas/control/benchmark-output.v1.schema.json
```

### Record-only benchmark-output calibration

`benchmark-output/v1` records sanitized VM benchmark outputs as calibration inputs only. The checker can normalize committed examples for `cyclictest` JSON/text, `fio` JSON, and `perf bench sched messaging` summaries. `rtla` and `perf sched` are represented only as `UNSUPPORTED_DEFERRED` records until a later milestone adds parsers.

Every record must include the tool family, safe relative output path, raw-output SHA-256, VM evidence link, basic metrics with units, sample/run counts, `host_mutation=false`, `release_eligible=false`, `production_capacity_claim=false`, `hard_thresholds_enforced=false`, and `threshold_status=record_only`. The checker rejects command lines, argv, environments, secrets, absolute/traversing paths, hard-threshold PASS/FAIL claims, release claims, and production-capacity claims. These artifacts are not performance gates and must not be used to approve production, release eligibility, or scheduler superiority.

Matrix workload specs may attach those records under `benchmark_provenance` as `{record_path, record_sha256, record_only=true}`. In manifest validation, `qa/matrix_run_contract_check.py` keeps each referenced path under `evidence/lab/matrix/<run-id>/`, verifies the SHA-256, then reuses `qa/benchmark_output_check.py` to validate the `benchmark-output/v1` record. Missing records, malformed records, and records carrying threshold/release/production claims are rejected. The attachment is provenance for calibration review only; it is not a PASS/FAIL threshold and is not a release gate.

Use `--accel kvm` on runners where KVM starts cleanly. Use `--accel tcg` only as an explicit disposable-VM fallback when QEMU/KVM startup is blocked by the runner environment. Either way, the host path remains fail-closed and must not load BPF or mutate host scheduler/cgroup state.

## VM harness matrix runner

`qa/vm/vm_harness_matrix.sh` is the canonical host-safe matrix wrapper around the VM lab evidence surface. It emits a `zig-scheduler/vm-harness-matrix-index/v1` manifest and one standalone `zig-scheduler/matrix-run/v1` row per selected scenario. It does not replace `qa/vm/vm_lab_backend.sh`, `qa/vm/run_all_lab.sh`, or `qa/vm/run_microvm_live_lab.sh`; the `live-backend` scenario delegates to the existing backend runner only when explicitly selected.

Host-safe fixture smoke run:

```bash
bash qa/vm/vm_harness_matrix.sh --mode host-safe --scenario fixture-pass --out evidence/lab/matrix/<run-id>
python3 qa/matrix_run_contract_check.py --manifest evidence/lab/matrix/<run-id>/manifest.json --schemas schemas/control --docs docs/control
bash qa/scope_fidelity.sh --plan .omo/plans/vm-harness-matrix-incident-api-hardening.md --evidence .omo/evidence/vm-harness-matrix-incident-api-hardening
```

Prerequisite-refusal examples:

```bash
bash qa/vm/vm_harness_matrix.sh --mode host-safe --scenario missing-qemu,missing-kvm,missing-kernel --out evidence/lab/matrix/<run-id>-missing
bash qa/vm/vm_harness_matrix.sh --mode vm-required --scenario missing-qemu --out evidence/lab/matrix/<run-id>-vm-required
```

Rows run sequentially. Output must be a relative path exactly shaped as `evidence/lab/matrix/<run-id>`; `<run-id>` must be 1-64 characters from `A-Z`, `a-z`, `0-9`, `_`, `.`, and `-`, and becomes the manifest `matrix_run_id` without truncation or rewriting. An existing run directory is always refused as a collision, including directories that carry the runner ownership marker. Every row records daemon events, host refusal proof, rollback proof, cleanup proof, privacy proof, and cleanup scans with `host_mutation=false` and `release_eligible=false`. Fixture rows are lab contract evidence only and are not production or release approval. Release gating may consume a matrix manifest with `qa/release_gate.sh --matrix-manifest evidence/lab/matrix/<run-id>/manifest.json`, but the manifest is accepted only as release-withheld lab evidence; it cannot create production approval or arbitrary-host approval.

The safe build targets run host-safe matrix and contract gates by default:

```bash
zig build client-contract --summary all
zig build host-safe-gates --summary all
zig build vm-harness-matrix --summary all
```

`client-contract` covers matrix fixtures, backend client API fixtures, runtime samples, control schema drift, and daemon golden transcripts. `host-safe-gates` covers workload catalog, BPF ABI/repro, root UI absence, no-host-mutation, release-withheld self-test, wording/privacy, read-only security, and Zig vendor-doc checks. `vm-harness-matrix` selects only the host-safe `fixture-pass` row unless explicit arguments are supplied after `--`; without a real VM marker, that row is `PASS` with `evidence_mode=fixture`, while vm-required marker-missing rows fail closed as `REFUSE` and prerequisite-missing rows remain `SKIP`/`REFUSE`. None of these default build targets require QEMU/KVM or VM kernel inputs.

The canonical protected live row is:

```bash
zig build vm-harness-matrix -- \
  --mode vm-required \
  --scenario live-backend \
  --out evidence/lab/matrix/<run-id>
```

That row invokes `qa/vm/vm_lab_backend.sh --mode vm-required`, and the backend stages BPF metadata before delegating real disposable-VM execution to `qa/vm/run_microvm_live_lab.sh`. If QEMU, `/dev/kvm`, a trusted kernel image, Nix/busybox staging, or the supported tuple is unavailable, the row must still leave a manifest with a validated `SKIP` or `REFUSE` artifact and `host_mutation=false`; it must not fall back to loading or attaching sched_ext on the host. On a capable protected runner, a PASS row must be `evidence_mode=vm-live`, include a row-local VM marker proof, and retain rollback, cleanup, host-refusal, runtime-sample, daemon-event, and privacy artifacts under the matrix run root.

Protected live operator checklist:

1. Confirm the run is on the protected `vm-proof-manual` environment and an isolated self-hosted runner with `zig-scheduler-vm-proof` and `disposable-vm` labels; ordinary hosts and hosted CI must stop at host-safe gates.
2. Capture runner substrate proof (`runner-substrate-proof.json`) before trusting a PASS. Unavailable QEMU, `/dev/kvm`, BTF, sched_ext kernel support, protected-reviewer signal, BPF object metadata, or artifact attestation is first-class `SKIP`/`REFUSE` evidence, not success.
3. Run the canonical command above and keep all artifacts under `evidence/lab/matrix/<run-id>/`, especially `manifest.json`, `rows/live-backend/matrix-run.json`, `runner-substrate-proof.json`, row-local VM marker proof, `rollback-proof.json`, `cleanup-proof.json`, `host-refusal.json`, runtime samples, daemon events, privacy scan, and benchmark provenance records.
4. Validate the matrix manifest and bundle manifest before review:

   ```bash
   python3 qa/matrix_run_contract_check.py --manifest evidence/lab/matrix/<run-id>/manifest.json --schemas schemas/control --docs docs/control
   python3 qa/evidence_manifest_check.py --manifest evidence/lab/manual-vm-proof/evidence-manifest.json --schema schemas/control/evidence-manifest.v1.schema.json
   ```

5. Verify artifact attestation from the GitHub run before treating the uploaded bundle as protected provenance:

   ```bash
   gh attestation verify vm-proof-bundle.tar.zst --repo <owner>/<repo>
   ```

A local PASS from these static checks only means the artifacts are shaped for review. It does not approve a release, does not approve production use, does not add frontend work, and does not allow host attach or host scheduler/cgroup mutation.

## VM workload scenario catalog

Workload catalog rows are matrix-run fixtures and VM-only execution plans. They do **not** run stressors on the host, do **not** load or attach sched_ext on the host, and do **not** write host cgroups, affinities, priorities, `/sys`, or `/proc`. The read-only capability checker is `qa/vm/workload_capability_probe.sh`; the matrix integration is `qa/vm/vm_harness_matrix.sh --scenario <id> --fixture`. Live workload execution remains disposable-VM-only and requires `/run/zig-scheduler-vm-lab.marker` plus the listed tools.

| Scenario ID | Workload class | Required tools / prereqs | Threshold source | Typed SKIP / REFUSE conditions | Artifact paths |
| --- | --- | --- | --- | --- | --- |
| `workload-cpu-saturation` | CPU saturation | `stress-ng` | `record-only` | Missing `stress-ng`; VM-required mode returns `REFUSE`, host-safe/auto returns `SKIP` when forced by the probe. | `rows/<scenario>/workload-spec.json`, `workload-capability.json`, `runtime-sample.jsonl`, `incident.json`, `rollback-proof.json`, `cleanup-proof.json`, `host-refusal.json`, `privacy-scan.json` |
| `workload-interactive-latency` | Interactive latency probe | `cyclictest`, `perf` | `record-only` | Missing `cyclictest` or `perf`; calibration remains uncalibrated until separately proven by VM-live evidence. | Same per-row artifact set under `evidence/lab/matrix/<run-id>/rows/<scenario>/` |
| `workload-scheduler-affinity-churn` | Scheduler / affinity churn | `stress-ng`, `taskset`, `chrt` | `record-only` | Missing any listed tool; live use is VM-only because affinity and scheduling knobs are mutation surfaces. | Same per-row artifact set under `evidence/lab/matrix/<run-id>/rows/<scenario>/` |
| `workload-fork-ipc-pressure` | Bounded fork / IPC pressure | `hackbench` or a `perf bench sched messaging`-like fallback (`hackbench-like`) | `record-only` | Missing hackbench-like tool; process pressure remains bounded and VM-only. | Same per-row artifact set under `evidence/lab/matrix/<run-id>/rows/<scenario>/` |
| `workload-mixed-io` | Mixed I/O | `fio` | `record-only` | Missing `fio`; no production throughput claim is inferred from fixture or record rows. | Same per-row artifact set under `evidence/lab/matrix/<run-id>/rows/<scenario>/` |
| `workload-cgroup-weight-quota` | cgroup weight / quota pressure | `stress-ng` | `record-only` | Missing `stress-ng`; VM-only semantic labels are `cpu.weight=callback-observed`, `cpu.max`/`cpu.max.burst=deferred`, `cpuset.cpus` constraints observed, uclamp/pressure observed-or-deferred, threaded/domain cgroups observed, and allowed-mask rejected. Cgroup writes remain VM-live-only behind the VM marker and are always refused on the host. | Same per-row artifact set under `evidence/lab/matrix/<run-id>/rows/<scenario>/` |
| `workload-cpu-hotplug` | CPU hotplug / offline where supported | VM CPU online control (`cpu-hotplug-online-control`) | `record-only` | Missing writable VM CPU online control or unsupported topology; VM-only semantic labels prove CPU offline/online fallback observed, cpuset constraints observed, and allowed-mask rejected. Host CPU hotplug/offline is always refused. | Same per-row artifact set under `evidence/lab/matrix/<run-id>/rows/<scenario>/` |

Capability discovery examples:

```bash
bash qa/vm/workload_capability_probe.sh --mode host-safe --scenario workload-cpu-saturation
ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL=stress-ng \
  bash qa/vm/vm_harness_matrix.sh --mode vm-required --fixture \
    --scenario workload-cpu-saturation --out evidence/lab/matrix/<run-id>-missing-workload
```

The `workload-spec.json` hash is recorded in the row's `workload.spec_sha256`; `workload-capability.json` records prerequisite status, `threshold_source=record-only`, and typed missing-prereq state. Thresholds remain uncalibrated record evidence until a later VM-only proof explicitly promotes them; `benchmark_provenance` records are validated by the benchmark-output checker as record-only artifacts and cannot become pass/fail performance results, production-capacity claims, release eligibility, or scheduler-performance claims.

Privacy rules: workload artifacts may record scenario IDs, tool names, threshold-source labels, bounded counters, and relative artifact paths only. They must not include command lines, argv, environments, secrets, API keys, tokens, passwords, bearer strings, or private process data. Every matrix row also carries a `privacy-scan.json` with `private_fields_found=false`, `host_mutation=false`, and `release_eligible=false`.

## Manual protected VM proof workflow

The repository includes `.github/workflows/manual-vm-proof.yml` as an opt-in `workflow_dispatch` lane for disposable VM proof provenance. It is not part of ordinary CI and ordinary push or pull-request checks must remain host-safe. Repository owners must configure the `vm-proof-manual` protected environment with required reviewers, branch/tag restrictions, and access only to an isolated self-hosted runner carrying `self-hosted`, `zig-scheduler-vm-proof`, and `disposable-vm` labels.

The manual dispatch requires the operator to provide an audit id, rollback id, VM marker path `/run/zig-scheduler-vm-lab.marker`, and the exact `supported_tuple` workflow input for the protected runner. The workflow is allowed to run VM-required proof commands only on that isolated runner; it must not be interpreted as real-host attach permission. The uploaded proof is the GitHub Actions artifact `vm-proof-bundle.tar.zst`; it is not a release asset, not OCI, not production approval, and keeps `release_eligible=false`, `host_mutation=false`, and `production_capacity_claim=false`.

Before opening the protected run, capture this operator preflight on the self-hosted runner and keep it with the evidence ledger. The tuple string must remain in the existing Linux `>=6.12` family and match the actual `uname -r` prefix used by the runner; unavailable sched_ext, BTF, `/dev/kvm`, or QEMU KVM support is `SKIP`/`REFUSE` evidence, not a PASS.

```bash
set -euo pipefail
kernel_release="$(uname -r)"
supported_tuple="linux-6.12-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only" # choose the existing linux-6.12+ tuple matching uname -r
printf 'kernel_release=%s\n' "$kernel_release"
printf 'workflow_supported_tuple=%s\n' "$supported_tuple"
case "$kernel_release" in
  6.1[2-9]*|6.[2-9][0-9]*) ;;
  *) echo "REFUSE: kernel release does not match the existing linux-6.12+ supported tuple input"; exit 1 ;;
esac
test -d /sys/kernel/sched_ext
test -r /sys/kernel/btf/vmlinux
test -e /dev/kvm && test -r /dev/kvm && test -w /dev/kvm
command -v qemu-system-x86_64
qemu-system-x86_64 -accel help | grep -E '(^|[[:space:]])kvm($|[[:space:]])'
echo "$supported_tuple" | grep -E '^linux-6\.(1[2-9]|[2-9][0-9])([.][0-9]+)?-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only$'
```

CachyOS `7.1.1-cachyos` is out of scope for this milestone. Do not add it to tuple regexes, schemas, validators, or PASS documentation here; handle it only in a future tuple-expansion governance milestone.

The protected workflow runs the same canonical `live-backend` matrix command. A non-zero matrix command is reviewable only when it left a valid manifest and the `live-backend` row is explicitly `SKIP` or `REFUSE`; the workflow validates that manifest before packaging evidence so unavailable substrate is recorded as proof of fail-closed behavior rather than silently discarded.

`vm-proof-bundle.tar.zst` is the pinned manual proof artifact type. It must contain or explicitly account for: audit id, rollback id, VM marker, supported tuple, pre state, post state, rollback proof, cleanup proof, host refusal, matrix manifest, matrix rows, BPF metadata, BPF SKIP JSON when the object is skipped, protected-environment-review.json generated from the current GitHub run review history, daemon events, live summary if present, static verification logs, and benchmark provenance for record-only matrix rows. Missing QEMU/KVM/kernel prerequisites remain `SKIP` or `REFUSE`; they are not success and are not release approval. PASS requires KVM accel, supported kernel release, non-placeholder kernel config hash, BTF, sched_ext, BPF object metadata, and explicit protected-environment reviewer approval.

Post-run provenance review is manual and evidence-based:

```bash
gh run download <run-id> --name vm-proof-bundle
gh attestation verify vm-proof-bundle.tar.zst --repo <owner>/<repo>
tar --zstd -tf vm-proof-bundle.tar.zst
python3 qa/matrix_run_contract_check.py --manifest evidence/lab/matrix/manual-vm-proof/manifest.json --schemas schemas/control --docs docs/control
python3 qa/manual_vm_proof_ci_check.py --workflow .github/workflows/manual-vm-proof.yml --docs docs/ci.md docs/runbooks/vm-lab.md docs/releases/governance-gate.md docs/security/review-checklist.md
```

Do not claim this run was approved or executed by a human unless the GitHub run history and protected-environment review record show that approval. Static local validation only proves the workflow/provenance contract is safe to review.

Manual protected VM proof bundles now carry `evidence-manifest.json` beside the matrix output. Operators should validate it with `python3 qa/evidence_manifest_check.py --manifest evidence/lab/manual-vm-proof/evidence-manifest.json --schema schemas/control/evidence-manifest.v1.schema.json` before treating the bundle as lab evidence. The manifest records an explicit `outcome` derived from matrix rows and protected runner substrate proof, plus SHA-256 hashes and schema roles for the matrix manifest, matrix rows, BPF metadata or BPF SKIP JSON, daemon events, benchmark provenance, protected-environment-review proof, rollback proof, cleanup proof, host refusal proof, privacy scan, static verification logs, audit id, rollback id, VM marker, supported tuple, and attestation status. It does not grant release eligibility or production approval.

Protected runner substrate proof is recorded as `runner-substrate-proof.json` and checked with `qa/runner_substrate_proof_check.py` against `schemas/control/runner-substrate-proof.v1.schema.json`. It records runner class, runner group, runner labels, protected environment reviewer status, run URL, QEMU path, QEMU version, /dev/kvm status, accel mode, kernel tuple, BPF metadata, attestation status, and unavailable reasons. All paths in that proof are relative/non-traversing, `host_mutation=false`, `release_eligible=false`, and `production_capacity_claim=false`; an unavailable QEMU, empty QEMU version, /dev/kvm, reviewer signal, kernel BTF metadata unavailable, sched_ext kernel substrate unavailable, unsupported kernel release, placeholder kernel config hash, TCG accel, BPF SKIP metadata, or attestation capability must be an explicit SKIP/REFUSE reason and never a fake PASS. PASS requires `reviewer_status=approved`, a normalized `protected-environment-review.json` artifact for the same run, and a real GitHub Actions run URL; `not_exposed_by_github_actions_runtime` is never enough for PASS. A local refusal artifact that never dispatched the protected workflow may set `run_url=unavailable` only with `proof_outcome=SKIP` or `REFUSE` and an explicit unavailable reason.

For the protected-vm-live-pass-final evidence set, the current final outcome is BLOCKED/non-PASS. Use `.omo/evidence/protected-vm-live-pass-final/final-proof-ledger.md`, `task-6-remote-blocker.md`, and `task-7-non-pass-ledger.md` as the safety-gate record: no matching runner was visible, no fresh approved bundle was downloaded, and no protected PASS may be claimed.
