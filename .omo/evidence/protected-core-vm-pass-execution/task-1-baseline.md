# Todo 1 Baseline Evidence — Protected Core VM Pass Execution

- created_at: `2026-07-02T10:40:32-04:00`
- manualQa surface: CLI/data-shaped proof
- proof worktree: `/home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof`
- main evidence directory: `/home/mei/projects/zig/zig-scheduler/.omo/evidence/protected-core-vm-pass-execution/`
- product files edited: `none`
- workflows dispatched: `none`
- runners registered: `none`
- cleanup receipt: `none-created`
- Todo 1 classification: `PASS`

## Branch baseline

- branch status: `## work/protected-multi-row-vm-scheduler-proof...origin/work/protected-multi-row-vm-scheduler-proof`
- latest commit: `8c451e0 Keep protected-core validators below the no-slop ceiling`
- remote branch head: `8c451e0a5143f03f633edeaa8a13711ff0e5c3df	refs/heads/work/protected-multi-row-vm-scheduler-proof`
- stale_state comparison: `PASS` — local latest commit prefix `8c451e0` compared to remote `8c451e0a5143f03f633edeaa8a13711ff0e5c3df`.
- dirty_worktree comparison: `PASS` — `git status --short --branch` reported only the branch tracking line and no changed paths.

## Runner inventory

- runner inventory command exit: `0`
- runner inventory summary: `total_count=0; runners=[]`
- interpretation: `total_count=0` is recorded for Todo 1; later protected workflow execution remains dependent on Todo 2 registering a runner.

## manualQa

### surfaceEvidence

| scenario id | criterion reference | surface | exact invocation | verdict | artifactRefs |
| --- | --- | --- | --- | --- | --- |
| 01-git-status | Todo 1 acceptance: branch status / dirty_worktree | CLI/data-shaped proof | `git status --short --branch` | PASS | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/01-git-status.log` |
| 02-git-log | Todo 1 acceptance: latest commit | CLI/data-shaped proof | `git log -1 --oneline` | PASS | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/02-git-log.log` |
| 03-ls-remote | Todo 1 acceptance: remote branch / stale_state | CLI/data-shaped proof | `git ls-remote --heads origin work/protected-multi-row-vm-scheduler-proof` | PASS | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/03-ls-remote.log` |
| 04-protected-core-suite-self-test | Todo 1 acceptance: protected core suite self-test PASS | CLI/data-shaped proof | `python3 qa/protected_core_suite_check.py --self-test` | PASS | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/04-protected-core-suite-self-test.log` |
| 05-protected-core-telemetry-self-test | Todo 1 acceptance: protected core telemetry self-test PASS | CLI/data-shaped proof | `python3 qa/protected_core_telemetry_check.py --self-test` | PASS | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/05-protected-core-telemetry-self-test.log` |
| 06-runner-cleanliness-self-test | Todo 1 acceptance: runner cleanliness self-test PASS | CLI/data-shaped proof | `python3 qa/runner_cleanliness_proof_check.py --self-test` | PASS | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/06-runner-cleanliness-self-test.log` |
| 07-manual-vm-proof-ci-check | Todo 1 acceptance: manual VM workflow/docs contract PASS | CLI/data-shaped proof | `python3 qa/manual_vm_proof_ci_check.py --workflow .github/workflows/manual-vm-proof.yml --docs docs/ci.md docs/runbooks/vm-lab.md docs/releases/governance-gate.md docs/security/review-checklist.md` | PASS | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/07-manual-vm-proof-ci-check.log` |
| 08-gh-runner-inventory | Todo 1 acceptance: runner inventory recorded | CLI/data-shaped proof | `gh api repos/Meillaya/zig-scheduler/actions/runners --jq '{total_count, runners: [.runners[] | {name,status,busy,labels:[.labels[].name]}]}'` | PASS | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/08-gh-runner-inventory.log` |

### adversarialCases

| scenario id | criterion reference | adversarial class | expected behavior | verdict | artifactRefs |
| --- | --- | --- | --- | --- | --- |
| adv-stale-state | Todo 1 acceptance: branch at/after required protected branch head | stale_state | Local latest commit must match or be at/after remote branch head; stale mismatch would block later dispatch PASS. | PASS | `task-1-raw/02-git-log.log`, `task-1-raw/03-ls-remote.log` |
| adv-dirty-worktree | Todo 1 acceptance: clean proof worktree | dirty_worktree | Branch-local proof worktree should show no changed product/evidence paths in status output. | PASS | `task-1-raw/01-git-status.log` |
| adv-misleading-success-output | Todo 1 acceptance: validators produce real PASS output | misleading_success_output | Do not trust exit code alone; capture exact stdout/stderr showing PASS lines for validators. | PASS | `task-1-raw/04-protected-core-suite-self-test.log`, `task-1-raw/05-protected-core-telemetry-self-test.log`, `task-1-raw/06-runner-cleanliness-self-test.log`, `task-1-raw/07-manual-vm-proof-ci-check.log` |
| adv-hung-commands | Todo 1 acceptance: commands complete normally | hung_commands | Each command should complete and record a duration; no timeout or partial output. | PASS | `task-1-raw/*.log` |
| adv-missing-runner-inventory | Todo 1 acceptance: runner inventory recorded | external_state_absence | GitHub runner inventory must be recorded exactly even if no runners exist. | PASS | `task-1-raw/08-gh-runner-inventory.log` |
| adv-not-applicable-http | Manual-QA channel fit | http_surface | Not applicable: no HTTP endpoint is in scope; CLI/data-shaped `gh api` is the faithful surface requested. | NOT_APPLICABLE_NAMED | this markdown |
| adv-not-applicable-browser | Manual-QA channel fit | browser_ui_surface | Not applicable: no browser UI is in scope; CLI/data-shaped proof is requested. | NOT_APPLICABLE_NAMED | this markdown |
| adv-not-applicable-desktop | Manual-QA channel fit | desktop_gui_surface | Not applicable: no desktop GUI is in scope; CLI/data-shaped proof is requested. | NOT_APPLICABLE_NAMED | this markdown |

