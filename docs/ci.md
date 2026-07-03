# CI split: host-safe default checks and privileged VM lab checks

This repository separates ordinary unprivileged CI from opt-in privileged VM lab checks. The default lane must remain safe to run on a developer laptop or hosted CI runner. It must not load BPF programs, attach sched_ext, write cgroups, change affinity, change priorities, or mutate scheduler state.

## Default host-safe lane

The default lane is unprivileged and read-only with respect to host scheduler state. It should run on every push and pull request:

```bash
zig build test --summary all
zig build client-contract --summary all
zig build host-safe-gates --summary all
zig build vm-harness-matrix --summary all
bash qa/scope_fidelity.sh --plan .omo/plans/vm-harness-matrix-incident-api-hardening.md --evidence .omo/evidence/vm-harness-matrix-incident-api-hardening
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

- `zig build client-contract` now runs the backend client API fixture pack, client/consumer adversarial self-tests, `matrix-run/v1` fixtures, runtime sample self-test, benchmark-output fixture validation, control schema drift, schema compatibility check/self-test, and daemon golden transcript checks.
- `zig build host-safe-gates` runs the workload catalog, root UI absence, no-host-mutation, wording/privacy, read-only security, Zig docs vendor, BPF ABI/repro, governance manifest check/self-test, evidence-manifest self-test, evidence-bundle comparison self-test, manual VM proof static/self-tests, matrix-run fixture/self-tests, protected-core suite and telemetry self-tests, runner-substrate fixture/self-tests, runner-cleanliness fixture/self-tests, benchmark-output self-test, benchmark provenance self-test, and release gate self-tests.
- `zig build vm-harness-matrix` runs only the host-safe fixture row by default. On hosts without `/run/zig-scheduler-vm-lab.marker`, that row may report `PASS` only as `evidence_mode=fixture`, which proves contract fixture generation/validation and never VM-live execution. VM-required or prerequisite-missing rows must SKIP/REFUSE rather than mutating the host or claiming VM-live marker evidence. The default target writes a temporary ignored run under `evidence/lab/matrix/<run-id>`, validates it with `qa/matrix_run_contract_check.py --manifest`, and removes the temporary row before exit; explicit `--out` invocations remain operator-owned evidence. It does not require QEMU, KVM, or a VM kernel.
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
python3 qa/benchmark_output_check.py --self-test
python3 qa/benchmark_output_check.py --fixtures fixtures/benchmark-output --schema schemas/control/benchmark-output.v1.schema.json
python3 qa/runner_substrate_proof_check.py --fixtures fixtures/runner-substrate-proof --schema schemas/control/runner-substrate-proof.v1.schema.json
python3 qa/runner_substrate_proof_check.py --self-test
python3 qa/matrix_benchmark_provenance_check.py --self-test
python3 qa/governance_manifest_check.py --manifest fixtures/lab/governance-sources.json
python3 qa/governance_manifest_check.py --self-test
python3 qa/schema_compatibility_check.py --self-test
python3 qa/frontend_contract_pack_check.py --self-test  # backend contract; no frontend implementation
python3 qa/consumer_contract_check.py --self-test
```

`benchmark-output/v1` is a record-only calibration contract. CI may validate parser behavior, committed fixtures, and matrix `benchmark_provenance` references, but those checks do not enforce performance thresholds and do not create release eligibility or production-capacity claims. Matrix provenance validation reuses `qa/benchmark_output_check.py`; malformed, missing, or claim-bearing benchmark records remain contract failures rather than performance failures.

On runners where QEMU KVM cannot initialize because of local resource limits, the disposable VM runner may be invoked with the explicit non-default fallback `--accel tcg --mem 1024M`. That still boots a marked disposable VM and still runs the same BPF verifier/register/unregister, runtime sample, rollback, cleanup, and mutation-evidence checks. It is not release approval and is not a real-host attach path.

## Manual protected VM proof provenance lane

