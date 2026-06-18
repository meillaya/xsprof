## Prometheus Strict Plan

### Target Result
- Convert `zig build tui-live-vm` from a launch-then-render status screen into a live VM-lab operator console that starts the daemon/run, streams daemon frames/events while active, updates panes from an in-memory lifecycle model, accepts live controls, visibly refuses stale/duplicate unsafe actions, models incidents first-class, and remains VM-lab-only, fail-closed, and non-production.

Current concrete entrypoint remains:

```bash
zig build tui-live-vm
```

Do **not** repoint root `zig build run` in this work. Treat the live VM console as the final design direction for future run-path UX only after a separate explicit scope decision.

### Evidence Summary
- `src/tui/main.zig` currently renders a queued frame for `m`, then blocks inside `dispatchStatus`; input cannot be consumed until daemon completion.
- `src/tui/daemon_adapter.zig` uses daemon `--follow`, but `src/tui/daemon_process.zig` accumulates raw output until EOF/timeout.
- `src/tui/daemon_model.zig` derives a posthoc model from full raw daemon output.
- `src/tui/interaction.zig` currently requires `b`/`b` and `s`/`s`; duplicate live arm is only locally refused.
- `src/tui/screens.zig` has VM lanes/event/counter sections but no event cursor/scrub store.
- `qa/tui_live_lab_e2e.sh` and `tools/tui_live_vm_pty_test.py` capture transcripts but mostly assert final-state text.
- `qa/tui_live_lab_failure_matrix.sh` already has fixture hooks for QEMU/KVM, verifier, lost stream, malformed stream, timeout, duplicate/stale IDs, and cleanup scan classes.
- `authoritative-final-design.html` is an untracked local visual reference for dense live microVM lab styling; use it only as density/layout inspiration, not as source to copy.

### Clarified Requirements (Metis)
- Objective: live async operator console for the VM-lab TUI.
- Scope in: TUI event loop, daemon streaming, live store, active controls, renderer density, PTY/e2e/failure proof, docs safety wording.
- Scope out: host scheduler/cgroup/cpuset/affinity/BPF mutation, production-readiness claims, root `zig build run` repointing, copying HTML source, broad redesign without deterministic snapshots.
- Acceptance: ordered intermediate transcript frames, active `s`/`b` behavior, visible duplicate/stale refusals, first-class incidents, owned process cleanup proof, existing safety gates preserved.
- Test strategy: regression-first and fixture-backed before live integration.
- Handoff: single-owner `$ultragoal` first; `$team` only after interfaces stabilize.
- Questions emitted: zero. Checklist cleared by prompt/repo evidence plus conservative assumptions.

### Critique Resolved (Momus)
| Objection | Resolution |
| --- | --- |
| Acceptance too vague | Add exact transcript markers, ordering, timeout bounds, refusal text, exit-status contracts, and matrix rows. |
| LiveRunStore undefined | Define LiveRunStore v1 schema, phase enum, action lifetime, cursor, dedupe, redaction, dropped-event, and incident invariants before implementation. |
| Process ownership unsafe | Require owned PGID/session, signals only to owned PGID, bounded escalation, and tests proving unrelated processes survive. |
| Active `s`/`b` semantics unclear | Define active-target contract with run ID, target ID, stop/rollback IDs, readiness phase, idempotency, duplicate/stale refusal, and audit events. |
| Streaming assumptions unproven | Build parser/store and fixture-backed streaming adapter tests before UI integration. |
| Renderer scope too broad | First pass is incremental live operator console using existing visual system; further density work is snapshot-gated. |
| Docs could overclaim | Require VM-lab-only, fail-closed, non-production wording and no host mutation claims. |
| `$team` premature | Use single-owner `$ultragoal`; defer `$team` until store/adapter contracts are green and work can split without shared-file conflicts. |

### LiveRunStore v1 Contract
Implementation may use Zig structs, but must preserve this logical schema:

```text
LiveRunStoreV1 {
  schema_version: "live-run-store.v1",
  active_run: ?RunIdentity,
  phase: Phase,
  footer_mode: FooterMode,
  event_cursor: EventCursor,
  events: []RunEvent,
  lanes: LaneState,
  counters: RuntimeCounters,
  actions: ActionRegistry,
  incidents: []Incident,
  malformed_line_count: u32,
  dropped_event_count: u32,
  redaction_policy: RedactionPolicy,
}
```

