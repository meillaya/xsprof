# Security threat model

Root `zig-scheduler` is fail-closed and path-to-production only. It must not present host mutation, production scheduler readiness, or Linux performance claims without later governance approval and evidence.

## Assets and trust boundaries

- Host scheduler state: sched_ext state, BPF verifier/load paths, cgroups/cpusets, affinities, priorities, and scheduler state are protected host assets.
- Disposable VM evidence: VM marker, kernel tuple, verifier logs, runtime samples, rollback ledgers, and cleanup receipts are lab evidence only.
- Release scope evidence: no frontend/root UI artifacts, unchanged `simulator/`, package manifest fields, and current-run cleanup receipts are part of the VM/lab backend trust boundary.
- Toolchain provenance: QEMU/KVM, `nix`-backed busybox fetches, and `bpftool`/`libbpf` are explicit host dependencies for the live VM flow; missing pieces must skip or refuse instead of masquerading as success.
- Root privileges and Linux capabilities: CAP_BPF, CAP_SYS_ADMIN, and CAP_PERFMON are mutation-capable lab concerns only; package defaults and host-side orchestration must not grant or require them outside the disposable VM marker/evidence gates.
- Logs and transcripts: no private command lines, credentials, cookies, tokens, hostnames beyond the lab tuple, or unbounded logs.

## Host-safe invariants

Default root commands must remain safe for a developer laptop or ordinary CI runner:

- no BPF load or attach;
- no sched_ext host attach;
- no cgroup/cpuset writes;
- no affinity/priority changes;
- no scheduler-state mutation;
- no auto-started services from package install;
- `host_mutation=false` for host-side lab orchestration.
- no package or release gate may treat fixture, host-safe, root UI, or simulator evidence as VM-live backend proof.

Unsafe verbs (`load`, `attach`, `enable`, `mutate`, `apply`) must refuse with a non-zero exit and a clear safety explanation.

## Daemon/control-plane threat notes

The disabled-safe daemon accepts typed operator action JSON and routes only through the trusted command registry. The safety model is:

- JSON fields are data, not shell;
- action ids, run ids, audit ids, rollback ids, and state directories are validated before use;
- fixed argv is used for trusted lab scripts;
- malformed, stale, duplicate, or unknown targets refuse visibly;
- output is redacted and bounded before it becomes evidence.

Security review for any future mutation-capable profile must include the daemon action parser, command registry, runtime stream privacy filters, rollback ledger validation, and packaging no-auto-start behavior.

The mutation-capable lab profile specifically reviews config injection, cgroup escape, audit tampering, BPF verifier assumptions, Log privacy, and Packaging defaults before any controlled-lab candidate can be promoted.

## Packaging threat notes

Packages install inert defaults. Services must not be enabled by installation or upgrade. Mutation-capable services must remain gated by VM marker, config marker, audit id, rollback id, approval evidence, and release gate proof. Package manifests must state VM/lab backend scope, `production_ready=false`, `arbitrary_host_safe=false`, and no frontend/simulator payloads.
