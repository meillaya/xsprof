# F3 Real QA — protected-core-vm-pass-execution

QA verdict: **approved for truthful NON-PASS/SKIP final evidence**.

Scope: read-only final QA against latest final bundle artifacts for GitHub Actions run `28606271556`, except writing this report and QA rerun logs under `.omo/evidence/protected-core-vm-pass-execution/`. I did not edit product code, frontend, or simulator files.

Important interpretation: this is **not** approval of a protected-core PASS claim. It approves the final bundle/reporting posture because the protected-core PASS validators still fail or SKIP as expected, while attestation and live behavior/freshness proof validators pass.

## Summary findings

- `protected_core_suite`: **confirmed FAIL / NON-PASS**. Rerun exits `1` because `workload-cgroup-weight-quota` is not PASS for protected-core PASS proof.
- `protected_core_telemetry`: **confirmed FAIL / NON-PASS**. Rerun exits `1` because `sample[0].policy_counters` is not unavailable when events are unavailable.
- Final manifest row outcomes: **one PASS + three REFUSE**, matching NON-PASS protected-core posture:
  - `live-backend`: `PASS`
  - `workload-cpu-saturation`: `REFUSE`
  - `workload-cgroup-weight-quota`: `REFUSE`
  - `workload-scheduler-affinity-churn`: `REFUSE`
- Attestation: **PASS**. `gh attestation verify ... --repo Meillaya/zig-scheduler --format json` exits `0` and identifies subject digest `db134e36debb5d5d4a14ffdc4ed063cb4b5123aef0454bc7efc80235d91e10f7` for `vm-proof-bundle.tar.zst` from source commit `b6de9857b9ad327efadd4bf25a0d86383cff1f0b`.
- Live behavior: **PASS** for all four rows.
- Live freshness: **PASS** for all four rows using source git context and the final extracted bundle.
- Cleanup runner inventory: **absent as expected**. Runner cleanliness proof has `proof_outcome=SKIP`, `removal_receipt.status=unavailable`, `no_reuse_evidence.status=REFUSE`, and no inventory key/file/grep hit.
- Bundle checksum: **PASS** after using the `.omo` checksum file. An initial stale invocation against `artifacts/task-8-final-qemu-rerun/vm-proof-bundle.sha256` failed because that checksum file is present only in the `.omo` evidence mirror; the corrected checksum verification exits `0`.

## manualQa

### surfaceEvidence

