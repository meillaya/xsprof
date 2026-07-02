# Task 8 rerun provisioning evidence

Date: 2026-07-02
Scope: protected-core VM proof rerun evidence only; no product, frontend, simulator, validator, release, production, or performance changes.

## Result

Non-PASS remains.

- Fresh workflow run: 28603050367
- Run URL: https://github.com/Meillaya/zig-scheduler/actions/runs/28603050367
- Branch/SHA tested: `work/protected-multi-row-vm-scheduler-proof` at `8c451e0a5143f03f633edeaa8a13711ff0e5c3df`
- GitHub workflow conclusion: success
- Protected-core proof outcome: non-PASS (`evidence-manifest.json` outcome `SKIP`; protected-core workload rows `REFUSE`)
- Bundle: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/download/vm-proof-bundle.tar.zst`
- Bundle SHA-256: `bf63c43d37a01161b959a8f2fe21e970d0b0257720001ab9d495da7f03a5dbf1`

## Runner-local provisioning performed

Reversible runner-local provisioning was created under `/home/mei/.omx-runs` only:

1. Installed stress-ng into Nix profile `/home/mei/.omx-runs/nix-profiles/zig-scheduler-vm-proof-stress-ng`.
2. Backed up the runner `.path` to `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/runner.path.before`.
3. Prepended `/home/mei/.omx-runs/nix-profiles/zig-scheduler-vm-proof-stress-ng/bin` to runner `.path`.
4. Restarted tmux runner session `zig-scheduler-runner-20260702T144806Z` with `PATH="$(cat .path)"`.
5. Verified runner listener process PATH contains the stress-ng profile and GitHub runner id 25 is online.

Key evidence:

- Provision log: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/stress-ng-provisioning.log`
- Runner restart log: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/runner-restart-fixed-path.log`
- Precise listener env: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/runner-listener-env-precise.txt`
- Runner before state: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/runner-before.txt`

## Dispatch and protected environment approval

Inputs used:

- `audit_id=AUD-20260702T154700Z-8c451e0a51-a8b8c8`
- `rollback_id=RB-task-8-rerun-stress-ng`
- `vm_marker_path=/run/zig-scheduler-vm-lab.marker`
- `supported_tuple=linux-7.1.1-2-cachyos-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only`
- `confirm_vm_only=disposable VM-only proof; no host attach`
- `approval_ack=manual protected VM proof only; not release approval`

Approval evidence:

- Dispatch log: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/workflow-dispatch.log` (contains an initial stale run-id selection error)
- Corrected run id log: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/workflow-dispatch-corrected-run-id.log`
- Pending deployment before approval: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/pending-deployments-before-approval.json`
- Approval request: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/approval-request.json`
- Approval response: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/approval-response.json`
- Watch log: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/run-watch.log`
- Final run metadata: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/run-view-final-full.json`
- Full GitHub job log: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/run.log`

## Downloaded artifacts and validators

Downloaded/extracted artifact paths:

- Download log: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/download-extract.log`
- Bundle contents listing: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/vm-proof-bundle.contents.txt`
- Extracted file listing: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/extracted-files.txt`
- Extracted bundle root: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/extracted/`

Validator evidence:

- Clean validator worktree setup: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/clean-verifier-worktree.log`
- Contract/proof validator summary: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/validator-rc-summary.tsv`
- Local validation/root-cause summary: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/validation-summary-and-root-cause.txt`
- Clean worktree evidence manifest + runner cleanliness: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/clean-worktree-validation.out`
- Protected-core validators: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/clean-worktree-protected-core-validators.out`
- Attestation JSON log: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/gh-attestation-verify-json.log`
- Attestation JSON: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/gh-attestation-verify.json`

Observed validator outcomes:

| Check | Result |
| --- | --- |
| matrix_run_contract_check | PASS |
| protected_environment_review_check | PASS |
| runner_substrate_proof_check | PASS |
| runner_cleanliness_proof_check | PASS after correct invocation in clean worktree |
| evidence_manifest_check | PASS in clean worktree |
| gh attestation verify --format json | PASS; subject digest matches bundle SHA-256 |
| protected_core_telemetry_check | FAIL |
| protected_core_suite_check | FAIL |

Attestation verified the bundle subject digest `bf63c43d37a01161b959a8f2fe21e970d0b0257720001ab9d495da7f03a5dbf1`, source ref `refs/heads/work/protected-multi-row-vm-scheduler-proof`, and source commit `8c451e0a5143f03f633edeaa8a13711ff0e5c3df`.

## Non-PASS root cause

The runner host can now find `stress-ng`, but the protected-core workload rows still fail inside the disposable microVM guest. The guest serial evidence reports:

- `workload-cpu-saturation`: `missing VM-local workload tool: stress-ng`
- `workload-cgroup-weight-quota`: `missing VM-local workload tool: stress-ng`
- `workload-scheduler-affinity-churn`: `missing VM-local workload tool: stress-ng`

The initramfs placement probe shows `stress-ng` was copied into the guest at the runner-local Nix profile path:

`home/mei/.omx-runs/nix-profiles/zig-scheduler-vm-proof-stress-ng/bin/stress-ng`

but the guest init script uses `PATH=/bin:/usr/bin`, so VM-local `command -v stress-ng` still fails. Exact evidence:

- Workload failure detail: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/workload-runner-failure-detail.log`
- Initramfs placement probe: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/initramfs-stress-ng-placement.log`
- Protected-core non-pass reasons from bundle: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-rerun/extracted/evidence/lab/manual-vm-proof/static-logs/protected-core-non-pass-reasons.txt`

No validators were weakened. No product/release/production/performance claim is made.
