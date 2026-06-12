# sched_ext Security Threat Model

Status: required for any mutation-capable lab release. This repository remains path-to-production only and is not a production-ready arbitrary-host scheduler.

## Assets and trust boundaries
- Root privileges and Linux capabilities: CAP_BPF, CAP_SYS_ADMIN, and CAP_PERFMON must be treated as hazardous.
- BPF verifier assumptions: verifier acceptance is necessary but not sufficient for operational safety.
- Cgroup scope: mutation-capable paths are limited to `/sys/fs/cgroup/zig-scheduler-lab.slice/` in disposable VM/lab evidence.
- Audit ledger and rollback snapshots: records must be append-only, per-audit-id, and secret-free.
- Logs and TUI output: no private command lines, credentials, cookies, tokens, hostnames beyond lab tuple, or unbounded logs.
- Packaging defaults: install read-only operator defaults only; no auto-starting scheduler.

## Threats and mitigations
| Threat | Mitigation | Gate evidence |
| --- | --- | --- |
| Root privilege misuse | Host default refuses load/attach/enable/mutate/apply; no-host mutation QA | `qa/no_host_mutation.sh` |
| Capability overreach | Preflight reports CAP_BPF/CAP_SYS_ADMIN/CAP_PERFMON; mutation remains VM-gated | preflight evidence |
| Config injection | Strict parser, unknown-field rejection, argv execution, no shell concatenation | config tests |
| Cgroup escape | Allowlist canonical lab subtree and stale-scope refusal | cgroup race evidence |
| Audit tampering | Append-only ledger, duplicate audit id refusal, per-audit immutable snapshots | rollback drill evidence |
| BPF verifier drift | Verifier-only VM/refusal artifacts and static BPF checks | verifier evidence |
| Log privacy leak | Structured evidence omits secrets and private command lines | observer/privacy tests |
| Unsafe packaging | Services disabled/read-only by default | package defaults QA |
| Premature production claim | Wording and release governance gates | wording audit |

## Mandatory mutation-release review
A mutation-capable release profile must include a signed JSON review artifact with:
- `schema`: `zig-scheduler/security-review/v1`
- `profile`: `mutation-capable-lab`
- `status`: `approved`
- `reviewer`: non-empty owner/operator identity
- `threat_model_version`: `2026-06-11`
- `checklist`: all required topics marked true
- `signed_attestation`: object with `kind`, `signed_by`, `signed_at`, and `statement` fields

Read-only profiles pass if this threat model and checklist exist and wording/no-host gates pass.

## TUI-driven control-plane threat notes

The TUI-driven workflow introduces an operator action queue and daemon stdin boundary. The safety model is:

- the TUI emits typed `operator-action/v1` JSON only;
- the daemon maps actions to fixed argv entries, not shell-concatenated commands;
- hazardous actions on ordinary hosts refuse with `host_mutation=false`;
- incident and rollback paths preserve audit ids, rollback ids, event journals, and cleanup receipts;
- transcripts are verification artifacts and must not contain secrets, credentials, private command lines, or unbounded host data.

Security review for any future mutation-capable profile must include the TUI key map, daemon action parser, command registry, runtime stream privacy filters, rollback ledger validation, and packaging no-auto-start behavior.
