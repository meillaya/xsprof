# sched_ext Governance Gate

This governance gate defines the evidence required before `zig-scheduler` may move beyond path-to-production language. The current VM/lab backend milestone can only claim disposable-VM backend readiness; it does not claim arbitrary-host readiness.

## Required status before any production claim
The release status remains `path-to-production` until all checks below pass. A successful gate may at most authorize `controlled_lab_pilot_candidate` unless a future owner explicitly approves broader scope.

## Required evidence bundle
A candidate release must provide:

1. Kernel tuple manifest for every supported lab target.
2. BPF verifier log for the scheduler object.
3. VM-only partial-switch attach transcript.
4. Cgroup allowlist proof showing no root/system cgroup attach.
5. Rollback snapshot and rollback drill transcript.
6. Audit ID, operator identity, git SHA, and rollback ID for every mutation-capable run.
7. Stress/chaos evidence for workload liveness and fallback behavior.
8. VM-live scheduler behavior bundle validated by `qa/live_behavior_check.py`, proving the result is not attach-only success.
9. Security threat model and completed security review checklist.
10. Cleanup proof showing no QEMU, tmux, or VM-live temporary-resource residue from the release run.
11. Packaging/default-service proof that install does not auto-start or mutate scheduler state.
12. Scope proof that root frontend/UI artifacts are absent and `simulator/` is unchanged.
13. Wording audit proving no unguarded production-ready or arbitrary-production-host claim.
14. Matrix harness manifest evidence accepted by `qa/matrix_run_contract_check.py`, with `release_eligible=false`, `host_mutation=false`, rollback proof, cleanup proof, host-refusal proof, privacy proof, and safe relative artifact paths.

## Production evidence matrix
The current release summary must keep `release_status=controlled_lab_pilot_candidate`,
`production_ready=false`, and `arbitrary_host_safe=false`. Any future status change beyond the controlled lab pilot requires every row below
to be complete, current for the release git SHA, reproducible, and reviewed.

| Evidence category | Required proof before any future production-ready status |
| --- | --- |
| Kernel tuple matrix | Supported kernel tuple matrix with architecture, kernel release, config hash, BTF state, sched_ext state, and repeat count. |
| Verifier logs | BPF object hash, source hash, verifier log, parsed verifier status, and structured failure reasons for every tuple. |
| VM attach evidence | VM-only partial-switch attach transcript proving the root host path did not load or attach. |
| Rollback drills | Reproducible rollback drill transcript, before/after scheduler state, rollback ID, and fallback success. |
| Stress/chaos | Stress/chaos evidence for workload liveness, fallback behavior, no starvation threshold breach, and no repeated reject counters. |
| Audit ledger | Append-only audit ledger validation with unique audit IDs, immutable artifact hashes, and duplicate-replay rejection. |
| Security signoff | Signed security signoff against the tracked threat model and security review checklist. |
| Package install safety | Package install safety drill in a staging root or disposable VM proving no host mutation and no service enablement. |
| Package upgrade safety | Package upgrade safety drill proving config preservation, evidence archive preservation, and rollback of staged files. |
| Package uninstall safety | Package uninstall safety drill proving non-config files are removed while audit/evidence archives are retained. |
| Incident runbook | Incident runbook drill for verifier failure, fallback, rollback, and operator escalation. |
| Privacy review | Privacy review proving runtime samples exclude raw command lines, environments, secrets, and PII. |
| Matrix manifest | `matrix-run/v1` manifest rows proving every scenario outcome keeps `host_mutation=false`, `release_eligible=false`, rollback proof, cleanup proof, host-refusal proof, privacy proof, and safe relative artifact paths. `SKIP` and `REFUSE` rows remain non-approval evidence. |
| systemd no auto-start | systemd no auto-start proof for installed units; mutation service remains gated by config, marker, and evidence. |
| Cleanup proof | Release-run summary with QEMU/tmux residue checks, VM-live temp-dir cleanup receipt, and no stale current-run evidence reuse. |
| Scope fidelity | `qa/no_frontend_root.sh`, clean `git status --short simulator`, and release artifacts with no frontend or simulator payloads. |

## Pass/fail rule
The gate fails if any required evidence is stale, unverifiable, contradictory, or collected outside a disposable VM/lab environment. If VM-live behavior proof is missing, the gate must write a `SKIP` summary and must not create a controlled-lab approval; current-run release verification also exits non-zero so missing VM-live evidence cannot be mistaken for a passing release. The gate also fails if the root host path can load, attach, enable, mutate, apply, write cgroups, change affinities, change priorities, or call scheduler/BPF mutation APIs without the lab evidence bundle.

