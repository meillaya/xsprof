# xsprof UI design contract

> The interactive console prototype is [`design/index.html`](design/index.html);
> its extracted token set, screens, flows, keybindings, and GPU mapping live in
> [`design/`](design/README.md). This document remains the profiler screen contract.

The profiler UI is a dense, read-only operator console. It should feel like an
instrument panel, not a marketing dashboard: compact monospace rows, visible
evidence, exact reason codes, and state colors that carry meaning.

- **nanoui-derived:** single binary, immediate-feeling Zig authoring, GPU
  instancing, web frontend, headless PNG snapshots, no C shims, idle-no-poll.
- **Raven-derived:** retained tree/cached layout, slot layout, flat draw list,
  custom-widget painter, render thread/backpressure, timeline/data widgets.
- **Profiler-specific:** CPU/thread timeline, advisor evidence, event ledger,
  READY/DEGRADED/SKIP/REFUSE capability states.

## Identity

- Wordmark: `▚ xsprof`
- Context line: `read-only scheduler & memory profiler`
- Persistent safety chip: `read-only · host_mutation=false`
- Source chip: `LIVE` or `REPLAY`
- Tone: terse, evidence-led. No celebratory language for gate results.

## Color tokens

| Token | Value | Role |
|---|---|---|
| `bg.letterbox` | `#050505` | outer shell |
| `bg.panel` | `#10100e` | primary pane |
| `bg.raised` | `#171512` | selected row/card |
| `bg.paper` | `#f3ead7` | light theme |
| `text.primary` | `#f5efe4` | main text |
| `text.muted` | `#a79b8c` | metadata |
| `border.hairline` | `#3a332b` | 1 px divisions |
| `accent.live` | `#58d7e8` | live/active |
| `status.pass` | `#72d487` | READY/PASS only |
| `status.skip` | `#e3b45c` | SKIP/uncollected |
| `status.refuse` | `#ff6b9a` | REFUSE/incident/loss |
| `status.pending` | `#ded6c9` | queued/pending |
| `status.vm` | `#b48cff` | VM-only identity |

Additional themes: light “paper” and high-contrast, exposed as
`xsui.themes.light` / `xsui.themes.high_contrast` with
`xsui.themes.derive` for overrides. Unavailable data is `SKIP`/uncollected,
never a fabricated zero. Lost/gapped/refused/malformed rows use refusal
styling.

## Typography and spacing

- Monospace-first: JetBrains Mono (OFL), bundled. Sizes 10/11/12/14/16/20.
  Numeric values use 14–16 px so the dotted zero stays legible; labels may use 9–10 px.
- Regular 400, medium 500, bold 700. Tabular numerals for counters/times.
- 4 px spacing grid; 1 px borders; 4–6 px radii; no decorative shadows.
- Long paths are relative evidence references; truncate visually, never
  rewrite the stored value.

## Layout

- Persistent header: wordmark, source, host/kernel, safety chip, loss counter,
  theme/help.
- Footer key map: visible shortcuts; every action has a pointer equivalent.
- Screens: Overview, Timeline, Advisor, Events, Capture status.
- Panes use hairline borders and dense ledgers. Overlays (palette, tooltip)
  are separate layers and never hide the safety/loss banner.
- Responsive/narrow: stack in workflow order; never hide refusal/loss rows.

## Screens

1. **Overview** — host facts, capability matrix with reasons, per-CPU
   utilization/runqueue, migrations/wakeups/faults/cache/memory/NUMA, top
   threads, advisor summary, alerts.
2. **Timeline** — ruler, minimap, CPU/thread lanes, switch intervals, paired
   wakeup→switch flows, instant markers, loss bands, brush selection,
   inspector. Zoom/pan/fit/follow/pause; virtualized and downsampled.
3. **Advisor** — seven rules with severity/confidence/summary/evidence/
   recommendations. Evidence focuses the timeline. “Suggestion only — never
   applied.” Empty, uncollected, and healthy are distinct.
4. **Events** — append-only ledger; filter/search; follow-tail; loss/gap rows;
   detail pane; sanitized, privacy-redacted text.
5. **Capture** — read-only status/instructions: capability, SKIP reason,
   duration/output guidance, BPF VM-only explanation. No mutation controls.

## Motion

Springs/tweens 120–180 ms for hover, focus, panel transitions, ledger
insertion. Cursor blink 1 s; live pulse 1.6 s. Reduced motion snaps to target.
Never animate loss/refusal/unsafe states into normal progress.

## Keyboard

`1..5` screens, `/` filter, `Space` pause, `f` fit, `+/-` zoom, `t` now,
`w` theme, `?` help, `q` quit, `Cmd/Ctrl+K` palette, `c` copy, `Esc` close
overlay. Focus ring always visible. No IME composition or screen-reader bridge
in v1.

## Rendering

- One flat instance stream (~96 B) + one SDF shader per backend.
- Per-instance clip; R8 glyph atlas; 1–3 draw calls typical.
- CPU raster is the reference for snapshots and parity; Metal and WebGL2
  consume the same draw list.
- No glass/blur/shadows in v1. Flat surfaces, borders, and typography carry
  depth.

## Required states for every screen

`loading`, `empty`, `ready`, `SKIP` (with reason), `REFUSE`/incident, `loss`
(with count), `stale`, `malformed`. A missing signal is never displayed as a
zero measurement. `PASS`/`READY` is scoped to the gate that produced it and is
never a release/production claim.