| scenario id | criterion reference | surface | exact invocation | verdict | artifactRefs |
|---|---|---|---|---|---|
| F3-SE-001 | F3-C1 latest final run metadata is run `28606271556` and completed successfully | filesystem JSON artifact inspection | `python3 - <<'PY' ... json.load('.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/run-view-final.json') ... PY` | PASS | A1, A2 |
| F3-SE-002 | F3-C2 final manifest remains NON-PASS: one PASS row and three REFUSE rows | filesystem TSV/JSON artifact inspection | `cat .omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/manifest-row-outcomes.tsv` | PASS | A3, A4 |
| F3-SE-003 | F3-C3 protected_core_suite must fail, not pass | CLI validator rerun | `(cd artifacts/task-8-final-qemu-rerun/extracted && python3 ../zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof/qa/protected_core_suite_check.py --manifest evidence/lab/matrix/manual-vm-proof/manifest.json)` | PASS: expected fail observed, exit `1` | A5 |
| F3-SE-004 | F3-C4 protected_core_telemetry must fail, not pass | CLI validator rerun | `(cd artifacts/task-8-final-qemu-rerun/extracted && python3 ../zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof/qa/protected_core_telemetry_check.py --manifest evidence/lab/matrix/manual-vm-proof/manifest.json)` | PASS: expected fail observed, exit `1` | A6 |
| F3-SE-005 | F3-C5 attestation must pass for final bundle | CLI attestation verification | `(cd /home/mei/projects/zig/zig-scheduler && gh attestation verify /home/mei/projects/zig/zig-scheduler/artifacts/task-8-final-qemu-rerun/download/vm-proof-bundle.tar.zst --repo Meillaya/zig-scheduler --format json)` | PASS: exit `0` | A7, A8 |
| F3-SE-006 | F3-C6 live behavior validators must pass | CLI validator rerun | For each row: `(cd artifacts/task-8-final-qemu-rerun/extracted && python3 ../zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof/qa/live_behavior_check.py --bundle evidence/lab/matrix/manual-vm-proof/rows/<row>/backend/live/summary.json)` | PASS: all four exit `0` | A9, A10, A11, A12 |
| F3-SE-007 | F3-C7 live freshness validators must pass | CLI validator rerun with source git context | For each row: `(cd artifacts/task-8-final-qemu-rerun/extracted && GIT_DIR=/home/mei/projects/zig/zig-scheduler/.git/worktrees/protected-multi-row-vm-scheduler-proof GIT_WORK_TREE=/home/mei/projects/zig/zig-scheduler/../zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof python3 ../zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof/qa/live_bundle_freshness_check.py --bundle evidence/lab/matrix/manual-vm-proof/rows/<row>/backend/live/summary.json)` | PASS: all four exit `0` | A13, A14, A15, A16 |
| F3-SE-008 | F3-C8 corrected matrix contract proof validates final extracted manifest | CLI validator rerun | `(cd artifacts/task-8-final-qemu-rerun/extracted && python3 ../zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof/qa/matrix_run_contract_check.py --manifest evidence/lab/matrix/manual-vm-proof/manifest.json --schemas ../zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof/schemas/control --docs ../zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof/docs/control)` | PASS: exit `0`, valid=4 | A17 |
| F3-SE-009 | F3-C9 final bundle checksum matches recorded digest | CLI checksum verification | `(cd /home/mei/projects/zig/zig-scheduler && sha256sum -c .omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/vm-proof-bundle.sha256)` | PASS: exit `0` | A18 |
| F3-SE-010 | F3-C10 runner cleanliness validator passes while proof outcome remains SKIP | CLI validator rerun | `(cd artifacts/task-8-final-qemu-rerun/extracted && python3 ../zig-scheduler-worktrees/protected-multi-row-vm-scheduler-proof/qa/runner_cleanliness_proof_check.py --proof evidence/lab/manual-vm-proof/runner-cleanliness-proof.json)` | PASS: validator exit `0`; proof content remains SKIP | A19, A20 |

### adversarialCases

| scenario id | criterion reference | adversarial class | expected behavior | verdict | artifactRefs |
|---|---|---|---|---|---|
| F3-ADV-001 | F3-A1 prevent false protected-core PASS promotion | A final bundle with REFUSE rows is fed to `protected_core_suite_check.py` | Validator must fail non-zero and name the non-PASS row | PASS: exit `1`, names `workload-cgroup-weight-quota` | A5 |
| F3-ADV-002 | F3-A2 prevent telemetry from passing with unavailable events mismatch | Final manifest telemetry is fed to `protected_core_telemetry_check.py` | Validator must fail non-zero and report policy counter/event mismatch | PASS: exit `1`, reports `sample[0].policy_counters` mismatch | A6 |
| F3-ADV-003 | F3-A3 prevent skipped cleanup proof from being treated as reusable-runner inventory proof | Runner cleanliness proof and extracted bundle are searched for inventory evidence | No cleanup runner inventory artifact/key should be present; proof should remain SKIP/REFUSE where no-reuse evidence is missing | PASS: no inventory filename/grep hits; `proof_outcome=SKIP`, `removal_receipt.status=unavailable`, `no_reuse_evidence.status=REFUSE` | A20 |
| F3-ADV-004 | F3-A4 prevent stale/mismatched bundle substitution | Verify downloaded tarball against recorded final digest | Checksum must match final digest | PASS: corrected checksum verification exits `0` | A18 |
| F3-ADV-005 | F3-A5 prevent accepting behavior-only proof without freshness | Run live behavior and live freshness validators separately for every row | Both behavior and freshness validators must pass for each row | PASS: all eight row validators exit `0` | A9, A10, A11, A12, A13, A14, A15, A16 |
| F3-ADV-006 | F3-A6 prevent accepting unsigned/unattested final bundle | Verify final tarball attestation through GitHub CLI | Attestation verify must exit `0` and bind bundle digest to run/source commit | PASS: exit `0`; digest/source/run evidence present | A7, A8 |

