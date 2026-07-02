# Task 8 final QEMU rerun evidence

- Recorded UTC: 2026-07-02T16:46:54Z
- Run id: `28606271556`
- Run URL: https://github.com/Meillaya/zig-scheduler/actions/runs/28606271556
- Commit tested: `b6de9857b9ad327efadd4bf25a0d86383cff1f0b`
- Branch tested: `work/protected-multi-row-vm-scheduler-proof`
- Final classification: **NON-PASS / SKIP**
- Workflow conclusion: `success` / status `completed`
- Evidence manifest outcome: `SKIP`
- Raw artifact root: `artifacts/task-8-final-qemu-rerun/`

## Dispatch and approval
- Dispatch inputs: `artifacts/task-8-final-qemu-rerun/dispatch-inputs.env`
- Approval body used exact comment `manual protected VM proof only; not release approval`: `artifacts/task-8-final-qemu-rerun/approval-body.json`
- Pending deployment/approval response: `artifacts/task-8-final-qemu-rerun/pending-deployments-before-approval.json`, `artifacts/task-8-final-qemu-rerun/approval-response.json`
- Runner id 25 preflight: `artifacts/task-8-final-qemu-rerun/initial-context.txt`

## Bundle
- Downloaded bundle: `artifacts/task-8-final-qemu-rerun/download/vm-proof-bundle.tar.zst`
- Extracted bundle: `artifacts/task-8-final-qemu-rerun/extracted/`
- Tar listing: `artifacts/task-8-final-qemu-rerun/bundle-tar-list.txt`
- Artifact summary: `artifacts/task-8-final-qemu-rerun/artifact-summary.json`

## Row outcomes
| scenario | outcome | reason |
| --- | --- | --- |
| `live-backend` | `PASS` | live_backend_completed |
| `workload-cpu-saturation` | `REFUSE` | live workload workload-cpu-saturation refused or unavailable: status=PASS reason=vm_live_complete |
| `workload-cgroup-weight-quota` | `REFUSE` | live workload workload-cgroup-weight-quota refused or unavailable: status=PASS reason=vm_live_complete |
| `workload-scheduler-affinity-churn` | `REFUSE` | live workload workload-scheduler-affinity-churn refused or unavailable: status=PASS reason=vm_live_complete |

