# zig-scheduler frontend design contract

This document is the root design contract for a future frontend planning lane. It is documentation only: no frontend implementation is authorized now, no source tree or dependency stack is approved by this file, and `frontend.html` remains a `reference-only` visual/function artifact rather than committed product source.

Design extraction mode: **Balanced extraction**. Preserve the recognizable `zig-scheduler · live microVM lab` command-center identity, operator workflow vocabulary, and fail-closed safety semantics while allowing a later implementation to improve maintainability, accessibility, responsiveness, and testability.

Safety scope that every later UI concept must repeat: all backend-derived rows keep `host_mutation=false`; VM mutation evidence is **VM-only** and lab-only; `PASS` means a bounded evidence row or bundle passed its own gate only; it is **not release**, **not production**, not a performance promise, and not authorization for any real-host scheduler binding.

## 1. Atmosphere & Identity

The future UI should feel like a dense Linux scheduler lab console rendered in a browser: compact, bordered, keyboard-first, evidence-led, and intentionally more like an operator TUI than a marketing dashboard. The reference identity string is `▚ zig-scheduler` with a `live microVM lab` context line. Keep the mood serious, instrumented, and fail-closed.

Identity rules before implementation:

- Primary artifact relationship: `frontend.html` is `reference-only`; use it to preserve recognizable look and workflow, not as source to copy or commit.
- Extraction policy: **Balanced extraction**; do not perform pixel-perfect cloning, and do not flatten the design into a generic admin panel.
- Safety copy is part of the visual identity. Every screen that shows lab proof, attach-like VM evidence, rollback, cleanup, or release eligibility must visibly retain `VM-only`, `host_mutation=false`, `not release`, and `not production` semantics.
- Tone: terse operator labels, schema terms, artifact references, exact reason codes, and visible refusal/incident rows. Avoid celebratory language for proof states.
- Product promise boundary: the design may describe future client planning only. It must not claim release readiness, production readiness, performance capacity, or real-host scheduler approval.

Core screens and states to preserve from the reference and contract maps:

- Home/read-only preflight state with host-safe facts and refused unsafe host verbs.
- VM target selection state with explicit audit, target, and rollback identity requirements.
- VM lab lifecycle state: preflight, build, boot, marker, verifier, attach, observe, rollback, audit, cleanup, validate.
- Evidence state: stage ledger, gate ledger, proof bundle summary, matrix handoff, artifact integrity, and incident/refusal banner.
- Replay state: deterministic fixture/replay inspection, including lost/gapped stream handling as unsafe/incomplete.

## 2. Color

Color tokens must communicate contract state before decoration. A later implementation may tune exact values for accessibility, but the semantic roles below are fixed.

| Token | Suggested value | Role | Required state semantics |
| --- | --- | --- | --- |
| `color.bg.letterbox` | `#050505` | outer shell background | quiet, non-content frame |
| `color.bg.panel` | `#10100e` | primary dark pane | dense operator surface |
| `color.bg.panel-raised` | `#171512` | selected cards/rows | active evidence focus, not success by itself |
| `color.bg.paper` | `#f3ead7` | future light/paper mode | daylight variant, still technical |
| `color.text.primary` | `#f5efe4` | main text | readable lab facts |
| `color.text.muted` | `#a79b8c` | secondary labels | metadata and captions |
| `color.border.hairline` | `#3a332b` | 1 px pane borders | TUI-style separation |
| `color.accent.live` | `#58d7e8` | live/active accent | observing, cursor, selected target; not final proof |
| `color.status.pass` | `#72d487` | `PASS` | accepted step or bundle row only |
| `color.status.skip` | `#e3b45c` | `SKIP`/withheld | intentionally unavailable or fail-closed non-action |
| `color.status.refuse` | `#ff6b9a` | `REFUSE`/incident | unsafe or refused; host unchanged |
| `color.status.pending` | `#ded6c9` | queued/pending/read-only | waiting or preflight state |
| `color.status.vm` | `#b48cff` | VM lab identity | VM-only lane and audit/rollback identifiers |

Theme families allowed for future implementation:

- Warm-dark operator default: black/pane neutrals, cyan live accent, green pass, amber skip, pink refusal.
- Cool dark: charcoal surfaces and cyan/mauve accent with the same state roles.
- Paper/light: tan paper surfaces with near-black ink and preserved state colors.
- Mocha/latte-inspired variants may be used only if state contrast remains accessible and terms remain contract-first.

Color constraints:

- Never render `SKIP`, `REFUSE`, lost stream, sample loss, privacy rejection, or release-ineligible states as success.
- `PASS` green is scoped; it does not mean release, production, performance, or host mutation approval.
- Missing or malformed data uses refusal/incident styling, not neutral absence.

## 3. Typography

Typography should preserve the reference’s compact operator-console feel.

