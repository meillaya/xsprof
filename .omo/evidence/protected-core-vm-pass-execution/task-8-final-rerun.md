# Task 8 final rerun evidence

## Run
- Workflow: `.github/workflows/manual-vm-proof.yml`
- Branch: `work/protected-multi-row-vm-scheduler-proof`
- Protected branch commit: `5e6518649edc6aaa667db0efd0fd6356f1b8749d`
- Run ID: `28604671999`
- Run URL: https://github.com/Meillaya/zig-scheduler/actions/runs/28604671999
- Runner id 25 pre-dispatch observable: online, idle, labels `self-hosted`, `Linux`, `X64`, `zig-scheduler-vm-proof`, `disposable-vm` artifact `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/runner-25-pre-dispatch-observable.json`
- Audit ID: `AUD-20260702T161209Z-5e6518649edc-3f5169`
- Rollback ID: `RB-task-8-final-rerun-20260702T161209Z`
- Supported tuple: `linux-7.1.1-2-cachyos-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only`
- Environment: `vm-proof-manual`
- Approval comment: `manual protected VM proof only; not release approval`

## Artifact capture
- Raw artifact directory: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun`
- Downloaded bundle: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/download/vm-proof-bundle.tar.zst`
- Extracted bundle CWD: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/extracted`
- Validation overlay for live freshness only: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validation-cwd`
- Bundle SHA-256: `f27f562f4398a6b4affa03cdf1c20505db7cda42923e256506c9a7a1162db837`
- Artifact list: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/artifacts-list.json`
- Run log: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/gh-run.log`
- Watch log: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/gh-run-watch.log`
- Attestation summary: `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/gh-attestation-summary.json`

## Final classification
NON-PASS

Protected-core PASS is not established. The GitHub Actions run completed successfully and produced/attested `vm-proof-bundle`, but the canonical protected-core suite validator failed against the extracted matrix manifest.

## Exact non-PASS root cause
- protected_core_suite: FAIL protected-core suite: evidence/lab/matrix/manual-vm-proof/manifest.json.live-backend must PASS for protected-core PASS proof

The matrix manifest row outcomes are:

```text
scenario_id	outcome	reason
live-backend	REFUSE	live backend live summary malformed
workload-cpu-saturation	REFUSE	live workload workload-cpu-saturation refused or unavailable: status=PASS reason=vm_live_complete
workload-cgroup-weight-quota	REFUSE	live workload workload-cgroup-weight-quota refused or unavailable: status=PASS reason=vm_live_complete
workload-scheduler-affinity-churn	REFUSE	live workload workload-scheduler-affinity-churn refused or unavailable: status=PASS reason=vm_live_complete
```

## Validator summary
Canonical validators used protected branch scripts from `/home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof` at `5e6518649edc6aaa667db0efd0fd6356f1b8749d`. Evidence-manifest validation was invoked from the extracted bundle CWD with `--source-root /home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof`.

```text
validator	status	exit_code	log
protected_core_suite	FAIL	1	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/protected_core_suite.log
protected_core_telemetry	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/protected_core_telemetry.log
live_behavior_evidence_lab_matrix_manual-vm-proof_rows_workload-cgroup-weight-quota_backend_live_summary_json	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/live_behavior_evidence_lab_matrix_manual-vm-proof_rows_workload-cgroup-weight-quota_backend_live_summary_json.log
live_behavior_evidence_lab_matrix_manual-vm-proof_rows_workload-cpu-saturation_backend_live_summary_json	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/live_behavior_evidence_lab_matrix_manual-vm-proof_rows_workload-cpu-saturation_backend_live_summary_json.log
live_behavior_evidence_lab_matrix_manual-vm-proof_rows_workload-scheduler-affinity-churn_backend_live_summary_json	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/live_behavior_evidence_lab_matrix_manual-vm-proof_rows_workload-scheduler-affinity-churn_backend_live_summary_json.log
live_freshness_evidence_lab_matrix_manual-vm-proof_rows_workload-cgroup-weight-quota_backend_live_summary_json	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/live_freshness_evidence_lab_matrix_manual-vm-proof_rows_workload-cgroup-weight-quota_backend_live_summary_json.log
live_freshness_evidence_lab_matrix_manual-vm-proof_rows_workload-cpu-saturation_backend_live_summary_json	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/live_freshness_evidence_lab_matrix_manual-vm-proof_rows_workload-cpu-saturation_backend_live_summary_json.log
live_freshness_evidence_lab_matrix_manual-vm-proof_rows_workload-scheduler-affinity-churn_backend_live_summary_json	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/live_freshness_evidence_lab_matrix_manual-vm-proof_rows_workload-scheduler-affinity-churn_backend_live_summary_json.log
runner_cleanliness	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/runner_cleanliness.log
evidence_manifest	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/evidence_manifest.log
protected_review	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/protected_review.log
runner_substrate	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/runner_substrate.log
gh_attestation	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/gh_attestation.log
matrix_contract_source_root	PASS	0	.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/matrix_contract_source_root.log
```

Notes:
- `matrix_contract_source_root` is the valid matrix-contract result for this rerun: extracted CWD plus protected branch schemas/docs.
- `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/matrix_contract.log` records an initial superseded invocation against the bundle's reduced schema subset; it failed because `schemas/control/matrix-run.v1.schema.json` is not included in the bundle subset.
- Live behavior and freshness passed for the three workload live summaries present under `backend/live/summary.json`.

## Attestation observable

```json
[{"runnerEnvironment":"self-hosted","sourceRepositoryDigest":"5e6518649edc6aaa667db0efd0fd6356f1b8749d","sourceRepositoryRef":"refs/heads/work/protected-multi-row-vm-scheduler-proof","subject":[{"digest":{"sha256":"f27f562f4398a6b4affa03cdf1c20505db7cda42923e256506c9a7a1162db837"},"name":"vm-proof-bundle.tar.zst"}],"timestamp":"2026-07-02T12:16:02-04:00","workflow":"manual-vm-proof"}]
```

## Required scenario/invocation/artifact mapping
- Dispatch: `gh workflow run .github/workflows/manual-vm-proof.yml --ref work/protected-multi-row-vm-scheduler-proof ...`, observable run `28604671999`, artifact `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/dispatch-command.log`.
- Approval: GitHub pending deployments API approved environment `vm-proof-manual` with exact comment `manual protected VM proof only; not release approval`, artifact `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/approval-response.json`.
- Watch: `gh run watch 28604671999 --interval 30 --exit-status`, observable exit 0, artifact `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/gh-run-watch.log`.
- Download/extract: `gh run download 28604671999 --name vm-proof-bundle`, observable bundle SHA `f27f562f4398a6b4affa03cdf1c20505db7cda42923e256506c9a7a1162db837`, artifacts `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/downloaded-files.txt` and `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/vm-proof-bundle-tar-list.txt`.
- Protected core suite/telemetry: `python3 qa/protected_core_* --manifest evidence/lab/matrix/manual-vm-proof/manifest.json`, artifacts under `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators`.
- Live behavior/freshness: `python3 qa/live_* --bundle <row>/backend/live/summary.json`, artifacts under `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators`.
- Runner cleanliness/review/substrate/evidence manifest/matrix contract: protected branch validators, artifacts under `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators`.
- GitHub attestation: `gh attestation verify .omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/download/vm-proof-bundle.tar.zst --repo Meillaya/zig-scheduler --source-ref refs/heads/work/protected-multi-row-vm-scheduler-proof --source-digest 5e6518649edc6aaa667db0efd0fd6356f1b8749d`, artifact `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-rerun/validators/gh_attestation.log`.