Required enums:

```text
Phase = queued | booting | marker_wait | verifying | verifier_rejected | attach_ready | attached | observing | rollback_ready | rollback_requested | rollback_running | cleanup_running | cleaned | validated | incident | safe
FooterMode = RUNNING | ROLLBACK | CLEANUP | SAFE
IncidentKind = qemu_unavailable | verifier_reject | lost_stream | timeout | rollback_failure | cleanup_residue | malformed_line | duplicate_action_id | stale_action_id | process_exit_unexpected | stream_decode_error
```

Required supporting structures:

```text
LaneState {
  boot: PhaseState,
  marker: PhaseState,
  verifier: PhaseState,
  attach: PhaseState,
  runtime_samples: PhaseState,
  rollback: PhaseState,
  cleanup: PhaseState,
  validation: PhaseState,
}

PhaseState {
  status: pending | active | pass | refuse | incident | skipped,
  last_seq: ?u64,
  summary: string,
}

Incident {
  seq: u64,
  kind: IncidentKind,
  severity: info | warning | error | unsafe_to_assume,
  phase: Phase,
  summary: string,
  raw_redacted: string,
  recoverable: bool,
}

RedactionPolicy {
  hide_absolute_host_paths: bool = true,
  hide_environment_assignments: bool = true,
  hide_long_opaque_tokens: bool = true,
  max_raw_preview_bytes: u16,
}
```

Required fields:

```text
RunIdentity {
  run_id: string,
  vm_id: string,
  target_id: string,
  daemon_pid: ?pid,
  daemon_pgid: ?pid,
  started_at_ms: i64,
}

EventCursor {
  next_seq: u64,
  selected_seq: ?u64,
  newest_seq: ?u64,
  scrub_offset: i32,
}

RunEvent {
  seq: u64,
  timestamp_ms: i64,
  run_id: string,
  kind: string,
  phase_after: Phase,
  summary: string,
  raw_redacted: string,
  source: daemon | control | store | test_fixture,
  action_id: ?string,
  dedupe_key: string,
}

RuntimeCounters {
  samples_seen: u64,
  cpu_samples: u64,
  memory_samples: u64,
  io_samples: u64,
  verifier_samples: u64,
  last_sample_ms: ?i64,
}

ActionRegistry {
  stop: ?ActionState,
  rollback: ?ActionState,
}

ActionState {
  action_id: string,
  run_id: string,
  target_id: string,
  requested_at_ms: i64,
  phase_when_requested: Phase,
  status: pending | accepted | duplicate_refused | stale_refused | completed | failed,
  expires_after_phase: Phase,
}
```

Store invariants:
- Event `seq` is monotonic.
- Duplicate `dedupe_key` does not mutate lifecycle state.
- Duplicate action ID produces visible event: `REFUSED duplicate action id: <action_id>`.
- Stale action ID produces visible event: `REFUSED stale action id: <action_id>`.
- Malformed daemon line increments `malformed_line_count` and creates an incident event with redacted raw payload.
- Redaction removes absolute host paths, environment-like secrets, and long opaque tokens before display/transcript.
- Dropped events increment `dropped_event_count` and surface a visible warning if buffer limits are exceeded.

### Oracle Execution Plan
1. **Parser/store contract lane — owner: executor**
   - Add LiveRunStore v1 types and pure parser/store tests.
   - Convert daemon/event lines into typed events.
   - Implement phase transitions, dedupe, cursor, malformed-line, redaction, incident, and counter updates.
   - No renderer or process changes yet.

2. **Streaming adapter lane — owner: executor**
   - Refactor `src/tui/daemon_adapter.zig` so daemon output is consumed incrementally.
   - Add fixture-backed fake daemon driver that emits delayed lines.
   - Prove UI-facing model receives `queued`, `booting`, and `attached` before EOF.
   - Preserve fail-closed timeout behavior.

3. **Process ownership lane — owner: executor**
   - Start daemon in an owned process group/session.
   - Signals target only the owned PGID.
   - Escalation contract: stop request signal; wait up to 2s; terminate owned PGID; wait up to 1s; kill owned PGID; incident if still present.
   - Add fixture proving unrelated sibling process survives.

