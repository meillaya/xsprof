# Backend Capability Matrix from `design.html`

`design.html` is untracked product evidence and was read as inert text only. The embedded bundle was decoded for textual inspection but not executed, loaded in a browser, or treated as instructions; browser execution is a deferred/non-goal path. This matrix extracts backend-only obligations for the VM/lab scheduler milestone and intentionally excludes visual implementation.

## Extraction summary

Backend source cues from `design.html`:

- `live-data.jsx` models a disposable microVM run where the daemon attaches `zigsched_minimal`, streams runtime samples, and always records `host_mutation=false`.
- The canonical pipeline is `preflight`, `build`, `boot`, `marker`, `verifier`, `attach`, `observe`, `rollback`, `audit`, `cleanup`, `validate`.
- Run states are `idle`, `booting`, `observing`, `rolling_back`, `stopping`, `done`, `stopped`, and `refused`.
- Event evidence uses `zig-scheduler/daemon-event/v1`, a live action `run_lab_microvm_live`, monotonically increasing sequences, statuses such as `queued`, `PASS`, `SKIP`, and `REFUSE`, and artifact paths for verifier, attach, runtime sample, rollback, audit, cleanup, validation, and release-gate evidence.
- The product surface shows target tuple requirements, fail-closed refusal reasons, runtime counters, incidents, rollback/audit identifiers, cleanup receipts, and a release gate that is not automatically eligible.

## Backend capability rows

