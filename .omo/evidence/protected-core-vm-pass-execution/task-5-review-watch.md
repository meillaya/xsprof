# Task 5 protected environment review + run watch evidence

Run: `28600509667`  
Repository: `Meillaya/zig-scheduler`  
Surface: CLI/GitHub API and GitHub run status observation  
Required approval comment: `manual protected VM proof only; not release approval`  
Evidence captured: 2026-07-02 UTC

## Summary verdict

PASS for Todo 5 scope only: protected environment approval evidence was captured with the exact required comment, the post-approval pending deployment set became empty, and `gh run watch 28600509667 --repo Meillaya/zig-scheduler --exit-status` completed with exit code 0. Final `gh run view` reports `status=completed`, `conclusion=success`, branch `work/protected-multi-row-vm-scheduler-proof`, and head SHA `8c451e0a5143f03f633edeaa8a13711ff0e5c3df`.

This is **not** a Todo 6 artifact-download claim and **not** a Todo 7 bundle-validator claim. No workflow artifacts were downloaded and no bundle validators were run in this task.

## Key raw observations

- Pre-approval pending deployment existed for environment `vm-proof-manual` with `environment.id=17499459504` and `current_user_can_approve=true`.
- Approval was applied through the documented pending-deployments review endpoint using request body `{ "environment_ids": [17499459504], "state": "approved", "comment": "manual protected VM proof only; not release approval" }`.
- `gh api repos/Meillaya/zig-scheduler/actions/runs/28600509667/approvals` returned reviewer `Meillaya`, state `approved`, environment `vm-proof-manual`, and the exact required comment.
- Post-approval and post-watch pending deployments were `[]`.
- Deployment `5286635009` advanced through `waiting`, `queued`, `in_progress`, then `success` for environment `vm-proof-manual`.
- Watch output ended with `exit_code=0` and all job steps successful.
- Final run metadata: `status=completed`, `conclusion=success`, `headBranch=work/protected-multi-row-vm-scheduler-proof`, `headSha=8c451e0a5143f03f633edeaa8a13711ff0e5c3df`.
- Remote branch head check returned the same SHA: `8c451e0a5143f03f633edeaa8a13711ff0e5c3df`.

## manualQa

