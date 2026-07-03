# Protected-core PASS evidence — 2026-07-03

This record captures the first fresh protected-core PASS evidence after the protected
multi-row VM scheduler proof branch repairs. It is lab evidence only: it is not a
release approval, not a production-capacity claim, not a performance claim, and
not permission to attach sched_ext on a real host.

## GitHub Actions run

- Workflow: `manual-vm-proof`
- Run: `28629448049`
- URL: <https://github.com/Meillaya/zig-scheduler/actions/runs/28629448049>
- Event: `workflow_dispatch`
- Head branch: `work/protected-multi-row-vm-scheduler-proof`
- Head commit: `f049142f4beed827a0a797c2272eaf2502c266d1`
- Status/conclusion: `completed` / `success`
- Created/updated: `2026-07-03T00:05:12Z` / `2026-07-03T00:08:18Z`

## Validator evidence

Fresh downloaded bundle validators passed from the protected-run artifact:

- `qa/matrix_run_contract_check.py`: PASS, 4 rows valid
- `qa/runner_substrate_proof_check.py`: PASS
- `qa/runner_cleanliness_proof_check.py`: PASS
- `qa/evidence_manifest_check.py`: PASS
- `qa/protected_core_suite_check.py`: PASS
- `qa/protected_core_telemetry_check.py`: PASS
- `gh attestation verify`: exit code `0`

## Protected-core rows

The evidence manifest outcome is `PASS` and every selected protected-core row is
`PASS`:

| Row | Outcome |
| --- | --- |
| `live-backend` | `PASS` |
| `workload-cpu-saturation` | `PASS` |
| `workload-cgroup-weight-quota` | `PASS` |
| `workload-interactive-latency` | `PASS` |

The selected latency row was `workload-interactive-latency`; the fallback
`workload-scheduler-affinity-churn` row was therefore not required for this run.

## Runner and substrate proof

- Runner class: protected self-hosted disposable VM proof runner.
- Required labels: `self-hosted`, `zig-scheduler-vm-proof`, `disposable-vm`.
- Ephemeral runner ID: `34`.
- Ephemeral registration receipt: `evidence/lab/manual-vm-proof/runner-ephemeral-registration-receipt.json`.
- Ephemeral registration SHA-256: `94cfdd45a3fcaebc4e2a941782deb515a147c69b4047f3eb4a56271febaf4e48`.
- Post-run matching runner query: `[]` (`matches=0`).
- Runner cleanliness outcome: `PASS`.
- Runner substrate outcome: `PASS`.
- Acceleration: `kvm`.
- Supported tuple: `linux-7.1.1-2-cachyos-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only`.
- BPF metadata SHA-256: `6390faf089e926abe15da2bc4307ab41d703bbd71067e9770711b549ef197200`.

## Safety flags

The bundle preserved the required safety facts:

- `host_mutation=false`
- `release_eligible=false`
- `production_capacity_claim=false`

## Frontend-readiness interpretation

This PASS completes the protected backend maturity evidence needed to begin
frontend implementation planning against the backend-only contract pack. It does
not remove the root project guard against accidental frontend code: actual UI work
must start from an explicit frontend scope, a `DESIGN.md` contract, and the
backend API surfaces documented under `docs/control/`.