4. **Active controls lane — owner: executor**
   - Implement active-target contract for `s` and `b`.
   - `s` is single-press valid during: `queued`, `booting`, `marker_wait`, `verifying`, `attach_ready`, `attached`, `observing`.
   - `b` is single-press valid during: `rollback_ready`, `attached`, `observing`, and verifier/incident states where rollback target exists.
   - Duplicate/stale IDs are visibly refused and logged as audit events.
   - Accepted active stop/rollback exits `0` after safe cleanup unless daemon reports failure; rollback failure and cleanup residue exit non-zero.

5. **Event-loop TUI integration lane — owner: executor**
   - Replace launch-then-render flow in `src/tui/main.zig`.
   - Event loop multiplexes daemon frames, keyboard input, timers/timeouts, and render ticks.
   - Redraw immediately on event/control and otherwise at least every 250ms while active, with no busy-spin.

6. **PTY/e2e transcript lane — owner: test-engineer**
   - Extend `tools/tui_live_vm_pty_test.py` and `qa/tui_live_lab_e2e.sh`.
   - Assert ordered intermediate markers:
     ```text
     [queued] VM run queued
     [booting] QEMU boot requested
     [attached] console attached
     [observing] runtime sample
     [rollback ready] rollback target ready
     [cleanup] cleanup running
     [cleaned] VM resources cleaned
     [SAFE] footer mode SAFE
     ```
   - Assert refusal markers:
     ```text
     REFUSED duplicate action id:
     REFUSED stale action id:
     ```
   - Assert incident markers:
     ```text
     INCIDENT qemu_unavailable
     INCIDENT verifier_reject
     INCIDENT lost_stream
     INCIDENT timeout
     INCIDENT rollback_failure
     INCIDENT cleanup_residue
     ```
   - Timeout bounds: first fake streaming frame within 750ms; happy-path fixture within 15s; lost-stream incident within 3s of silence threshold; rollback/cleanup escalation completes or fails visibly within 5s.

7. **Renderer polish lane — owner: executor**
   - Densify existing `src/tui/screens.zig` panes.
   - Add real event cursor/scrub view and runtime sample counters.
   - Preserve Linux/operator labels and avoid simulator task/Gantt/policy-teaching labels.
   - Snapshot-gate queued, running/observing, rollback, cleanup, safe, and incident states.

8. **Failure matrix and docs lane — owner: verifier**
   - Extend `qa/tui_live_lab_failure_matrix.sh` for qemu/kvm unavailable, verifier reject, lost stream, malformed line, timeout, duplicate/stale action, rollback failure, and cleanup residue.
   - Confirm docs/UI wording remains VM-lab-only, fail-closed, non-production, and no host mutation.

9. **Final verification lane — owner: verifier**
   - Run final gates and collect evidence:
     ```bash
     zig build test --summary all
     bash qa/tui_live_lab_e2e.sh --self-test
     bash qa/tui_live_lab_failure_matrix.sh
     bash qa/unsafe_cli_matrix.sh
     bash qa/no_host_mutation.sh
     zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print)
     git diff --check
     ```
   - Where a real QEMU/KVM host is unavailable, fixture/failure-matrix proof is acceptable for default CI; no VM-live success claim may be made without live bundle validators.