| Token | Value | Use |
| --- | --- | --- |
| `font.family.mono` | `JetBrains Mono`, `Fira Code`, `SF Mono`, Menlo, Consolas, monospace | all primary UI text |
| `font.weight.regular` | `400` | body rows and metadata |
| `font.weight.medium` | `500` | pane subtitles and stable labels |
| `font.weight.semibold` | `600` | counters, row keys, status chips |
| `font.weight.bold` | `700` | product mark, terminal alerts, selected state |
| `font.size.micro` | `10px` | glyph labels, tiny counters, footer hints |
| `font.size.small` | `11px` | row metadata and status captions |
| `font.size.body` | `12px` | dense table rows and event ledger |
| `font.size.value` | `14px` | counters and key values |
| `font.size.title` | `16px` | compact pane titles and header identity |
| `font.feature.tabular` | `tnum`, `zero` where supported | sequence IDs, latency, counters, timestamps |

Typography rules:

- Use uppercase or small-caps styling only for short pane labels and state chips; keep evidence copy readable.
- Reason codes such as `lost_stream`, `release_ineligible`, and `workload_capability_missing` remain monospace and exact.
- Sequence numbers, `sample_sequence`, RTT, DSQ depth, and runtime counters use tabular numerals.
- Long artifact paths are relative evidence references; truncate visually with a disclosure affordance, never rewrite the stored path.

## 4. Spacing & Layout

The layout grammar is high-density but must remain navigable. Exact pixels can change later; relationships and states are the contract.

Spacing and sizing tokens:

| Token | Suggested value | Use |
| --- | --- | --- |
| `space.1` | `4px` | chip gaps, glyph spacing |
| `space.2` | `8px` | row padding, compact gutters |
| `space.3` | `12px` | pane internal padding |
| `space.4` | `16px` | major grid gutters |
| `space.5` | `24px` | section separation in non-live views |
| `radius.none` | `0` | terminal bars and table joins |
| `radius.small` | `4px` | chips and small controls |
| `border.hairline` | `1px` | pane, row, and ledger divisions |
| `density.compact` | 10–11 px row text, narrow gutters | live operator mode |
| `density.standard` | 12 px row text, standard gutters | default planning/replay mode |
| `density.wide` | more whitespace, same hierarchy | accessibility/large displays |

Required layout primitives:

- Shell: full-viewport operator frame with persistent header/footer bars.
- Idle/preflight grid: two-pane layout for target picker and read-only host facts/refusals.
- Live lab grid: three-column layout, with lifecycle/gate evidence left, runtime/latency middle, and firehose/journal right.
- Pane header: title, subtitle, right-side count/status chip, and hairline divider.
- Ledger rows: fixed status glyph, event or protected-core label, exact reason/status, relative artifact link, and `host_mutation=false` where applicable.
- Alert strip: one-line high-signal notice for request, refusal, incident, sample loss, or lost stream.
- Footer key map: keyboard shortcuts plus clickable equivalents for later accessibility.

Responsive rules:

- On narrow screens, stack panes in workflow order: alert, target/preflight, lifecycle, gate ledger, runtime, firehose, footer.
- Do not hide refusal/incident/safety rows behind decorative cards.
- Preserve deterministic replay inspection even when graphs collapse into textual rows.

## 5. Components

Component primitives are defined here before implementation. They describe required behavior and state mapping, not a mandate to add UI code now.

| Primitive | Purpose | Required states/data |
| --- | --- | --- |
| `AppShell` | outer operator frame | product identity, lab mode, theme/density, daemon/replay status |
| `AlertStrip` | current blocking notice | request, queued, incident, refusal, lost stream, cleanup residue |
| `TargetPicker` | select or review VM lab target | target ID, release/arch note, audit ID, rollback ID pre-arm status |
| `PreflightFacts` | host-safe observation pane | read-only facts and refused unsafe verbs; no mutation controls |
| `LifecycleLedger` | VM pipeline progress | preflight/build/boot/marker/verifier/attach/observe/rollback/audit/cleanup/validate |
| `GateLedger` | proof and governance checks | lab scope, VM marker, host mutation, release eligibility, audit, rollback, cleanup |
| `RuntimeSamplePanel` | redacted runtime observation | scheduler state, DSQ depth, fairness, `nr_rejected`, workload alive, sample loss |
| `LatencyPanel` | queue/runtime summaries | bars/sparklines from contract-approved summaries only |
| `FirehoseLedger` | append-only daemon event rows | `daemon-event/v1` seq, event, status, reason, artifact, `host_mutation=false` |
| `ProofBundleSummary` | evidence-manifest display | PASS/SKIP/REFUSE/BLOCKED, protected-core rows, hash/path integrity |
| `MatrixHandoff` | matrix artifact reference | `matrix-run/v1` manifest path and validation-needed/pass/refuse state |
| `IncidentBanner` | refusal/incident taxonomy | exact wire reason, operator guidance, unsafe/incomplete display |
| `KeyMapOverlay` | keyboard help | `m`, `b`, `s`, `h`, `w`, `?`, `q`, target number keys, confirmation states |
| `ConfirmAction` | dangerous action confirmation | rollback/stop second-press copy; queues only schema-valid actions in a future approved implementation |

State rules for every primitive:

- Source of truth is the backend contract pack: `docs/control/frontend-api-pack.md`, stream semantics, incident taxonomy, schemas, and fixtures.
- `daemon-event/v1` rows are append-only ledger entries. Preserve `seq` and render gaps/nonmonotonic replay as refusal or incident states.
- `runtime-sample/v1` rows are privacy-filtered VM observations converted into daemon events; do not show raw paths, command lines, argv, environment, secrets, `/proc`, or `/sys` values.
- Matrix and proof manifests are evidence references. A UI may show them as validation-needed until the relevant checker has accepted the artifact.
- `release_ineligible`, `lost_stream`, `workload_capability_missing`, privacy rejection, malformed runtime, and replay-row refusals are blocking/unsafe displays.
- No component may imply that frontend controls can mutate the host. Future controls, if explicitly approved later, submit schema-valid backend actions and display refusal/incident rows when gates fail.

## 6. Motion & Interaction

Motion is minimal, terminal-like, and evidence-oriented.

Motion tokens:

| Token | Timing | Use |
| --- | --- | --- |
| `motion.cursor.blink` | 800–1200 ms step | active row cursor or awaiting replay frame |
| `motion.live.pulse` | 1400–2000 ms ease | daemon/VM live dot; never terminal proof |
| `motion.row.insert` | 120–180 ms fade/slide | new ledger row, respecting reduced-motion |
| `motion.scan.subtle` | 4–8 s linear | optional pane scan line for live mode only |
| `motion.confirm.flash` | 120 ms | rollback/stop confirmation feedback |

Interaction rules:

- Keyboard-first with visible clickable equivalents. Reference keys: `m` request live microVM run, `b` rollback confirmation, `s` safe stop confirmation, `h` home, `w` theme, `?` help, `q` quit, number keys for target selection.
- Dangerous interactions require confirmation copy and identity context before any future action submission.
- Lost, malformed, stale, duplicate, gapped, or truncated streams fail closed visually; do not animate them into normal progress.
- Replay and fixture inspection are deterministic. The v1 `events.follow` surface is replay-equivalent, not live push.
- Reduced-motion mode must preserve all evidence freshness and state changes through text, glyphs, and status chips.

Implementation-readiness gate:

No frontend implementation is authorized now. A later frontend execution step may begin only after explicit approval that names the source location and accepts the no-frontend governance change, if any. Until then, this repository remains docs/design-only for frontend planning.

A future approved implementation must satisfy all of these gates before code is considered reviewable:

1. Explicit approval: written task scope authorizes frontend source files, any dependency stack, and any changes to root no-frontend governance.
2. Source boundary: source location is named up front; simulator history remains untouched unless separately authorized.
3. Contract boundary: no backend contract drift; no backend schema, fixture, daemon, or API-pack changes are made to fit the UI unless a separate backend task approves them.
4. Fixture/replay first: UI state is built from committed frontend-contract fixture rows and replay outputs before any live bridge is discussed.
5. Safety copy: visible states preserve `host_mutation=false`, `VM-only`, `not release`, and `not production` wording.
6. Required gates: `bash qa/no_frontend_root.sh`, `git diff --check`, backend client-contract checks, fixture/schema replay checks, and any newly approved frontend lint/test/build commands must pass.
7. Visual QA: future browser work requires screenshot-based visual QA against this design contract and the reference-only artifact.
8. Lighthouse: if a browser implementation is later approved, run Lighthouse or an equivalent accessibility/performance diagnostic as an advisory quality check only; do not treat it as a performance promise.
9. Failure behavior: malformed input, replay gaps, lost streams, privacy rejection, and release-ineligible rows render unsafe/incomplete states.

## 7. Depth & Surface

Depth should come from layered evidence surfaces, not decorative realism.

Surface tokens:

| Token | Suggested value | Use |
| --- | --- | --- |
| `shadow.none` | none | default panes; TUI flatness |
| `shadow.focus` | `0 0 0 1px color.accent.live` | focused selected pane or row |
| `shadow.danger` | `0 0 0 1px color.status.refuse` | refusal/incident emphasis |
| `surface.base` | letterbox + pane | persistent operator shell |
| `surface.raised` | slightly lighter panel | selected target, active ledger group |
| `surface.overlay` | bordered modal/panel | key map and confirmation overlays |
| `surface.evidence` | tabular ledger | append-only proof/refusal rows |

Depth rules:

- Use borders, ledgers, and row grouping more than drop shadows.
- The highest visual priority is current unsafe/refused/lost-stream state, then active VM-only observation, then completed evidence rows, then static preflight facts.
- Proof bundle and matrix artifact surfaces show validation state and relative paths; they do not become badges of release approval.
- Overlays must not hide the alert strip or current unsafe state.
- If visual density conflicts with safety copy, safety copy wins.

Manual QA expectations for this design contract:

- Read every required section and confirm token/components/states exist before implementation.
- Confirm the implementation-readiness gate refuses current implementation authority.
- Confirm no frontend source, dependencies, build steps, simulator edits, backend contract/schema/fixture changes, or `qa/no_frontend_root.sh` changes are introduced by this document.
