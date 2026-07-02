# Final classification ledger — protected-core VM proof execution

Recorded: 2026-07-02T12:51:03-04:00 (`America/Toronto`) / 2026-07-02T16:51:03Z
Workflow run: `28606271556`
Run URL: https://github.com/Meillaya/zig-scheduler/actions/runs/28606271556
Workflow: `manual-vm-proof`
Branch/SHA tested: `work/protected-multi-row-vm-scheduler-proof` / `b6de9857b9ad327efadd4bf25a0d86383cff1f0b`

## Final classification

**NON-PASS / SKIP.** GitHub Actions reports workflow conclusion `success`, but the protected-core proof criteria were not satisfied. The successful workflow only proves that the guarded workflow completed and uploaded/attested a bundle; it is not a protected-core PASS.

## Blocking evidence for NON-PASS/SKIP

| Blocker | Binary observable | Artifact |
| --- | --- | --- |
| Evidence manifest classified the proof as SKIP, not PASS | `Evidence manifest outcome: SKIP` in the Task 8 final QEMU rerun evidence | `.omo/evidence/protected-core-vm-pass-execution/task-8-final-qemu-rerun.md` |
| Runner cleanliness proof outcome was SKIP, not PASS | `runner-cleanliness proof_outcome is SKIP not PASS` in exact blocker list | `.omo/evidence/protected-core-vm-pass-execution/task-8-final-qemu-rerun.md` |
| Protected-core workload rows did not reach PASS | manifest rows `workload-cpu-saturation`, `workload-cgroup-weight-quota`, and `workload-scheduler-affinity-churn` are `REFUSE` | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/manifest-row-outcomes.tsv` |
| Protected-core suite validator failed | `protected_core_suite` exit `1`; `workload-cgroup-weight-quota must PASS for protected-core PASS proof` | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/validator-results.tsv`, `.omo/evidence/protected-core-vm-pass-execution/task-8-final-qemu-rerun.md` |
| Protected-core telemetry validator failed | `protected_core_telemetry` exit `1`; `sample[0].policy_counters must be unavailable when events are unavailable` | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/validator-results.tsv`, `.omo/evidence/protected-core-vm-pass-execution/task-8-final-qemu-rerun.md` |

## Positive evidence that does not upgrade the classification

- GitHub run `28606271556` completed with conclusion `success` and job `reviewer-gated disposable VM proof` completed successfully: `artifacts/task-9-cleanup/gh-run-28606271556.jsonl`.
- Protected environment review, runner substrate, runner cleanliness validator shape, evidence manifest schema, matrix contract rerun, live behavior/freshness reruns, and GitHub attestation had passing observables where noted in `.omo/evidence/protected-core-vm-pass-execution/task-8-final-qemu-rerun.md`.
- Those positive observables are insufficient because the manifest/evidence outcomes and protected-core validators above still block PASS.

## Cleanup and safety closure

| Closure item | Binary observable | Artifact |
| --- | --- | --- |
| GitHub self-hosted runner removed | `DELETE repos/Meillaya/zig-scheduler/actions/runners/25` returned HTTP `204 No Content` | `artifacts/task-9-cleanup/github-runner-delete.txt` |
| Runner inventory clean | target runner count `0` for id/name query | `artifacts/task-9-cleanup/post-cleanup-verification-final.txt` |
| Local disposable runner directory removed | `ABSENT /home/mei/.omx-runs/zig-scheduler-gh-runner-20260702T144806Z` | `artifacts/task-9-cleanup/post-cleanup-verification-final.txt` |
| Runner-local stress-ng profile symlinks removed | `ABSENT /home/mei/.omx-runs/nix-profiles/zig-scheduler-vm-proof-stress-ng` and `...-1-link` | `artifacts/task-9-cleanup/post-cleanup-verification-final.txt` |
| Runner/tmux/process residue absent | `tmux_has_session_exit=1`, `NO_EXACT_TASK_PROCESS_RESIDUE` | `artifacts/task-9-cleanup/post-cleanup-verification-final.txt` |
| Task-scoped QEMU residue absent | `NO_TASK_QEMU_RESIDUE` | `artifacts/task-9-cleanup/post-cleanup-verification-final.txt` |
| Host scheduler mutation guard clean | `PASS: no host mutation observed for root commands and daemon live-VM bridge paths` | `artifacts/task-9-cleanup/no-host-mutation-gate.txt` |

## Claim boundaries

- No host scheduler mutation claim: the run remains host-safe; the cleanup only removed the explicitly disposable GitHub runner resources and local runner profile/dir.
- No release eligibility claim.
- No production readiness or production capacity claim.
- No performance claim or benchmark claim.
- No protected-core PASS claim.
