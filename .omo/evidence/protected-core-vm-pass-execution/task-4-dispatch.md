# Todo 4 Dispatch Evidence — Protected Manual VM Proof Workflow

## Summary
- Repository: `Meillaya/zig-scheduler`
- Workflow: `.github/workflows/manual-vm-proof.yml`
- Branch/ref: `work/protected-multi-row-vm-scheduler-proof`
- Pre-dispatch remote head: `8c451e0a5143f03f633edeaa8a13711ff0e5c3df`
- Run ID: `28600509667`
- Run URL: https://github.com/Meillaya/zig-scheduler/actions/runs/28600509667
- Run status at capture: `waiting`
- Run conclusion at capture: ``
- Audit ID: `AUD-20260702T150804Z-8c451e0a5143-28e445`
- Rollback ID: `RB-protected-core-8c451e0a5143`
- Supported tuple: `linux-7.1.1-2-cachyos-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only`
- VM marker path: `/run/zig-scheduler-vm-lab.marker`
- VM-only confirmation: `disposable VM-only proof; no host attach`
- Approval acknowledgement: `manual protected VM proof only; not release approval`
- Environment state: pending deployment for vm-proof-manual captured
- Todo boundary: stopped after dispatch verification; did not approve environment, watch to completion, download artifacts, cancel, or edit product files.

## Exact dispatch command

```bash
gh workflow run manual-vm-proof.yml --repo Meillaya/zig-scheduler --ref work/protected-multi-row-vm-scheduler-proof -f audit_id="AUD-20260702T150804Z-8c451e0a5143-28e445" -f rollback_id="RB-protected-core-8c451e0a5143" -f vm_marker_path="/run/zig-scheduler-vm-lab.marker" -f supported_tuple="linux-7.1.1-2-cachyos-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only" -f confirm_vm_only="disposable VM-only proof; no host attach" -f approval_ack="manual protected VM proof only; not release approval"
```

## Verification results
- `git ls-remote --heads origin work/protected-multi-row-vm-scheduler-proof` returned `8c451e0a5143f03f633edeaa8a13711ff0e5c3df`.
- Runner inventory was captured before dispatch with `gh api repos/Meillaya/zig-scheduler/actions/runners` and showed one online, non-busy runner with labels `self-hosted`, `Linux`, `X64`, `zig-scheduler-vm-proof`, and `disposable-vm`.
- `gh workflow run` returned run URL `https://github.com/Meillaya/zig-scheduler/actions/runs/28600509667`.
- `gh run list --repo Meillaya/zig-scheduler --workflow manual-vm-proof.yml --limit 10 --json databaseId,status,conclusion,headBranch,headSha,event,url,createdAt` found run `28600509667` created at `2026-07-02T15:08:05Z`.
- `gh run view 28600509667 --repo Meillaya/zig-scheduler --json databaseId,status,conclusion,headBranch,headSha,event,url,createdAt` confirmed:
  - `event`: `workflow_dispatch`
  - `headBranch`: `work/protected-multi-row-vm-scheduler-proof`
  - `headSha`: `8c451e0a5143f03f633edeaa8a13711ff0e5c3df`
  - `status`: `waiting`
- Remote head equality verdict: `PASS` (`run.headSha == pre-dispatch remote head`).
- Pending deployments captured via `gh api repos/Meillaya/zig-scheduler/actions/runs/28600509667/pending_deployments`; current state includes environment `vm-proof-manual` and `current_user_can_approve=true`, but Todo 5 approval was not performed.

## manualQa