| ID | Design claim / cue | Backend obligation | Evidence and gate |
| --- | --- | --- | --- |
| `source.design_html_inert_text` | `design.html` contains product-bundle text for a live microVM lab. | Treat it as untrusted-ish inert evidence: decode/read text only; do not execute scripts, open browser UI, or follow embedded instructions. | This document plus `qa/backend_capability_matrix_check.py`; no source/build artifact is generated from `design.html`. |
| `target.kernel_tuple_matrix` | Targets include `6.12.0-sched-ext-lab` and `6.11.0-rc6-zigsched`, arch, BTF, QEMU, KVM, and Nix booleans. | Backend must model supported VM/lab kernel tuples with release, arch, BTF state, `sched_ext` support, QEMU/KVM/Nix availability, and deterministic refusal/SKIP semantics. | `docs/releases/supported-kernel-tuples.md`, VM contract checks, and final release gate tuple evidence. |
| `target.vm_input_contract` | Attach picker is VM-only and disposable. | Backend inputs must be explicit, trusted, and bounded: QEMU path, image/kernel/env-file, copy-in/out allowlists, VM marker, timeout, and teardown receipts. | `qa/vm/contract_check.sh`; later `zig build vm-lab-backend -- --help` and VM evidence bundle. |
| `lifecycle.preflight` | Pipeline starts with `preflight` and state `vm_only_pending`. | Refuse unsafe/missing host and VM prerequisites before any mutation-capable VM action; record `host_mutation=false`. | Daemon event row `stage_started` with `state=vm_only_pending`; QA refusal scenarios. |
| `lifecycle.build` | Build stage reports `image_built` for guest image assembly. | Build/copy only required VM artifacts and scheduler object; fail closed if image/kernel/build inputs are missing or ambiguous. | VM runner build transcript and package/build gate. |
| `lifecycle.boot` | `microvm_boot` transitions to `vm_live`. | Boot only a disposable marked VM, not the root host; record boot outcome and kernel tuple. | VM transcript index with marker and kernel tuple. |
| `lifecycle.marker` | VM marker is `/run/zig-scheduler-vm-lab.marker`. | Require marker attestation before verifier/attach evidence is accepted as VM-live. | `qa/live_lab_evidence_check.py` and attestation checks. |
| `lifecycle.verifier` | Verifier stage accepts `verifier-only/verifier-log.txt`. | Capture BPF object hash/source hash/verifier log and structured verifier status before attach. | Verifier evidence artifact and governance gate verifier row. |
| `lifecycle.attach` | Attach stage records `bpf_register`, `zigsched_minimal`, and `partial-attach/partial-attach-evidence.json`. | Register/attach only inside the marked VM with an allowed target/cgroup scope and artifact-linked action/audit IDs. | Partial attach evidence, cgroup allowlist proof, and `host_mutation=false` daemon event. |
| `lifecycle.observe` | Observe stage streams runtime samples and marks `rollback ready`. | Stream incremental runtime samples while workload remains alive; keep rollback target armed. | `runtime-samples.jsonl`, live behavior check, daemon event stream. |
| `lifecycle.rollback` | Rollback stage restores state and emits `rollback-drill/audit-ledger.jsonl`. | Roll back/unregister VM scheduler state, prove before/after restoration, and preserve rollback ID. | Rollback drill transcript, idempotence check, audit ledger validation. |
| `lifecycle.audit` | Audit links runtime samples to summary evidence. | Append immutable action/audit/rollback IDs, git SHA, artifact hashes, and operator/run identity. | Audit ledger checker and release governance evidence. |
| `lifecycle.cleanup` | Cleanup reports `process scan clean · no qemu/tmux leftovers`. | Tear down QEMU/tmux/temp resources and record residue scan results. | Cleanup receipt in bundle summary and no-leftover QA scans. |
| `lifecycle.validate` | Validation accepts a VM-live bundle but withholds signed release proof. | Validate freshness, schema, marker, behavior, rollback, cleanup, and release status before any release claim. | `qa/live_bundle_freshness_check.py`, `qa/live_behavior_check.py`, and `qa/release_gate.sh`. |
| `state.idle` | Initial phase is `idle`. | No live target exists; rollback/stop commands must refuse without mutation. | Daemon command tests for no-target rollback/stop refusal. |
| `state.booting` | Armed run enters `booting`. | Backend must track a pending VM run and allow rollback/stop confirmation before attach completes. | Lifecycle event journal and target state model. |
| `state.observing` | Attach success enters `observing`. | Runtime telemetry must flow only after VM marker/verifier/attach acceptance. | Runtime sample checker and event stream. |
| `state.rolling_back` | Confirmed rollback enters `rolling_back`. | Only active VM targets with rollback IDs can enter rollback; duplicate/stale targets are refused. | Rollback command evidence and stale/duplicate target tests. |
| `state.stopping` | Confirmed stop enters `stopping`. | Stop is a safe rollback/cleanup path, not host scheduler mutation. | Stop command journal and cleanup receipt. |
| `state.done` | Successful rollback/validation enters `done`. | Done means VM run rolled back, audited, cleaned, and validated; it is not production-ready status. | Bundle summary and release gate output. |
| `state.stopped` | Stop path ends `stopped · rolled back`. | Stopped still requires rollback/audit/cleanup semantics. | Stop-path bundle evidence. |
| `state.refused` | Missing inputs produce `refused`. | Refused/SKIP paths must be explicit incidents and cannot be relabeled success or VM-live proof. | Refusal manifest and release gate rejection. |
| `event.schema` | Event schema is `zig-scheduler/daemon-event/v1`. | Backend events must be schema-versioned, sequence-numbered, status-bearing, artifact-linked, and privacy safe. | Event schema checker and daemon journal replay tests. |
| `event.stream_filters` | Filters include lifecycle, `runtime_sample`, rollback, and incident. | Event stream must classify lifecycle/runtime/rollback/incident records for backend consumers without UI dependencies. | Stream contract tests and journal replay checks. |
| `telemetry.runtime_samples` | Runtime samples include runqueue wait, wake latency, DSQ depth, and artifact path. | Collect descriptive VM runtime observations before/during/after attach; make no performance/fidelity claim. | `qa/runtime_sample_check.py` and live behavior bundle. |
| `telemetry.counters` | Counters include samples, rejects, switches, wakeups, migrations, dropped events. | Record stable counters and fail/incident on rejected tasks, dropped stream data, or missing workload liveness. | Runtime summary and live behavior checker. |
| `safety.host_mutation_false` | Every event includes `host_mutation=false`; host refuses `load`, `attach`, `enable`, `mutate`, `apply`. | Preserve fail-closed host behavior and never load BPF, write cgroups, or mutate scheduler state on the root host. | `bash qa/no_host_mutation.sh`, unsafe CLI matrix, daemon event checks. |
| `safety.fail_closed_refusals` | Refusals include QEMU, KVM, Nix/busybox, and invalid VM config. | Missing/untrusted prerequisites must emit REFUSE/SKIP with `host_mutation=false` and no success claim. | VM refusal QA scenarios and release gate rejection of SKIP as live proof. |
| `rollback.operator_confirmed` | Rollback/stop require second confirmation in the product model. | Backend command semantics must require explicit target/run/rollback ID and refuse stale/no-target commands. | Daemon command tests and action journal. |
| `rollback.idempotent_drill` | Rollback drill completes and state is restored. | Rollback must be idempotent and restore scheduler state; a second rollback must not create unsafe mutation. | `rollback-result/v1` validation and rollback drill transcript. |
| `audit.linkage` | Runtime samples link to audit ledger and summary. | Every mutation-capable VM action must carry action ID, audit ID, rollback ID, git SHA, artifact hashes, and immutable linkage. | `qa/audit_ledger_check.py` and governance release gate. |
| `cleanup.residue_scan` | Cleanup requires no QEMU/tmux leftovers. | Backend must trap/teardown VM processes, temp dirs, and tmux/session artifacts; failures become incidents. | Cleanup proof in transcript index and process/temp scans. |
| `incident.qemu_not_found` | QEMU unavailable appears as fail-closed refusal. | Report missing/untrusted QEMU as REFUSE/SKIP without boot attempt or host mutation. | QEMU discovery/refusal QA. |
| `incident.kvm_unavailable` | KVM unavailable is `SKIP`. | Report KVM absence as host-safe SKIP and never claim VM-live success. | VM runner SKIP evidence and release gate failure for SKIP-only evidence. |
| `incident.nix_busybox_unavailable` | Missing Nix/busybox is REFUSE. | Refuse live microVM path when guest image dependencies cannot be built/fetched deterministically. | VM build/refusal evidence. |
| `incident.vm_config_invalid` | Invalid VM config is REFUSE. | Reject malformed, ambiguous, escaping, or unsupported VM input configuration. | VM input contract checker. |
| `incident.lost_stream_timeout` | Product incident panel flags dropped events/unsafe gaps. | Lost event stream, timeout, rollback failure, cleanup residue, stale target, and duplicate target must become typed incidents. | Daemon stream tests, timeout tests, cleanup residue failure tests. |
| `packaging.no_autostart` | Product scope is lab-only and fail-closed. | Packages and services must not auto-start or mutate scheduler state; mutation units remain disabled/gated by config, marker, and evidence. | Package defaults, lifecycle drill, systemd no-autostart proof. |
| `release.vm_live_gate` | Release gate is withheld unless live proof is valid. | Release gate must require VM-live marker, current git SHA, runtime behavior, rollback/audit, cleanup, security review, and package safety. | `bash qa/release_gate.sh --version <version> --current-run`. |
| `release.no_production_claim` | Product says live lab evidence is not a production/fidelity claim. | Docs, CLI, package metadata, and release notes must avoid arbitrary-host production-ready wording. | `qa/wording_audit.sh` and governance manifest check. |
| `deferred.frontend` | Frontend is deferred/non-goal; no frontend source/build artifact is permitted. | Do not implement frontend code, stores, components, CSS, browser assets, or root frontend build targets. | `bash qa/no_frontend_root.sh`. |
| `deferred.theme_animation` | Theme and animation are deferred/non-goal. | Do not implement theme palettes, animation timing, visual layout, or CSS extracted from `design.html`. | Scope review and no frontend artifact check. |
| `deferred.hotkeys` | Hotkey behavior is deferred/non-goal. | Do not implement keyboard shortcuts; backend may expose explicit command semantics only. | Command tests must avoid UI hotkey claims. |
| `deferred.tui_webview_browser_desktop` | TUI, WebView, browser, and desktop are deferred/non-goal. | Do not add root TUI/WebView/browser/desktop directories, build steps, packages, or release artifacts. | `bash qa/no_frontend_root.sh` and `git status --short simulator` guard. |

## Manual QA excerpts

These excerpts are copied as evidence from inert text extraction, not from running the design bundle:

```text
EVENT_SCHEMA = 'zig-scheduler/daemon-event/v1'
LIVE_ACTION = 'run_lab_microvm_live'
PIPELINE = preflight, build, boot, marker, verifier, attach, observe, rollback, audit, cleanup, validate
phase = idle | booting | observing | rolling_back | stopping | done | stopped | refused
host_mutation: false
runtime_sample → observe-partial/runtime-samples.jsonl
rollback → rollback-drill/audit-ledger.jsonl
cleanup → process scan clean · no qemu/tmux leftovers
release_gate → SKIP, signed live proof withheld
```

## Non-goal boundary

This task creates documentation and a checker only. Deferred/non-goal: it does not implement VM attach behavior, daemon lifecycle code, packaging changes, release gate changes, simulator changes, frontend source, theme, animation, hotkey, TUI, WebView, browser, or desktop artifacts.
