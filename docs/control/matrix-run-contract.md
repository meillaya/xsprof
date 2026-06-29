# Matrix-run/v1 evidence contract

`matrix-run/v1` is a backend-only standalone artifact manifest for VM harness matrix evidence. It is not a daemon-event and not a `daemon-event/v1` extension, not a frontend contract, not a simulator fixture, and not production or release approval.

The artifact schema string and JSON Schema `$id` are both `zig-scheduler/matrix-run/v1`.

## Required safety invariants

- `host_mutation` is always `false`; host rows may only prove refusal.
- `release_eligible` is always `false`; a matrix artifact is lab evidence only.
- Artifact paths are repository-relative data paths. Absolute paths and `..` traversal are invalid both in the standalone schema and in the checker. This applies to top-level artifact paths plus `policy.object_path`, `policy.source_path`, `workload.spec_path`, and `privacy_scan.report_path`.
- `rollback_proof_path`, `cleanup_proof_path`, and `host_refusal_proof_path` are required for every outcome, including `SKIP` and `REFUSE`.
- VM-live rows require a VM marker fact with `required=true`, `present=true`, and path `/run/zig-scheduler-vm-lab.marker`.
- Host-refusal-only rows use `evidence_mode=host-refusal-only` and keep `vm_marker.present=false` while still carrying host refusal proof.
- Stale or dirty git state is rejected by the contract (`git.status` must be `current`, `expected_sha` must match `actual_sha`, and `dirty=false`).
- Privacy scans must pass with `private_fields_found=false`; docs and fixtures are inert data and must not execute external text.
- The manifest and nested contract objects are closed shapes (`additionalProperties=false`); extra unexpected properties are invalid even if all required fields are present.

## Outcomes

| Outcome | Meaning |
| --- | --- |
| `PASS` | VM-live lab row has complete marker, runtime, rollback, cleanup, host-refusal, privacy, and non-release evidence. |
| `SKIP` | Prerequisite was unavailable or unsupported; rollback, cleanup, and host-refusal proof still exist. |
| `REFUSE` | Fail-closed refusal evidence, usually host-refusal-only, with no host mutation. |
| `INCIDENT` | Unsafe or incomplete lab state captured as incident evidence. |
| `FAIL` | Matrix execution failed, including rollback failure or cleanup residue evidence. |

## Required fields

The v1 manifest requires matrix run ID, scenario ID, outcome, kernel tuple, supported tuple status, VM marker facts, BPF ABI version, policy object/hash metadata, workload spec/hash, action ID, audit ID, rollback ID, pre/post scheduler state, pre/post cgroup state, runtime sample path, incident path, rollback proof path, cleanup proof path, host refusal proof path, privacy scan, git state, `release_eligible=false`, and `host_mutation=false`.

## Validation

Run:

```sh
python3 qa/matrix_run_contract_check.py --fixtures fixtures/matrix-run --schemas schemas/control --docs docs/control
```

The checker validates committed valid fixtures and confirms fixtures under `fixtures/matrix-run/invalid/` are rejected. The invalid fixtures cover malformed JSON, invalid outcome, stale and dirty git, missing VM marker on a VM-live row, absolute and traversing artifact paths, missing rollback proof, missing cleanup proof, missing cleanup proof on both `SKIP` and `REFUSE`, missing host refusal proof, privacy failure, extra unexpected properties, `host_mutation=true`, and `release_eligible=true`.