`.github/workflows/manual-vm-proof.yml` is a protected manual VM proof lane, not an ordinary CI lane. It is triggered only by `workflow_dispatch`; ordinary push, pull request, scheduled, and default CI paths must not launch QEMU, load BPF, attach sched_ext, or mutate host scheduler/cgroup state. Default host-safe checks continue to rely on `qa/no_host_mutation.sh`, `qa/no_frontend_root.sh`, and the release-withheld gates above.

The manual lane is intentionally reviewer-gated and isolated:

The protected-core suite invocation used by the protected lane is:

```bash
zig build vm-harness-matrix --summary all -- \
  --mode vm-required \
  --suite protected-core \
  --out evidence/lab/matrix/<run-id>
```

That command is not a default CI command. It is valid only after protected-runner prerequisites are satisfied; otherwise the lane must emit truthful `SKIP`, `REFUSE`, `INCIDENT`, or `FAIL` row evidence, or a `BLOCKED` bundle-level evidence manifest, with `host_mutation=false` and package the failure-closed artifacts for review. The protected-core suite must package `live-backend`, `workload-cpu-saturation`, `workload-cgroup-weight-quota`, and exactly one latency/churn row (`workload-interactive-latency` or `workload-scheduler-affinity-churn`). A PASS evidence manifest requires all selected protected-core rows to PASS; missing prerequisite rows must carry explicit reasons and remain non-release, non-production lab evidence.

- GitHub environment: `vm-proof-manual`, configured by repository owners as a protected environment with required reviewers and branch/tag restrictions before use.
- Runner: self-hosted labels `self-hosted`, `zig-scheduler-vm-proof`, and `disposable-vm`; hosted runners such as `ubuntu-latest` are not acceptable for this lane.
- Dispatch inputs: explicit audit id, rollback id, VM marker path `/run/zig-scheduler-vm-lab.marker`, and the exact `supported_tuple` string from `docs/releases/supported-kernel-tuples.md` that matches the protected runner kernel release.
- Artifact: GitHub Actions uploaded tarball `vm-proof-bundle.tar.zst` with explicit retention; it is not a release asset, not OCI, and not production approval.
- Provenance: the workflow requests GitHub artifact attestation and prints a `gh attestation verify` command for post-run verification.

Before dispatching the protected lane, the operator must run a runner preflight on the isolated self-hosted runner and preserve the transcript with the run evidence. The `supported_tuple` workflow input must be the existing Linux `>=6.12` tuple or the exact protected `7.1.1-2-cachyos` tuple and must correspond to the actual `uname -r` prefix; if the runner kernel does not match, stop with `SKIP`/`REFUSE` evidence instead of broadening the tuple contract.

```bash
set -euo pipefail
kernel_release="$(uname -r)"
supported_tuple="linux-6.12-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only" # replace 6.12 only with the matching protected-runner supported release prefix
printf 'kernel_release=%s\n' "$kernel_release"
printf 'workflow_supported_tuple=%s\n' "$supported_tuple"
case "$kernel_release" in
  6.1[2-9]*|6.[2-9][0-9]*|7.1.1-2-cachyos) ;;
  *) echo "REFUSE: protected runner kernel is outside the supported protected tuple"; exit 1 ;;
esac
test -d /sys/kernel/sched_ext
test -r /sys/kernel/btf/vmlinux
test -e /dev/kvm && test -r /dev/kvm && test -w /dev/kvm
command -v qemu-system-x86_64
qemu-system-x86_64 -accel help | grep -E '(^|[[:space:]])kvm($|[[:space:]])'
echo "$supported_tuple" | grep -E '^linux-(6\.(1[2-9]|[2-9][0-9])([.][0-9]+)?|7\.1\.1-2-cachyos)-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only$'
```

CachyOS is accepted only for the exact protected tuple `linux-7.1.1-2-cachyos-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only`; other CachyOS/downstream releases remain out of scope.

The `vm-proof-bundle.tar.zst` contract contains or accounts for: audit id, rollback id, VM marker, supported tuple, pre state, post state, rollback proof, cleanup proof, host refusal, matrix manifest, matrix rows, BPF metadata, BPF SKIP JSON when object metadata is unavailable, protected-environment-review.json generated from the current GitHub run review history, daemon events, live summary if present, static verification logs, and benchmark provenance for calibrated rows when applicable. Every included proof must preserve `host_mutation=false`, `release_eligible=false`, and `production_capacity_claim=false`.