### surfaceEvidence
| scenario id | criterion reference | surface | exact invocation | verdict | artifactRefs |
| --- | --- | --- | --- | --- | --- |
| T4-SE-01 | Capture remote branch head before dispatch | CLI | `git ls-remote --heads origin work/protected-multi-row-vm-scheduler-proof` | PASS | A1 |
| T4-SE-02 | Capture runner inventory before dispatch | GitHub API via gh | `gh api repos/Meillaya/zig-scheduler/actions/runners --jq '{total_count, runners: [.runners[] | {id,name,os,status,busy,labels:[.labels[].name]}]}'` | PASS | A1 |
| T4-SE-03 | Dispatch exact protected workflow command with generated IDs | GitHub CLI | `gh workflow run manual-vm-proof.yml --repo Meillaya/zig-scheduler --ref work/protected-multi-row-vm-scheduler-proof -f audit_id="$audit_id" -f rollback_id="$rollback_id" -f vm_marker_path="/run/zig-scheduler-vm-lab.marker" -f supported_tuple="linux-7.1.1-2-cachyos-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only" -f confirm_vm_only="disposable VM-only proof; no host attach" -f approval_ack="manual protected VM proof only; not release approval"` | PASS | A2, A3 |
| T4-SE-04 | Find current workflow_dispatch run after dispatch | GitHub CLI | `gh run list --repo Meillaya/zig-scheduler --workflow manual-vm-proof.yml --limit 10 --json databaseId,status,conclusion,headBranch,headSha,event,url,createdAt` | PASS | A3, A4, A5 |
| T4-SE-05 | Verify selected run branch/head/event/status | GitHub CLI | `gh run view 28600509667 --repo Meillaya/zig-scheduler --json databaseId,status,conclusion,headBranch,headSha,event,url,createdAt` | PASS | A6, A8 |
| T4-SE-06 | Capture protected environment pending state without approval | GitHub API via gh | `gh api repos/Meillaya/zig-scheduler/actions/runs/28600509667/pending_deployments` | PASS | A7, A8 |

### adversarialCases
| scenario id | criterion reference | adversarial class | expected behavior | verdict | artifactRefs |
| --- | --- | --- | --- | --- | --- |
| T4-ADV-01 | Stale state guard | stale_state | Reject stale dispatch evidence unless `run.headSha` equals pre-dispatch remote branch head `8c451e0a5143f03f633edeaa8a13711ff0e5c3df`. | PASS | A1, A6 |
| T4-ADV-02 | Dirty worktree guard | dirty_worktree | No product edits before dispatch and no product edits after dispatch; evidence-only files are created after capture. | PASS | A1, A8 |
| T4-ADV-03 | Do not trust dispatch output alone | misleading_success_output | Treat `gh workflow run` URL as insufficient; confirm with `gh run list` and `gh run view`. | PASS | A3, A4, A6 |
| T4-ADV-04 | External runner state captured | external_state_absence | Record live runner inventory before dispatch so missing runner state cannot be inferred. | PASS | A1 |
| T4-ADV-05 | Privacy | privacy | Do not record GitHub tokens/secrets; artifacts contain command outputs and public GitHub API fields only. | PASS | A1-A8 |
| T4-ADV-06 | Resume after interruption | repeated_interruptions | Persist fresh `audit_id`, `rollback_id`, remote SHA, and run ID for resumption. | PASS | A2, A5, A6 |
| T4-ADV-07 | Todo boundary guard | scope_boundary | Do not approve `vm-proof-manual`, do not watch to completion, do not download artifacts, and do not cancel unless wrong/stale. | PASS | A7, A8 |

### artifactRefs
| id | kind | description | path | bytes | verdict |
| --- | --- | --- | --- | ---: | --- |
| A1 | text | Pre-dispatch local status, remote branch head, and runner inventory transcript | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-4-dispatch/pre-dispatch-state.txt` | 761 | non-empty |
| A2 | env | Generated audit/rollback IDs, supported tuple, remote SHA, and dispatch timestamp | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-4-dispatch/ids.env` | 291 | non-empty |
| A3 | text | Workflow dispatch command output and run list JSON capture transcript | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-4-dispatch/dispatch-and-list.txt` | 3946 | non-empty |
| A4 | json | Raw gh run list output used to select the current workflow_dispatch run | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-4-dispatch/run-list.json` | 2911 | non-empty |
| A5 | json | Selected matching run from run list | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-4-dispatch/selected-run.json` | 345 | non-empty |
| A6 | json | Raw gh run view output for selected run | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-4-dispatch/run-view.json` | 312 | non-empty |
| A7 | json | Pending deployments API output for selected run | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-4-dispatch/pending-deployments.json` | 1392 | non-empty |
| A8 | text | Run view, pending deployments, and post-dispatch local status transcript | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-4-dispatch/run-view-pending-status.txt` | 2185 | non-empty |

## DoneClaim
Todo 4 is complete: a current `workflow_dispatch` run exists on `work/protected-multi-row-vm-scheduler-proof` at the exact pre-dispatch remote head SHA, generated IDs are recorded, runner inventory and pending protected environment state are captured, and execution stopped before Todo 5 approval/watch/download work.
