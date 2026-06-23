# PROJECT KNOWLEDGE BASE

**Generated:** 2026-06-23T11:53:34-04:00
**Commit:** 302cead
**Branch:** master

## OVERVIEW
`zig-scheduler` root is a fail-closed Linux scheduler backend and VM-lab evidence surface written in Zig, Python, and shell. The root now owns host-safe preflight, daemon/control contracts, VM-only sched_ext proof paths, schema/fixture gates, and packaging/governance evidence; `simulator/` remains historical and has its own AGENTS hierarchy.

## CURRENT POSTURE
- Backend-first. No frontend/TUI/WebView/browser/desktop work exists in root; do not add it without explicit new scope.
- Host fail-closed. Root host paths may observe and plan, but must not mutate scheduler state, cgroups, cpusets, affinities, priorities, `/sys`, or `/proc`.
- Real sched_ext attach/load is VM-lab-only unless a later explicit approval changes scope. VM work requires marker, supported tuple, audit ID, rollback ID, pre/post state, rollback proof, cleanup proof, and host refusal evidence.
- No production/release claim. Lab evidence can prove readiness gates, not production readiness.
- Do not edit `simulator/` unless the user explicitly asks for simulator work.

## STRUCTURE
```text
./
├── build.zig                    # root build graph and verification steps
├── bpf/                         # sched_ext BPF source/header inputs, VM/lab artifact only
├── src/main.zig                 # fail-closed operator CLI and unsafe-verb refusals
├── src/preflight_main.zig       # read-only host preflight entrypoint
├── src/daemon_main.zig          # foreground daemon, replay, stdio JSONL, local UDS JSON-RPC
├── src/control/                 # operator actions, daemon events, journal, replay, VM lab dispatch
├── src/lab/                     # lab evidence, tuple, verifier helpers
├── src/observability/           # read-only host/runtime fact collection
├── src/sched_ext/               # sched_ext readiness and loader-boundary metadata
├── schemas/control/             # frozen v1 JSON schemas for backend/client contract
├── fixtures/                    # committed golden/control/frontend-contract/VM mutation fixtures
├── qa/                          # source, schema, evidence, governance, safety, and VM checks
├── tools/                       # daemon and BPF helper scripts
├── docs/                        # ADRs, runbooks, API contract, security/governance sources
├── evidence/                    # tracked curated evidence plus local generated lab outputs
└── simulator/                   # archived deterministic simulator package; separate guidance
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| CLI behavior and unsafe refusals | `src/main.zig`, `qa/unsafe_cli_matrix.sh` | Unsafe verbs must refuse non-zero on host. |
| Read-only host facts | `src/preflight_main.zig`, `src/observability/` | No mutation, no BPF load. |
| Daemon API and replay | `src/daemon_main.zig`, `src/control/`, `docs/control/` | `daemon-event/v1`, `operator-action/v1`, `runtime-sample/v1`. |
| Frontend integration boundary | `docs/control/frontend-api-pack.md`, `fixtures/frontend-contract/`, `qa/frontend_contract_pack_check.py` | Backend-only contract; no UI implementation. |
| VM-lab backend path | `qa/vm/`, `src/control/lab_runner*`, `docs/runbooks/vm-lab.md` | Disposable VM evidence only. |
| BPF ABI/artifact gates | `bpf/`, `tools/bpf_metadata.sh`, `qa/bpf_abi_freeze_check.py`, `docs/adr/0004-bpf-abi-strategy.md` | Object metadata or explicit SKIP, never host attach. |
| Evidence/release governance | `docs/releases/`, `docs/security/`, `fixtures/lab/governance-sources.json`, `qa/release_gate.sh` | Lab release gates are not production approval. |
| Zig 0.16 reference baseline | `docs/vendor/zig-0.16.0/`, `docs/zig-0.16-api-usage.md`, `qa/zig_docs_vendor_check.py` | Use before changing Zig APIs. |

## CODE MAP
| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `main` | fn | `src/main.zig` | Root CLI: preflight, dry-run, attach refusal. |
| `main` | fn | `src/daemon_main.zig` | Daemon entry; selects foreground stdio or local socket mode. |
| `runForeground` | fn | `src/daemon_main.zig` | Stdio JSONL, event replay, runtime replay, journal write. |
| `runSocket` | fn | `src/daemon_main.zig` | Local Unix-domain socket JSON-RPC contract surface. |
| `validateReplayEventRow` | fn | `src/daemon_main.zig` | Schema-safe daemon-event replay validation. |
| `ActionKind` / `EventKind` | enum | `src/control/protocol.zig` | Zig source of truth mirrored by `schemas/control/`. |
| `parseActionJson` | fn | `src/control/protocol.zig` | Boundary parser for untrusted operator action JSON. |
| `parseArgs` | fn | `src/control/daemon.zig` | Daemon arg validation, safe state/socket path checks. |
| `appendAction` | fn | `src/control/daemon_dispatch.zig` | Dispatches actions to refusals, VM lab, rollback, incident lanes. |
| `appendRuntimeFile` | fn | `src/control/stream.zig` | Privacy-filtered runtime-sample to daemon-event conversion. |
| `runMicrovmLive` | fn | `src/control/lab_runner.zig` | VM-live runner invocation and evidence capture. |
| `build` | fn | `build.zig` | Wires `test`, `daemon-stdio`, `daemon-socket-rpc`, `client-contract`, `bpf`, `vm-lab-backend`, `package`. |

## COMMANDS
```bash
zig build test --summary all
zig build daemon-stdio
zig build daemon-socket-rpc
zig build client-contract
zig build linux-preflight -- --json
zig build run -- --help
zig build bpf
zig build vm-lab-backend
bash qa/no_frontend_root.sh
bash qa/no_host_mutation.sh
python3 qa/control_schema_drift_check.py --protocol src/control/protocol.zig --schemas schemas/control
python3 qa/frontend_contract_pack_check.py --fixtures fixtures/frontend-contract --schemas schemas/control --docs docs/control
python3 qa/zig_docs_vendor_check.py --root docs/vendor/zig-0.16.0
zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print)
git diff --check
```

## CONVENTIONS
- Keep schemas, Zig protocol enums, fixtures, docs, and contract checks in lockstep.
- JSONL event streams are append-only evidence; every daemon event must keep `host_mutation=false`.
- Paths accepted by daemon/control APIs must be relative and safe; sockets must live under `--state-dir`.
- Runtime samples must not expose command lines, argv, environment, secrets, API keys, tokens, or passwords.
- Generated bulky VM output under `evidence/lab/` is often local evidence; commit only curated/reviewable artifacts deliberately.
- Use `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt` and `zig-0.16.0-stdlib-sources.txt` for Zig API checks.

## ANTI-PATTERNS
- Do not add root frontend/UI/TUI/WebView/browser/desktop code or build steps.
- Do not restore simulator UI or modify simulator history from root backend tasks.
- Do not make host `load`, `attach`, `enable`, `mutate`, or `apply` paths succeed.
- Do not treat VM-lab PASS as production approval or release eligibility without the governance gate.
- Do not weaken schema, golden transcript, host-mutation, no-frontend, or rollback checks to get green builds.

## NOTES
- Child guidance exists for `src/control/`, `qa/`, and `qa/vm/`; follow the deepest applicable file.
- Existing `simulator/AGENTS.md` and descendants govern simulator-only work.
- LSP may be unavailable in some Codex sessions; codegraph and executable checks are still authoritative for source/gate discovery.
