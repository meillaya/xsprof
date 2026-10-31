# GUI lab plan

Status: in progress. L0 and L1 are implemented. L2 adds the native lab rail,
source buttons, capture controls, transport buttons, and command palette. L3
adds transport window advancement, the inspector, trace export, and native
path editing. L4 adds the scenario schema, headless runner, built-in
scenarios, and `lab-smoke`. The wasm replay client now shares the lab state
and rail but hides native-only source and capture controls. The wasm client also runs the
healthy scenario through `web_run_scenario` and reports assertions. L3 A/B
compare uses a second source store and reports regression counts in the rail.
Remaining: web file pickers for custom scenarios and the final acceptance
sweep.

## Goal

Make the profiler a lab bench: choose a source, run a bounded read-only
scenario, drive every screen from one control surface, inspect the evidence,
export the result, and replay the same run headlessly.

The GUI should be able to drive every CLI capability that does not mutate the
host:

| CLI surface | Lab action | Where |
|---|---|---|
| `record` | start and stop a bounded capture | native, capability-gated |
| `daemon`, `capture` | open a recorder directory, extract a window | all platforms |
| `serve` | open the loopback view | native host |
| `metrics`, `compare` | analyze A/B sessions | all platforms |
| `timeline` | export Chrome Trace | all platforms |
| `advise` | open Advisor with evidence | all platforms |
| `snapshot` | capture the current frame | all platforms |
| `doctor`, `pressure`, `cgroup` | host panel | native Linux |
| `ui` | the lab itself | native and web replay |

## Principles

- **One action stream.** Keyboard, pointer, command palette, scenario files,
  and the headless CLI all produce the same bounded `Action` values.
- **Pure reducer.** `Action` plus `LabState` yields `LabState` and a bounded
  list of `Effect` values. Rendering never performs I/O.
- **Read-only host.** No action enables BPF on a host, writes `/proc` or
  `/sys`, changes policy, elevates privileges, or applies advice. A capture
  action opens perf only when the existing probe reports READY.
- **Deterministic first.** Every state has a headless test through
  `xsui.Tester`. A scenario run must produce the same JSON and frame hashes
  with a fixed clock.
- **Explicit failure.** SKIP, REFUSE, loss, malformed input, and missing files
  stay visible in the workbench. A failed run is never shown as a pass.
- **Web replay only.** The wasm surface cannot start a perf capture. It can
  open journals and scenarios and must say why live capture is unavailable.
- **Bounded memory.** One frame arena, bounded event stores, bounded action
  queues, and no per-frame allocation churn.

## Current gaps

| Area | Today | Lab requirement |
|---|---|---|
| Input | one key per frame; pointer and wheel | text fields, shortcuts, focus, command palette |
| Widgets | panel, chip, stat, rule, key hint | button, toggle, list, modal, toast, text field |
| State | five screens over one immutable Session | source, capture, transport, scenario, run state |
| Capture | CLI only, blocking | worker-owned bounded capture with start/stop/progress |
| Sources | replay file or web live store | replay, recorder dir, scenario, live (native) |
| Evidence | screens and CLI exports | cross-screen selection, A/B compare, export actions |
| Harness | snapshots and unit tests | scenario steps and assertions, headless `lab` command |
| Web | file open and SSE | replay-only lab rail with explicit unsupported states |

## Target model

```text
keyboard / pointer / palette / scenario / CLI
                    |
                 Action
                    |
          LabState reducer (pure)
                    |
            Effect list
                    |
        platform executor
                    |
     Session / EventStore / files
```

`LabState` holds the current source, phase, capture state, transport,
scenario, step, selection, filters, output directory, and the last error. It
owns no file handles and no threads.

Source variants:

- `replay`: one journal path, immutable Session.
- `recorder`: state directory plus manifest, bounded windows.
- `scenario`: one or more built-in fixtures, deterministic clock.
- `live`: native only, bounded store fed by a capture worker.

Phase variants: `idle`, `loading`, `ready`, `running`, `paused`, `exporting`,
`failed`. Every failure carries a reason and the action that caused it.

Effects:

- `open_source`, `close_source`
- `start_capture`, `stop_capture`
- `extract_window`, `append_events`
- `export_trace`, `export_report`, `save_snapshot`
- `run_scenario`, `assert_scenario`
- `open_loopback`

Platform executors own threads, child processes, and file I/O. The web
executor supports only replay, recorder, scenario, and export.

## Workbench

The existing five screens stay. A persistent Lab rail sits above the footer or
as a narrow left column, and toggles with `L`:

1. **Source**: open journal, open recorder directory, choose a scenario,
   recent sources, source facts and validation result.
2. **Capture**: duration, preset, start/stop, event rate, loss, CPU/RSS
   overhead, and the exact READY/SKIP/REFUSE reason. Disabled on web with a
   reason.
3. **Transport**: play, pause, step, speed, window, fit, follow, and scrub.
4. **Scenarios**: built-in list, step progress, assertion results, and a
   failure reason.
5. **Inspector**: selected task, CPU, cgroup, event detail, advisor evidence,
   and the active combined filter.
6. **Export**: trace, report, snapshot, and run JSON, always into an explicit
   output directory.

A command palette (`Cmd/Ctrl+K`) lists every action with its shortcut and
availability. Unavailable actions show the gate reason; they do not disappear.

## Scenario format

Scenarios are JSON, validated at the boundary, with a stable schema
`xsprof/lab-scenario/v1`:

```json
{
  "schema": "xsprof/lab-scenario/v1",
  "id": "scheduler-mix",
  "source": {"kind": "fixture", "path": "fixtures/real/scheduler-mix.ndjson"},
  "steps": [
    {"at_ms": 0, "action": "screen", "value": "timeline"},
    {"at_ms": 100, "action": "filter", "value": "sched_switch"},
    {"at_ms": 200, "action": "select", "value": "cpu:2"},
    {"at_ms": 300, "action": "snapshot", "value": "timeline"}
  ],
  "assertions": [
    {"metric": "events", "op": "eq", "value": 12000},
    {"metric": "lost", "op": "eq", "value": 0},
    {"metric": "indicator", "op": "eq", "value": "host_mutation=false"}
  ]
}
```

Rules:

- `action` is an enum; there is no shell, no free-form command, and no host
  mutation action.
- Steps are bounded (for example 4096) and sorted by `at_ms`.
- `snapshot` writes only inside `--out`.
- Assertions cover metrics, screen state, and safety indicators.
- A scenario that reads a recorder directory must report missing or corrupt
  segments as failures, never as zeros.

Headless command:

```sh
xsprof lab --scenario scenarios/scheduler-mix.json --out /tmp/lab --json
xsprof lab --list
```

The command builds the same `LabState`, applies the same actions, writes a
frame per snapshot step, and prints canonical JSON with run status, step
results, assertions, loss, and `host_mutation=false`.

## Milestones

### L0: interaction kernel

Add `Action`, `Effect`, `LabState`, and the reducer. Add button, toggle, list,
modal, toast, text field, focus, and command palette primitives. Extend input
with text and several keys per frame. Key-repeat and IME remain out of scope.

Exit: headless tests for focus, text entry, palette filtering, and every
widget state; one snapshot per widget.

### L1: sources and capture controller

Add the source interface and native capture worker. A capture runs off the UI
thread, feeds a bounded queue, and reports progress. Start/stop never elevates
and never runs when the probe is not READY. Add recorder-directory opening and
window extraction.

Exit: SKIP/REFUSE tests on hosts without perf; bounded-memory test for a long
capture; service-level smoke unchanged.

### L2: lab shell

Add the Lab rail, source panel, capture panel, and status chips. Add action
availability and the command palette. Wire the existing screens to the lab
state instead of ad-hoc fields.

Exit: lab idle, loading, ready, running, paused, and failed snapshots; keyboard
and pointer parity for the rail.

### L3: transport and inspection

Add play/pause/step/speed/scrub, follow, cross-screen selection, event
inspector, cgroup and pressure panes, and A/B compare slots. Filters become
actions shared by timeline, ledger, and inspector.

Exit: selection and filter state stays consistent across all screens; snapshot
tests for a scrub and for an A/B pair.

### L4: scenario runner and CLI

Add the scenario schema, parser, runner, assertions, and `xsprof lab`. Add
built-in scenarios for healthy, loss, empty, and real scheduler captures. The
runner uses the deterministic clock and never opens a window.

Exit: canonical JSON golden, per-step frame goldens, failing assertion exits
non-zero, malformed scenario is refused.

### L5: web parity and accessibility

Expose replay, recorder, scenario, filters, transport, and exports in the
wasm build. Live capture says "native only" with a reason. Add focus order,
visible focus rings, larger hit targets, and reduced-motion handling.

Exit: web smoke covers lab open, scenario run, export, and the unsupported
live state; a Playwright screenshot per lab phase.

### L6: acceptance

Run the full gate, add `qa/lab_smoke.sh`, verify native hidden smoke, web smoke,
Linux service smoke, and cross-builds. Document the workbench and scenario
format.

Exit: `zig build check`, `lab_smoke`, web smoke, hidden macOS smoke, Linux VM
tests, and all existing gates pass.

## File plan

```text
src/app/lab/action.zig       Action and Effect enums
src/app/lab/state.zig        LabState and reducer
src/app/lab/scenario.zig     schema, parser, assertions
src/app/lab/runner.zig       headless step runner
src/app/lab/controller.zig   source and capture interface
src/app/lab_view.zig         Lab rail and panels
src/ui/input.zig             text and multi-key input
src/ui/widgets/              button, toggle, list, modal, text field
src/platform/macos/lab.zig   executor: capture, files, snapshot
src/platform/linux/lab.zig   executor: capture, files, snapshot
src/platform/web/lab.zig     replay-only executor
schemas/xsprof/lab-scenario.v1.schema.json
scenarios/                   built-in scenario files
qa/lab_smoke.sh
```

Every file stays under the 600-line limit; the lab view is split by panel.

## Safety and failure rules

- Action allowlist only. No arbitrary command, no shell, no URL input.
- Capture uses the existing `live.Capture` and probe; no privilege path.
- Web has no capture and no control endpoint. `serve` stays GET/HEAD.
- Exports are written only under an explicit output path.
- Missing, malformed, stale, or refused data is a visible state.
- Killing the capture worker on source close or window close must join the
  worker and close rings.

## Open decisions

Defaults are proposed; these can change during L0.

1. **In-app live capture.** Default: native only, gated by the existing probe,
   with an off-thread worker. Alternative: the Lab only opens recorder state
   and never owns perf.
2. **Lab placement.** Default: persistent rail plus command palette, not a
   sixth screen. This keeps the five data screens stable.
3. **Scenario format.** Default: JSON with a Zig enum action set. Alternative:
   a compact text script; JSON is easier to validate and wire to the web.