A controlled-lab candidate requires a VM-live behavior bundle accepted by `qa/live_behavior_check.py` and freshness-validated by `qa/live_bundle_freshness_check.py` against the current git SHA and BPF object before approval. The bundle must include marker-attested VM evidence, partial-switch `zigsched_minimal` metadata, runtime samples before/during/after attach, stable fatal/reject/fallback counters, daemon runtime events with `host_mutation=false`, live workload evidence, rollback-restored state, audit ledger validation, and cleanup proof. Host-safe or surrogate CI evidence may keep non-approval dry runs green only as `SKIP`; it must not be relabeled as live proof. Matrix harness manifests consumed by the release gate remain withheld unless a future explicit approval supplies full VM-live evidence; `release_eligible=true` in any matrix row or manifest is rejected.

For final T27/T28 same-run verification, use `qa/release_gate.sh --version <version> --current-run` so the gate writes ignored evidence under `evidence/releases/<version>-runall/current` by default. Current-run evidence must be ignored, untracked, and uncommitted; the gate refuses tracked or non-ignored current-run destinations. Tracked `evidence/releases/<version>/` files are curated historical release snapshots only and must not be rewritten merely to satisfy live-bundle freshness.

## Approval record
The owner/operator records approval in `.omo/evidence/release-approval-<version>.json` or the release evidence bundle. Approval must include the release version, git SHA, audit ID, reviewer, date, and exact authorized status.

## Non-release VM-lab evidence milestone

The VM-lab evidence scheduler safety milestone is a backend proof milestone, not a release approval. A passing milestone bundle may demonstrate schema drift checks, BPF ABI freeze checks, disposable VM marker proof, VM-only attach/register/unregister, mutation-family evidence, rollback, cleanup, and record-only calibration. It must still keep release approval withheld and must not claim to be production-ready, safe for production, or safe for arbitrary production hosts.

The milestone is rejected if any mutation family lacks host refusal proof, VM marker proof, allowlisted target, audit ID, rollback ID, pre-state, post-state, rollback proof, cleanup proof, or `host_mutation=false`. Frontend/root UI artifacts, simulator changes, real-host attach support, signing, publishing, and release-approval artifacts are out of scope and must not be introduced as part of the milestone.

## Manual VM proof provenance lane is release-withheld

The `manual-vm-proof` workflow is a protected `workflow_dispatch` evidence lane for disposable VM proof review. It may produce `vm-proof-bundle.tar.zst` as a GitHub Actions uploaded artifact with attestation, but that artifact is not a release asset, not OCI, not production approval, and not a substitute for the release gate. The bundle and its matrix rows must keep `release_eligible=false`, `host_mutation=false`, and `production_capacity_claim=false`.

Before a manual VM proof run is trusted as evidence, repository owners must configure the `vm-proof-manual` protected environment with required reviewers, branch/tag restrictions, and a dedicated self-hosted `zig-scheduler-vm-proof` / `disposable-vm` runner. The proof bundle must preserve audit id, rollback id, VM marker, supported tuple, pre state, post state, rollback proof, cleanup proof, host refusal, matrix manifest, matrix rows, BPF metadata, BPF SKIP JSON, daemon events, live summary if present, static verification logs, and benchmark provenance. Verification should include `gh attestation verify` plus the repository static checker; it must not fabricate reviewer approval in local agent runs.

Protected manual VM proof provenance additionally requires `evidence-manifest.json` to pass `qa/evidence_manifest_check.py` with `schemas/control/evidence-manifest.v1.schema.json`. The manifest is a hash index, not a release approval: it records an explicit `outcome` derived from matrix rows and protected runner substrate proof, plus SHA-256 hashes, schema roles, audit id, rollback id, VM marker, supported tuple, BPF metadata or SKIP JSON, daemon events, matrix manifest, benchmark provenance when applicable, rollback proof, cleanup proof, host refusal proof, privacy scan, and attestation status while preserving `host_mutation=false`, `release_eligible=false`, and `production_capacity_claim=false`. PASS manifests must include VM-marker proof and benchmark artifact references; SKIP/REFUSE/BLOCKED manifests may explicitly mark benchmark provenance not applicable when the guarded proof stopped before benchmark artifacts existed.

The host-safe governance lane must also run `qa/governance_manifest_check.py --manifest fixtures/lab/governance-sources.json` and `--self-test` so protected-runner, runtime-sample, benchmark provenance, schema compatibility, frontend/consumer contract, and matrix validators cannot drift silently. These checks are static/fixture-only and must not require QEMU, `/dev/kvm`, live VM marker access, or any host scheduler mutation.