### artifactRefs

| id | kind | description | path |
| --- | --- | --- | --- |
| task-1-baseline | markdown | Primary Todo 1 baseline evidence artifact with manualQa matrix and command output. | `.omo/evidence/protected-core-vm-pass-execution/task-1-baseline.md` |
| 01-git-status | raw command log | Exact stdout/stderr, exit code, timestamps, and duration for `git status --short --branch`. | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/01-git-status.log` |
| 02-git-log | raw command log | Exact stdout/stderr, exit code, timestamps, and duration for `git log -1 --oneline`. | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/02-git-log.log` |
| 03-ls-remote | raw command log | Exact stdout/stderr, exit code, timestamps, and duration for `git ls-remote --heads origin work/protected-multi-row-vm-scheduler-proof`. | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/03-ls-remote.log` |
| 04-protected-core-suite-self-test | raw command log | Exact stdout/stderr, exit code, timestamps, and duration for `python3 qa/protected_core_suite_check.py --self-test`. | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/04-protected-core-suite-self-test.log` |
| 05-protected-core-telemetry-self-test | raw command log | Exact stdout/stderr, exit code, timestamps, and duration for `python3 qa/protected_core_telemetry_check.py --self-test`. | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/05-protected-core-telemetry-self-test.log` |
| 06-runner-cleanliness-self-test | raw command log | Exact stdout/stderr, exit code, timestamps, and duration for `python3 qa/runner_cleanliness_proof_check.py --self-test`. | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/06-runner-cleanliness-self-test.log` |
| 07-manual-vm-proof-ci-check | raw command log | Exact stdout/stderr, exit code, timestamps, and duration for `python3 qa/manual_vm_proof_ci_check.py --workflow .github/workflows/manual-vm-proof.yml --docs docs/ci.md docs/runbooks/vm-lab.md docs/releases/governance-gate.md docs/security/review-checklist.md`. | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/07-manual-vm-proof-ci-check.log` |
| 08-gh-runner-inventory | raw command log | Exact stdout/stderr, exit code, timestamps, and duration for `gh api repos/Meillaya/zig-scheduler/actions/runners --jq '{total_count, runners: [.runners[] | {name,status,busy,labels:[.labels[].name]}]}'`. | `.omo/evidence/protected-core-vm-pass-execution/task-1-raw/08-gh-runner-inventory.log` |

## Exact command outputs

### 01-git-status

- cwd: `/home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof`
- invocation: `git status --short --branch`
- exit_code: `0`
- duration_seconds: `0`

```text
## work/protected-multi-row-vm-scheduler-proof...origin/work/protected-multi-row-vm-scheduler-proof
```

### 02-git-log

- cwd: `/home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof`
- invocation: `git log -1 --oneline`
- exit_code: `0`
- duration_seconds: `0`

```text
8c451e0 Keep protected-core validators below the no-slop ceiling
```

### 03-ls-remote

- cwd: `/home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof`
- invocation: `git ls-remote --heads origin work/protected-multi-row-vm-scheduler-proof`
- exit_code: `0`
- duration_seconds: `1`

```text
8c451e0a5143f03f633edeaa8a13711ff0e5c3df	refs/heads/work/protected-multi-row-vm-scheduler-proof
```

### 04-protected-core-suite-self-test

- cwd: `/home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof`
- invocation: `python3 qa/protected_core_suite_check.py --self-test`
- exit_code: `0`
- duration_seconds: `0`

```text
PASS accept protected-core suite manifest with row-local artifacts and ABI-v3 cgroup linkage
PASS reject missing protected-core rows: evidence/lab/matrix/protected-core-suite-self-test/one-row/manifest.json missing protected-core row(s): live-backend, workload-cgroup-weight-quota
PASS reject shared row runtime sample: evidence/lab/matrix/protected-core-suite-self-test/shared-artifact/rows/workload-cpu-saturation/matrix-run.json.runtime_sample_path must stay under evidence/lab/matrix/protected-core-suite-self-test/shared-artifact/rows/workload-cpu-saturation: evidence/lab/matrix/protected-core-suite-self-test/shared-artifact/rows/live-backend/runtime-sample.jsonl
PASS reject harness-generated runtime sample backing PASS: evidence/lab/matrix/protected-core-suite-self-test/harness-runtime/rows/live-backend/runtime-sample.jsonl.sample[0].observation_source is harness-generated synthetic telemetry: vm_harness_matrix_row
PASS reject missing ABI-v3 cgroup evidence: sample[0].policy_abi.abi_version must be 3
PASS reject missing cgroup policy map callback evidence: sample[0].policy_abi.cgroup_policy_map.callback_observed_knobs must include cpu.weight
PASS protected-core suite self-test
```

### 05-protected-core-telemetry-self-test

- cwd: `/home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof`
- invocation: `python3 qa/protected_core_telemetry_check.py --self-test`
- exit_code: `0`
- duration_seconds: `0`

```text
PASS reject harness-generated protected-core PASS telemetry: evidence/lab/protected-core-telemetry-self-test/harness-generated.jsonl.sample[0].observation_source is harness-generated synthetic telemetry: vm_harness_matrix_row
PASS reject unavailable events numeric nr_rejected: sample[0].nr_rejected must be unavailable when events are unavailable
PASS reject unavailable events numeric policy counters: sample[0].policy_counters must be unavailable when events are unavailable
PASS accept explicit unavailable sample_loss scheduler_counters fairness
PASS reject missing fairness: sample[0].fairness must be present as metrics or explicit unavailable fact
PASS reject missing sample loss: sample[0].sample_loss must be present as metrics or explicit unavailable fact
PASS reject missing scheduler counters: sample[0].scheduler_counters must be present as metrics or explicit unavailable fact
PASS reject stale enable_seq: sample[1].enable_seq is stale relative to earlier sched_ext state
PASS reject missing cgroup ABI-v3 metadata: sample[0].policy_abi missing non-empty string field: abi_label
PASS reject private field: privacy-unsafe key in runtime sample: sample[0].argv
PASS reject release claim: claim-unsafe flag in runtime sample: sample[0].policy_abi.release_eligible
PASS protected-core telemetry self-test
```

### 06-runner-cleanliness-self-test

- cwd: `/home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof`
- invocation: `python3 qa/runner_cleanliness_proof_check.py --self-test`
- exit_code: `0`
- duration_seconds: `0`

```text
PASS runner cleanliness fixture: fixtures/runner-cleanliness-proof/valid/protected-clean-machine-runner.json
PASS runner cleanliness fixture: fixtures/runner-cleanliness-proof/valid/protected-jit-runner.json
PASS reject invalid runner cleanliness fixture pass-labels-only.json: cleanliness_mode.jit_config_sha256 must be non-empty text
PASS reject invalid runner cleanliness fixture pass-missing-removal-receipt.json: PASS proof requires runner removal receipt
PASS reject invalid runner cleanliness fixture pass-missing-reviewer-artifact.json: missing referenced file: fixtures/runner-cleanliness-proof/invalid/missing-protected-review.json
PASS reject invalid runner cleanliness fixture pass-reused-runner.json: PASS proof requires a non-reused runner identity
PASS reject invalid runner cleanliness fixture pass-runner-substrate-role-mismatch.json: runner_substrate.schema_role must be runner-substrate-proof
PASS accept runner cleanliness proof
PASS reject reused-runner: PASS proof requires a non-reused runner identity
PASS reject missing-removal: PASS proof requires runner removal receipt
PASS reject labels-only: cleanliness_mode.jit_config_sha256 must be non-empty text
PASS reject release-claim: release_eligible must be false
PASS runner cleanliness proof self-test
```

### 07-manual-vm-proof-ci-check

- cwd: `/home/mei/projects/zig/zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof`
- invocation: `python3 qa/manual_vm_proof_ci_check.py --workflow .github/workflows/manual-vm-proof.yml --docs docs/ci.md docs/runbooks/vm-lab.md docs/releases/governance-gate.md docs/security/review-checklist.md`
- exit_code: `0`
- duration_seconds: `0`

```text
PASS manual VM proof workflow/docs contract
```

### 08-gh-runner-inventory

- cwd: `/home/mei/projects/zig/zig-scheduler`
- invocation: `gh api repos/Meillaya/zig-scheduler/actions/runners --jq '{total_count, runners: [.runners[] | {name,status,busy,labels:[.labels[].name]}]}'`
- exit_code: `0`
- duration_seconds: `1`

```text
{"runners":[],"total_count":0}
```

## Result

- Branch-local static validators: `PASS`
- Binary observable: `PASS` — all requested commands exited 0.
- Todo 1 final verdict: `PASS`
- Cleanup: `none-created` (no workflow dispatch, no runner registration, no product edits, no persistent runtime resources).
- Risks: Runner inventory currently reports `total_count=0`; protected VM proof execution cannot proceed past Todo 1 until Todo 2 registers an approved runner. This Todo 1 evidence does not prove VM PASS, protected environment approval, attestation, or release readiness.