Static protection is validated locally with:

```bash
python3 qa/manual_vm_proof_ci_check.py \
  --workflow .github/workflows/manual-vm-proof.yml \
  --docs docs/ci.md docs/runbooks/vm-lab.md docs/releases/governance-gate.md docs/security/review-checklist.md
```

This checker rejects unsafe default triggers, missing protected-environment/reviewer wording, untrusted runner labels, missing proof artifacts, release claims, production claims, and real-host attach allowances. The workflow must run `qa/protected_core_suite_check.py` and `qa/protected_core_telemetry_check.py --manifest evidence/lab/matrix/manual-vm-proof/manifest.json` before deriving any protected-core telemetry PASS or evidence-manifest PASS. A passing static check does not mean the protected environment was configured or that a human reviewer approved/executed the lane.

The manual proof bundle must also include `evidence-manifest.json`, validated by `qa/evidence_manifest_check.py` against `schemas/control/evidence-manifest.v1.schema.json`. The evidence manifest is the machine-readable provenance index for the protected VM proof bundle: it lists artifact paths, SHA-256 hashes, schema roles, audit id, rollback id, VM marker, supported tuple, BPF metadata or BPF SKIP JSON, daemon events, matrix manifest, benchmark provenance, protected-environment-review proof, rollback proof, cleanup proof, host refusal proof, privacy scan, and attestation status. The manifest records an explicit `outcome` derived from matrix rows and protected runner substrate proof, and remains `host_mutation=false`, `release_eligible=false`, and `production_capacity_claim=false`; it is not release approval and a local static pass does not prove the protected environment actually exists.

Protected runner substrate proof is recorded as `runner-substrate-proof.json` and checked with `qa/runner_substrate_proof_check.py` against `schemas/control/runner-substrate-proof.v1.schema.json`. It records runner class, runner group, runner labels, protected environment reviewer status, run URL, QEMU path, QEMU version, /dev/kvm status, accel mode, kernel tuple, BPF metadata, attestation status, and unavailable reasons. All paths in that proof are relative/non-traversing, `host_mutation=false`, `release_eligible=false`, and `production_capacity_claim=false`; an unavailable QEMU, empty QEMU version, /dev/kvm, reviewer signal, kernel BTF metadata unavailable, sched_ext kernel substrate unavailable, unsupported kernel release, placeholder kernel config hash, TCG accel, BPF SKIP metadata, or attestation capability must be an explicit SKIP/REFUSE reason and never a fake PASS. PASS requires `reviewer_status=approved`, a normalized `protected-environment-review.json` artifact for the same run, and a real GitHub Actions run URL; `not_exposed_by_github_actions_runtime` is never enough for PASS. A local refusal artifact that never dispatched the protected workflow may set `run_url=unavailable` only with `proof_outcome=SKIP` or `REFUSE` and an explicit unavailable reason.

Protected runner cleanliness proof is recorded as `runner-cleanliness-proof.json` and checked with `qa/runner_cleanliness_proof_check.py` against `schemas/control/runner-cleanliness-proof.v1.schema.json`. It is a companion artifact, not an extension of `runner-substrate-proof/v1`: it records JIT config, clean-machine boot/run identity, or a hashed ephemeral registration receipt; no-reuse evidence; runner removal receipt when applicable; the GitHub Actions run URL, and links to both `protected-environment-review.json` and `runner-substrate-proof.json`. GitHub runner labels alone are never cleanliness proof; a PASS cleanliness proof requires explicit no-reuse evidence plus either a removal receipt or a validator-enforced ephemeral registration receipt for in-job ephemeral cleanup while preserving `host_mutation=false`, `release_eligible=false`, and `production_capacity_claim=false`.

Current protected-core PASS evidence is recorded in `evidence/lab/protected-core-pass-20260703.md` for GitHub Actions run `28629448049` at commit `f049142f4beed827a0a797c2272eaf2502c266d1`. It remains lab-only evidence: do not cite it as release approval, production approval, a performance claim, or permission for real-host sched_ext attach.