### artifactRefs

| id | kind | description | path |
|---|---|---|---|
| A1 | JSON | Final GitHub run view for run `28606271556` | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/run-view-final.json` |
| A2 | JSON | Artifact summary with head SHA, protected review status, row outcomes, static logs | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/artifact-summary.json` |
| A3 | TSV | Final manifest row outcomes extracted from bundle | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/manifest-row-outcomes.tsv` |
| A4 | JSON | Full validator summary from prior final validation/rerun bundle review | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/validator-summary.json` |
| A5 | log | F3 rerun of protected core suite validator; expected failure | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/protected_core_suite.log` |
| A6 | log | F3 rerun of protected core telemetry validator; expected failure | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/protected_core_telemetry.log` |
| A7 | log | F3 rerun of GitHub attestation verification | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/gh_attestation.log` |
| A8 | JSON | Existing concise attestation summary | `.omo/evidence/protected-core-vm-pass-execution/artifacts/task-8-final-qemu-rerun/validators/gh-attestation-summary.json` |
| A9 | log | F3 live behavior rerun: live-backend | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/live_behavior_live-backend.log` |
| A10 | log | F3 live behavior rerun: workload-cpu-saturation | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/live_behavior_workload-cpu-saturation.log` |
| A11 | log | F3 live behavior rerun: workload-cgroup-weight-quota | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/live_behavior_workload-cgroup-weight-quota.log` |
| A12 | log | F3 live behavior rerun: workload-scheduler-affinity-churn | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/live_behavior_workload-scheduler-affinity-churn.log` |
| A13 | log | F3 live freshness rerun: live-backend | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/live_freshness_live-backend.log` |
| A14 | log | F3 live freshness rerun: workload-cpu-saturation | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/live_freshness_workload-cpu-saturation.log` |
| A15 | log | F3 live freshness rerun: workload-cgroup-weight-quota | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/live_freshness_workload-cgroup-weight-quota.log` |
| A16 | log | F3 live freshness rerun: workload-scheduler-affinity-churn | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/live_freshness_workload-scheduler-affinity-churn.log` |
| A17 | log | F3 corrected matrix contract validator rerun | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/matrix_contract_corrected.log` |
| A18 | log | F3 corrected final bundle checksum verification | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/sha256_bundle_corrected.log` |
| A19 | log | F3 runner cleanliness validator rerun | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/runner_cleanliness.log` |
| A20 | log | F3 cleanup runner inventory absence inspection | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/cleanup_runner_inventory_absence.log` |
| A21 | TSV | F3 validator rerun exit-code matrix | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/validator-rerun-results.tsv` |
| A22 | JSON | F3 validator rerun summarized tails | `.omo/evidence/protected-core-vm-pass-execution/f3-real-qa-artifacts/validator-rerun-summary.json` |

## Notes and risks

- The bundle still contains a runner cleanliness proof that validates structurally but has `proof_outcome=SKIP`; that is acceptable only as truthful NON-PASS/SKIP evidence, not as cleanup/no-reuse proof.
- The `.omo` evidence mirror is smaller than the working `artifacts/task-8-final-qemu-rerun/` directory; reruns used the working extracted/downloaded bundle plus `.omo` checksum and summaries. The requested report and F3 logs are under `.omo/evidence/protected-core-vm-pass-execution/`.
- No skipped, inferred, partial, or not_applicable adversarial case is counted as passing in this report.