### Verification Matrix
| Claim | Required evidence | Owner/lane |
| --- | --- | --- |
| Daemon output streams incrementally before EOF | Fake daemon emits delayed lines; test sees `queued` then `booting` before process exits | Streaming adapter |
| Store schema/invariants implemented | Unit tests for phase transitions, cursor, dedupe, malformed lines, redaction, dropped count, incidents | Parser/store |
| Duplicate action visibly refused | Unit + PTY transcript contains `REFUSED duplicate action id:` | Active controls |
| Stale action visibly refused | Unit + PTY transcript contains `REFUSED stale action id:` | Active controls |
| `s` stops active run mid-run | PTY sends `s` during `observing`; transcript shows stop/cleanup/safe sequence | Active controls / PTY |
| `b` rollbacks active VM target | PTY sends `b` when rollback-ready; transcript shows rollback/cleanup/safe sequence | Active controls / PTY |
| Signals target only owned PGID | Process test starts unrelated sibling; stop/rollback does not kill sibling | Process ownership |
| Timeout escalation bounded | Test proves graceful→terminate→kill escalation with visible timeout/incident within bound | Process ownership |
| Event loop redraws while run active | PTY transcript contains ordered intermediate markers, not just final screen | Event-loop / PTY |
| Runtime counters update per sample | Fixture emits multiple samples; snapshot/transcript shows increasing counters | Store / Renderer |
| Event cursor/scrub exists | Unit or snapshot proves selected/newest cursor changes and bounded event list display | Renderer |
| Incident states first-class | Failure matrix transcript contains required `INCIDENT ...` markers | Failure matrix |
| Renderer remains Linux/operator semantic | Snapshot review contains no simulator task/Gantt/fidelity claims | Renderer / Verifier |
| Docs stay fail-closed and VM-lab-only | Review/grep docs and UI strings for non-production wording and no host mutation claims | Docs / Verifier |
| Existing build target preserved | `build.zig` still exposes `tui-live-vm`; root `zig build run` not repointed | Verifier |
| Unsafe verbs still refuse | `bash qa/unsafe_cli_matrix.sh` proves `load`, `attach`, `enable`, `mutate`, and `apply` refuse non-zero without host mutation | Final verification |
| No host-mutation surface introduced | `bash qa/no_host_mutation.sh` plus source review/scans prove no host BPF load, scheduler attach, cgroup/cpuset/affinity/priority mutation, or scheduler-state mutation path was added | Final verification |
| Formatting clean | `zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print)` passes | Final verification |
| No whitespace errors | `git diff --check` passes | Final verification |
| All tests pass | `zig build test --summary all` passes | Final verification |
| E2E default proof passes | `bash qa/tui_live_lab_e2e.sh --self-test` and relevant fixture mode pass | Final verification |
| Failure matrix passes | `bash qa/tui_live_lab_failure_matrix.sh` passes | Final verification |

### Artifact
- Durable plan path: `.omx/plans/prometheus-strict/live-event-loop-tui-vm.md`

### Handoff
- Recommended next workflow: `$ultragoal`
- Do **not** start `$team` yet. Interfaces must stabilize first: LiveRunStore v1, streaming adapter, process ownership, and active-target contract.
- `$team` becomes appropriate only after parser/store and adapter contracts are green and remaining work can split cleanly into renderer, PTY, and docs lanes.

Callable handoff:

```bash
$ultragoal "Execute .omx/plans/prometheus-strict/live-event-loop-tui-vm.md as a single-owner story. Keep the concrete entrypoint as zig build tui-live-vm; do not repoint root zig build run; preserve VM-lab-only fail-closed non-production boundaries; satisfy every verification matrix row before claiming completion."
```

Stop condition: every verification matrix row has evidence and final gates pass.

Completion-blocking condition: any failed renderer, docs, e2e, failure-matrix, safety, formatting, or test gate blocks completion and requires iteration before handoff can be considered done.

Rollback condition: revert implementation changes if streaming/control/process ownership tests cannot be made fail-closed without unsafe host mutation, or if a later renderer/docs/e2e change introduces unsafe host mutation, production-readiness claims, or an unfixable contradiction with the VM-lab-only boundary. Ordinary renderer/docs/e2e failures that remain within the safety boundary should be iterated, not reverted by default.

Escalation condition: ask the user only if scope must widen to root `zig build run`, production host scheduling, BPF/cgroup/cpuset/affinity mutation, or external VM infrastructure beyond current lab fixtures.

### Oracle Self-Verification
| Gate | Result |
| --- | --- |
| Every machine-checkable claim has evidence source | Pass |
| Every execution step has owner/lane | Pass |
| Parallel conflict avoided | Pass — recommends single-owner `$ultragoal`; `$team` deferred |
| Acceptance and rollback are consistent | Pass |
| No unauthorized destructive/production step | Pass |
| Concrete workflow handoff exists | Pass |
| Explicit non-goals preserved | Pass |
| Clean-room credit preserved | Pass |

### Post-Plan Metis Gap Check
- Round 1 result: ITERATE. Repaired missing unsafe-verb/no-host-mutation verification, undefined `LaneState`/`Incident`/`RedactionPolicy` schema members, and rollback-vs-completion-blocking semantics.
- Round 2 result: PASS. No remaining blocking ambiguity, lane-overlap, unsafe scope, acceptance/rollback contradiction, or handoff ambiguity found.

### Clean-Room Credit
Inspired by OMO Prometheus (`code-yeongyu/oh-my-openagent`), reimplemented from concept under MIT.