```yaml
surfaceEvidence:
  - scenarioId: task5-pre-approval-pending
    criterionRef: "Todo 5 VERIFY: capture pending deployments before approval"
    surface: "CLI/GitHub API"
    exactInvocation: "gh api repos/Meillaya/zig-scheduler/actions/runs/28600509667/pending_deployments"
    verdict: PASS
    artifactRefs:
      - A01
  - scenarioId: task5-approval-api
    criterionRef: "Todo 5: apply/observe reviewer approval with exact comment"
    surface: "CLI/GitHub API"
    exactInvocation: "gh api --method POST repos/Meillaya/zig-scheduler/actions/runs/28600509667/pending_deployments --input .omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/02-approval-request.json"
    verdict: PASS
    artifactRefs:
      - A02
      - A03
  - scenarioId: task5-post-approval-pending-empty
    criterionRef: "Todo 5 VERIFY: capture pending deployments after approval"
    surface: "CLI/GitHub API"
    exactInvocation: "gh api repos/Meillaya/zig-scheduler/actions/runs/28600509667/pending_deployments"
    verdict: PASS
    artifactRefs:
      - A04
  - scenarioId: task5-review-record
    criterionRef: "Todo 5 acceptance: protected environment approval record, reviewer, comment"
    surface: "CLI/GitHub API"
    exactInvocation: "gh api repos/Meillaya/zig-scheduler/actions/runs/28600509667/approvals"
    verdict: PASS
    artifactRefs:
      - A06
      - A12
  - scenarioId: task5-deployment-statuses
    criterionRef: "Todo 5 acceptance: approval/deployment evidence available via REST"
    surface: "CLI/GitHub API"
    exactInvocation: "gh api repos/Meillaya/zig-scheduler/deployments/5286635009/statuses"
    verdict: PASS
    artifactRefs:
      - A05
      - A11
  - scenarioId: task5-watch-to-completion
    criterionRef: "Todo 5 acceptance: gh run watch output captured"
    surface: "CLI/GitHub run status observation"
    exactInvocation: "timeout 7200s gh run watch 28600509667 --repo Meillaya/zig-scheduler --exit-status"
    verdict: PASS
    artifactRefs:
      - A08
  - scenarioId: task5-final-run-view
    criterionRef: "Todo 5 VERIFY: final gh run view JSON"
    surface: "CLI/GitHub CLI"
    exactInvocation: "gh run view 28600509667 --repo Meillaya/zig-scheduler --json databaseId,status,conclusion,headBranch,headSha,event,url,createdAt,updatedAt"
    verdict: PASS
    artifactRefs:
      - A09
  - scenarioId: task5-job-steps-after-watch
    criterionRef: "Todo 5: runner log/status observation if useful"
    surface: "CLI/GitHub CLI"
    exactInvocation: "gh run view 28600509667 --repo Meillaya/zig-scheduler --json jobs"
    verdict: PASS
    artifactRefs:
      - A10

adversarialCases:
  - scenarioId: adv-stale-state
    criterionRef: "Adversarial: stale_state (head SHA/branch still exact)"
    adversarialClass: stale_state
    expectedBehavior: "Final run branch/SHA must still match the protected branch head; stale/wrong branch would block or prevent PASS."
    verdict: PASS
    artifactRefs:
      - A09
      - A14
  - scenarioId: adv-misleading-success-output
    criterionRef: "Adversarial: misleading_success_output (run view after watch)"
    adversarialClass: misleading_success_output
    expectedBehavior: "Do not trust watch output alone; final gh run view must independently report completed/success."
    verdict: PASS
    artifactRefs:
      - A08
      - A09
  - scenarioId: adv-external-approval-boundary
    criterionRef: "Adversarial: external approval boundary (record API evidence)"
    adversarialClass: external_approval_boundary
    expectedBehavior: "Approval must be represented by GitHub API review/deployment evidence with exact comment; labels or success alone are insufficient."
    verdict: PASS
    artifactRefs:
      - A01
      - A02
      - A03
      - A04
      - A06
      - A12
  - scenarioId: adv-privacy
    criterionRef: "Adversarial: privacy (no tokens)"
    adversarialClass: privacy
    expectedBehavior: "Evidence artifacts must not contain GitHub token or Authorization header markers."
    verdict: PASS
    artifactRefs:
      - A15
  - scenarioId: adv-hung-command
    criterionRef: "Adversarial: hung command (bounded watch; if timeout, record running state)"
    adversarialClass: hung_command
    expectedBehavior: "Watch invocation is bounded by timeout and must record exit status; if timed out, final run state would be recorded truthfully."
    verdict: PASS
    artifactRefs:
      - A08
      - A09
  - scenarioId: adv-repeated-interruptions
    criterionRef: "Adversarial: repeated interruptions (run id/comment preserved)"
    adversarialClass: repeated_interruptions
    expectedBehavior: "Every approval/watch/status command preserves run id 28600509667 and exact comment string."
    verdict: PASS
    artifactRefs:
      - A02
      - A03
      - A06
      - A08
      - A09
      - A12

artifactRefs:
  - id: A01
    kind: GitHub API raw response
    description: "Pre-approval pending deployments; environment vm-proof-manual id 17499459504, current_user_can_approve=true."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/01-pending-deployments-before.jsonlog"
  - id: A02
    kind: GitHub API request body
    description: "Approval body with environment_ids [17499459504], state approved, exact non-release comment."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/02-approval-request.json"
  - id: A03
    kind: GitHub API raw response
    description: "Approval POST response returning deployment 5286635009 for vm-proof-manual on branch work/protected-multi-row-vm-scheduler-proof at 8c451e0a5143f03f633edeaa8a13711ff0e5c3df."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/03-approval-response.jsonlog"
  - id: A04
    kind: GitHub API raw response
    description: "Post-approval pending deployments; empty list."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/04-pending-deployments-after.jsonlog"
  - id: A05
    kind: GitHub API raw response
    description: "Deployment statuses immediately after approval showing waiting/queued/in_progress transition."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/05-deployment-statuses-after.jsonlog"
  - id: A06
    kind: GitHub API raw response
    description: "Run approvals endpoint showing reviewer Meillaya, state approved, environment vm-proof-manual, and exact comment."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/06-run-approvals.jsonlog"
  - id: A07
    kind: GitHub CLI JSON
    description: "Run view before watch showing in_progress run on expected branch/SHA."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/07-run-view-before-watch.jsonlog"
  - id: A08
    kind: GitHub CLI transcript
    description: "Bounded gh run watch transcript; completed with exit_code=0."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/08-run-watch.txt"
  - id: A09
    kind: GitHub CLI JSON
    description: "Final required run view JSON showing completed/success."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/09-run-view-after-watch.jsonlog"
  - id: A10
    kind: GitHub CLI JSON
    description: "Job/step status after watch showing all steps success."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/10-run-jobs-after-watch.jsonlog"
  - id: A11
    kind: GitHub API raw response
    description: "Deployment statuses after watch showing final success state for vm-proof-manual deployment."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/11-deployment-statuses-after-watch.jsonlog"
  - id: A12
    kind: GitHub API raw response
    description: "Run approvals endpoint after watch preserving exact approval comment."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/12-run-approvals-after-watch.jsonlog"
  - id: A13
    kind: GitHub API raw response
    description: "Pending deployments after watch; empty list."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/13-pending-deployments-after-watch.jsonlog"
  - id: A14
    kind: GitHub API raw response
    description: "Remote branch head check proving branch head SHA matches final run head SHA."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/14-remote-branch-head.jsonlog"
  - id: A15
    kind: local artifact inspection
    description: "Privacy marker scan; no common token/authorization markers found in task-5 artifacts."
    path: ".omo/evidence/protected-core-vm-pass-execution/artifacts/task-5-review-watch/15-privacy-marker-scan.txt"
```

## DoneClaim

Todo 5 is complete for run `28600509667`: protected environment review evidence with exact comment was captured through GitHub API, the run was watched to completion, and final run status is `completed/success`. Todo 6 and Todo 7 were intentionally not performed.