## Validator summary
| criterion | exit | observable | log/artifact |
| --- | ---: | --- | --- |
| `protected_core_suite` | `1` | FAIL protected-core suite: evidence/lab/matrix/manual-vm-proof/manifest.json.workload-cgroup-weight-quota must PASS for protected-core PASS proof | `artifacts/task-8-final-qemu-rerun/validators/protected_core_suite.log` |
| `protected_core_telemetry` | `1` | FAIL protected-core telemetry: sample[0].policy_counters must be unavailable when events are unavailable | `artifacts/task-8-final-qemu-rerun/validators/protected_core_telemetry.log` |
| `protected_review` | `0` | PASS protected review proof: evidence/lab/manual-vm-proof/protected-environment-review.json | `artifacts/task-8-final-qemu-rerun/validators/protected_review.log` |
| `runner_substrate` | `0` | PASS runner substrate proof: evidence/lab/manual-vm-proof/runner-substrate-proof.json | `artifacts/task-8-final-qemu-rerun/validators/runner_substrate.log` |
| `runner_cleanliness` | `0` | PASS runner cleanliness proof: evidence/lab/manual-vm-proof/runner-cleanliness-proof.json | `artifacts/task-8-final-qemu-rerun/validators/runner_cleanliness.log` |
| `evidence_manifest` | `0` | PASS evidence manifest: evidence/lab/manual-vm-proof/evidence-manifest.json | `artifacts/task-8-final-qemu-rerun/validators/evidence_manifest.log` |
| `matrix_contract` | `0` | PASS matrix-run contract: manifest=evidence/lab/matrix/manual-vm-proof/manifest.json valid=4 docs=/home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof/docs/control | `artifacts/task-8-final-qemu-rerun/validators/matrix_contract_rerun.log` |
| `live_behavior_live-backend` | `0` | PASS live behavior bundle: evidence/lab/matrix/manual-vm-proof/rows/live-backend/backend/live/summary.json | `artifacts/task-8-final-qemu-rerun/validators/live_behavior_live-backend.log` |
| `live_freshness_live-backend` | `0` | PASS live bundle freshness: evidence/lab/matrix/manual-vm-proof/rows/live-backend/backend/live/summary.json | `artifacts/task-8-final-qemu-rerun/validators/live_freshness_live-backend_rerun.log` |
| `live_behavior_workload-cpu-saturation` | `0` | PASS live behavior bundle: evidence/lab/matrix/manual-vm-proof/rows/workload-cpu-saturation/backend/live/summary.json | `artifacts/task-8-final-qemu-rerun/validators/live_behavior_workload-cpu-saturation.log` |
| `live_freshness_workload-cpu-saturation` | `0` | PASS live bundle freshness: evidence/lab/matrix/manual-vm-proof/rows/workload-cpu-saturation/backend/live/summary.json | `artifacts/task-8-final-qemu-rerun/validators/live_freshness_workload-cpu-saturation_rerun.log` |
| `live_behavior_workload-cgroup-weight-quota` | `0` | PASS live behavior bundle: evidence/lab/matrix/manual-vm-proof/rows/workload-cgroup-weight-quota/backend/live/summary.json | `artifacts/task-8-final-qemu-rerun/validators/live_behavior_workload-cgroup-weight-quota.log` |
| `live_freshness_workload-cgroup-weight-quota` | `0` | PASS live bundle freshness: evidence/lab/matrix/manual-vm-proof/rows/workload-cgroup-weight-quota/backend/live/summary.json | `artifacts/task-8-final-qemu-rerun/validators/live_freshness_workload-cgroup-weight-quota_rerun.log` |
| `live_behavior_workload-scheduler-affinity-churn` | `0` | PASS live behavior bundle: evidence/lab/matrix/manual-vm-proof/rows/workload-scheduler-affinity-churn/backend/live/summary.json | `artifacts/task-8-final-qemu-rerun/validators/live_behavior_workload-scheduler-affinity-churn.log` |
| `live_freshness_workload-scheduler-affinity-churn` | `0` | PASS live bundle freshness: evidence/lab/matrix/manual-vm-proof/rows/workload-scheduler-affinity-churn/backend/live/summary.json | `artifacts/task-8-final-qemu-rerun/validators/live_freshness_workload-scheduler-affinity-churn_rerun.log` |
| `gh_attestation` | `0` | verified_count=1 | `artifacts/task-8-final-qemu-rerun/validators/gh_attestation_strict_summary.json` |

## Exact blockers
- evidence-manifest outcome is SKIP not PASS
- runner-cleanliness proof_outcome is SKIP not PASS
- workload-cpu-saturation row outcome REFUSE: live workload workload-cpu-saturation refused or unavailable: status=PASS reason=vm_live_complete
- workload-cgroup-weight-quota row outcome REFUSE: live workload workload-cgroup-weight-quota refused or unavailable: status=PASS reason=vm_live_complete
- workload-scheduler-affinity-churn row outcome REFUSE: live workload workload-scheduler-affinity-churn refused or unavailable: status=PASS reason=vm_live_complete
- protected_core_suite validator exit 1: FAIL protected-core suite: evidence/lab/matrix/manual-vm-proof/manifest.json.workload-cgroup-weight-quota must PASS for protected-core PASS proof
- protected_core_telemetry validator exit 1: FAIL protected-core telemetry: sample[0].policy_counters must be unavailable when events are unavailable

## Attestation
- Strict `gh attestation verify --source-digest --source-ref --format json` verified count: `1`
- Attested subject SHA-256: `db134e36debb5d5d4a14ffdc4ed063cb4b5123aef0454bc7efc80235d91e10f7`
- Attestation source digest/ref: `b6de9857b9ad327efadd4bf25a0d86383cff1f0b` / `refs/heads/work/protected-multi-row-vm-scheduler-proof`

## Notes
- Product code was not edited. Operational evidence files only were created under `.omo/evidence/` and `artifacts/`.
- `matrix_contract` and live freshness were rerun with corrected protected source schema/docs and extracted current BPF object baseline; superseded failed invocations remain in raw validator logs for auditability.
