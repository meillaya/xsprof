# Task 9 — runner cleanup and deregistration ledger

Recorded: 2026-07-02T12:51:03-04:00 (`America/Toronto`) / 2026-07-02T16:51:03Z
Repository: `Meillaya/zig-scheduler`
Runner id/name: `25` / `zig-scheduler-vm-proof-20260702T144806Z-3202578`
Local disposable runner dir: `/home/mei/.omx-runs/zig-scheduler-gh-runner-20260702T144806Z`
Runner tmux session: `zig-scheduler-runner-20260702T144806Z`
Runner-local stress-ng profile: `/home/mei/.omx-runs/nix-profiles/zig-scheduler-vm-proof-stress-ng`
Scope: operational cleanup/evidence only; no product code edits.

## Cleanup status

**COMPLETE.** The GitHub self-hosted runner was removed, the local runner/tmux process surface is stopped, the disposable runner directory and runner-local stress-ng profile symlinks were deleted, and post-cleanup verification found no exact task process residue or task-scoped QEMU residue.

## Scenario ledger

| Scenario | Invocation | Binary observable | Captured artifact |
| --- | --- | --- | --- |
| Baseline GitHub inventory listed target runner | `gh api repos/Meillaya/zig-scheduler/actions/runners --paginate --jq '.runners[] | select(.id==25 or .name=="zig-scheduler-vm-proof-20260702T144806Z-3202578") ...'` | target runner present: `id=25`, `status=online`, `busy=false` | `artifacts/task-9-cleanup/github-runner-inventory-before.txt` |
| GitHub runner deregistration/removal | `gh api -X DELETE -i repos/Meillaya/zig-scheduler/actions/runners/25` | HTTP `204 No Content`, exit `0` | `artifacts/task-9-cleanup/github-runner-delete.txt` |
| Local runner/tmux stopped | `tmux has-session -t zig-scheduler-runner-20260702T144806Z`; process table scan for runner identifiers | target tmux session absent (`tmux_has_after=1`); no runner process rows after GitHub removal | `artifacts/task-9-cleanup/stop-local-runner.txt` |
| Disposable runner directory deleted | `rm -rf --one-file-system /home/mei/.omx-runs/zig-scheduler-gh-runner-20260702T144806Z` after exact-path safety check | path absent after deletion | `artifacts/task-9-cleanup/delete-local-paths.txt` |
| Runner-local stress-ng profile removed safely | `rm -f /home/mei/.omx-runs/nix-profiles/zig-scheduler-vm-proof-stress-ng /home/mei/.omx-runs/nix-profiles/zig-scheduler-vm-proof-stress-ng-1-link` after exact-path safety check | symlink and generation symlink absent; `/nix/store` target was not recursively deleted | `artifacts/task-9-cleanup/delete-local-paths.txt` |
| GitHub inventory no longer lists target runner | `gh api repos/Meillaya/zig-scheduler/actions/runners --paginate --jq '[.runners[] | select(.id==25 or .name=="zig-scheduler-vm-proof-20260702T144806Z-3202578")] | length'` | `target_runner_count=0` | `artifacts/task-9-cleanup/post-cleanup-verification-final.txt` |
| No exact task process residue | Python-filtered `ps -eo pid=,ppid=,pgid=,sid=,stat=,etime=,cmd=` for runner id/name/session/run id | `NO_EXACT_TASK_PROCESS_RESIDUE` | `artifacts/task-9-cleanup/post-cleanup-verification-final.txt` |
| No task-scoped QEMU residue | Python-filtered `ps -eo pid=,ppid=,pgid=,sid=,stat=,etime=,comm=,args=` where `comm` starts with `qemu` and args contain task indicators | `NO_TASK_QEMU_RESIDUE` | `artifacts/task-9-cleanup/post-cleanup-verification-final.txt` |
| Host scheduler mutation guard remains clean | `bash qa/no_host_mutation.sh` | `PASS: no host mutation observed for root commands and daemon live-VM bridge paths` | `artifacts/task-9-cleanup/no-host-mutation-gate.txt` |
| Run 28606271556 metadata captured for final classification | `gh run view 28606271556 --repo Meillaya/zig-scheduler --json ...` | workflow status `completed`, conclusion `success`; job completed successfully, but proof classification remains NON-PASS/SKIP per validators | `artifacts/task-9-cleanup/gh-run-28606271556.jsonl` |

## Notes

- `artifacts/task-9-cleanup/pre-delete-runner-safe-excerpts.txt` preserves non-secret runner log excerpts before deletion. It records the runner listener terminating with `Runner not found` after GitHub removal.
- `artifacts/task-9-cleanup/runner-metadata-safe.json` records safe runner metadata (`agentId`, `agentName`, pool, work folder) only; `.credentials` and private key material were not copied.
- Product source files were not edited.
- This cleanup does not convert run `28606271556` into a protected-core PASS and does not make a release, production, or performance claim.
