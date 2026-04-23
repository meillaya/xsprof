# PRD — M15 follow-up: non-TTY TUI surface

## Status
Revised planner draft — architect + critic feedback incorporated on 2026-04-21

## 1) Task framing and assumption check

### Framing
Plan the next implementation after M15 so the TUI surface can still be used when stdin/stdout are not attached to a real interactive terminal, without regressing the current raw-mode interactive TTY experience.

### Assumption check
The working assumption is **valid from repo evidence**:
- `src/tui/terminal.zig` hard-fails on non-TTY stdin/stdout, enables raw mode, alternate screen, cursor hiding, polling, and terminal-size ioctls.
- `src/tui/root.zig` already bootstraps reports from `--input`, `--stdin`, built-in scenarios, and scenario files before terminal init, so data loading is not the blocker.
- `src/tui/render.zig` already renders a complete frame from `AppView`; the missing piece is a non-interactive presentation path.
- The current pipe-oriented mismatch is surfaced most directly by the in-app picker copy in `src/tui/render.zig`, which advertises `zig build run -- --scenario-file <path> --format json | zig build tui -- --stdin`, while `src/tui/main.zig` still rejects non-TTY stdin/stdout.
- `zig build test --summary all` passes today (`125/125 tests passed` on 2026-04-21).

### Scope boundary
This plan targets a **non-interactive, non-TTY-compatible rendering path for the existing TUI surface**, not a browser app, remote terminal service, or replacement UI stack.

---

## 2) Principles
1. **Keep the current TTY explorer intact.** Real-terminal interactive behavior stays the default when a TTY is available.
2. **Make non-TTY behavior explicit and bounded.** Support snapshot-style rendering outside a TTY; do not imply keyboard interactivity where none exists.
3. **Reuse the existing render pipeline.** Build on `AppView` + `render.zig` instead of inventing a second UI model.
4. **Preserve stable public simulator/report contracts.** Any change stays inside the TUI surface and docs unless an additive CLI flag is required.
5. **Prefer stdlib-only, reviewable changes.** No new dependency unless Architect finds a hard blocker.

---

## 3) Decision Drivers
1. **User-facing mismatch:** current docs and `--stdin` ingestion suggest pipeability, but `Terminal.init()` rejects non-TTY use.
2. **Leverage existing architecture:** the renderer already produces full-frame output from loaded app state; a second backend is lower risk than a second UI.
3. **Verification/review cost:** a bounded snapshot mode is much easier to test deterministically than PTY emulation or a remote interactive transport.

---

## 4) Viable Options

### Option A — Recommended: explicit non-interactive snapshot mode backed by the existing renderer
Add an explicit TUI mode/flag for rendering one frame without terminal init, plus configurable dimensions and an output format that works without a TTY.

**Pros**
- Fits current code shape: bootstrap already loads reports before terminal init.
- Keeps `terminal.zig` TTY-only and easier to reason about.
- Deterministic and easy to test with golden/substr assertions.
- Solves piping/file capture/CI/docs examples cleanly.

**Cons**
- Adds CLI surface area.
- Non-interactive mode cannot support picker navigation or playback controls.
- May require `render.zig` to expose a plain-text variant instead of ANSI-only output.

### Option B — PTY-backed compatibility layer / pseudo-terminal wrapper
Hide the TTY requirement behind a PTY shim or recorder so the existing interactive loop can run unchanged.

**Pros**
- Preserves more of the current loop semantics.
- Could enable richer demos/recordings later.

**Cons**
- Higher complexity and platform sensitivity.
- Harder to test deterministically in-repo.
- Pushes the repo toward transport/process concerns instead of a bounded TUI follow-up.
- More likely to require new dependencies or fragile shell integration.

### Option C — Auto-fallback to one best-effort frame whenever stdout is not a TTY
Keep the CLI shape unchanged and silently render a static frame when interactive terminal features are unavailable.

**Pros**
- Lowest user-facing CLI friction.
- Lets existing `--stdin` example start working without extra flags.

**Cons**
- Ambiguous behavior: same command means interactive in one environment and static in another.
- Harder to document honestly for picker/no-input cases.
- Increases risk of surprising automation output and brittle future semantics.

---

## 5) Recommended approach
Choose **Option A**.

### Recommendation
Add an **explicit snapshot-style non-TTY rendering path** while preserving the current TTY loop as the default interactive path. The presentation contract should be explicit: `interactive` vs `snapshot`, separate from the existing input-source selection.

### Frozen v1 contract
- Add `--snapshot` to request one-shot non-interactive rendering explicitly.
- Add `--width <cols>` and `--height <rows>` as snapshot-only flags; default to `120x40`.
- Snapshot v1 renders **plain text only**; ANSI remains interactive-only in this milestone.
- `--stdin` becomes **snapshot-only** in the TUI: supported as `... --stdin --snapshot`, invalid otherwise.
- Remove the old implicit “non-TTY stdin in picker mode auto-loads a report” behavior; non-TTY invocation without `--snapshot` becomes a clear error.

### Working design direction
- Keep `src/tui/terminal.zig` as the TTY-only backend.
- Extend `src/tui/args.zig` with additive presentation flags for a one-frame render path, modeled as presentation config orthogonal to source selection: `--snapshot`, `--width`, and `--height`.
- In `src/tui/root.zig`, split the current `run()` flow into:
  1. **interactive session path**: existing terminal init / poll / redraw loop
  2. **snapshot path**: bootstrap app state, render exactly one frame, write to stdout, exit
- Keep picker and help navigation interactive-only. Snapshot v1 requires a resolved report/simulation source and renders the explorer view only; if no TTY and no explicit snapshot source is available, fail clearly rather than faking picker behavior.
- Use `120x40` as the default snapshot size unless explicit dimensions are provided, matching the existing fallback in `Terminal.size()`.
- Add a snapshot-specific copy rule: non-interactive output must not advertise keyboard hints or other interactive controls.
- Freeze snapshot v1 to plain-text output for this milestone, leaving ANSI snapshot output for a later follow-up if ever needed.

This gives the repo a pipeable, CI-friendly, documentation-friendly TUI surface without turning the TUI into a remote-interaction project.

---

## 6) Implementation plan

### Concrete codebase touchpoints
- `src/tui/args.zig`
  - add additive CLI parsing for `--snapshot`, `--width`, and `--height`
  - keep current source-selection rules stable
  - add parsing tests for valid/invalid combinations
- `src/tui/root.zig`
  - separate interactive terminal loop from one-shot frame rendering
  - add a small presentation/config struct so source selection and presentation are not conflated
  - retire the current implicit non-TTY stdin bootstrap behavior in favor of the explicit `--stdin --snapshot` contract
  - gate picker-only behavior behind real-TTY availability
  - add tests around non-TTY render path / default view selection where feasible
- `src/tui/render.zig`
  - expose the rendering primitive needed by snapshot output
  - remove or replace interactive-only key hints when rendering snapshot output
  - add a plain-text frame emission path for snapshot mode alongside the existing ANSI interactive path
  - update the in-app picker copy that currently implies piped `--stdin` TUI usage
  - add focused render tests on width/height and non-ANSI stability if format branching is introduced
- `src/tui/main.zig`
  - replace the blanket `NotATerminal` failure path with branching that still errors for unsupported interactive usage but allows explicit snapshot usage
  - update usage text
- `README.md`
  - document real-TTY interactive usage vs non-TTY snapshot usage
  - add/clarify examples only after the final snapshot flag contract is frozen
- `build.zig`
  - likely no structural change, but verify the TUI test target still covers the new tests

### Phase 1 — CLI and mode split
**Goal:** define explicit non-TTY behavior without changing report contracts.

**Acceptance criteria**
- The TUI has an explicit one-shot non-interactive mode expressed separately from source-selection mode via `--snapshot`.
- Existing interactive commands still require/use a real TTY.
- `--stdin` is valid only with `--snapshot`; non-TTY invocation without `--snapshot` fails clearly.
- `--width` and `--height` are valid only with `--snapshot`; default size is `120x40`.
- Invalid combinations (for example snapshot mode with no source, or interactive mode with `--stdin`) fail clearly.

### Phase 2 — Render backend reuse for snapshot output
**Goal:** render one frame from existing `AppView` state without terminal init.

**Acceptance criteria**
- A report-loaded explorer view can render once and exit without calling `Terminal.init()`.
- Snapshot v1 renders explorer/report-backed state only, not the interactive picker or help flows by default.
- Non-TTY snapshot output is deterministic for fixed width/height and input, with `120x40` as the default size.
- Snapshot output is plain text and does not advertise unavailable keyboard controls.
- The interactive loop still uses the current redraw/poll model unchanged in spirit.

### Phase 3 — Docs and regression proof
**Goal:** align docs/examples/tests with the new contract.

**Acceptance criteria**
- README and in-app copy distinguish interactive TTY usage from non-TTY snapshot usage.
- Tests cover CLI parsing, snapshot rendering, interactive-regression safety, and copy correctness for snapshot mode.
- The repo keeps public simulator/report contracts unchanged.

### Verification
Minimum execution-time proof for implementation handoff:
- `zig build test --summary all`
- TUI arg-parsing tests for new flags and invalid combinations
- at least one snapshot-mode test asserting deterministic output for fixed dimensions/input
- smoke: interactive TTY path still builds and routes through terminal init in normal mode
- smoke: `zig build tui -- --input docs/examples/exports/multicore-contention-fcfs.report.json --snapshot` works without a TTY
- smoke: `zig build run -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs --format json | zig build tui -- --stdin --snapshot` works without a TTY
- explicit test/assertion that snapshot execution does not call `Terminal.init()`
- command/copy audit so documented TUI pipeline examples and in-app picker text match real behavior

---

## 7) ADR

### Decision
Introduce an explicit, non-interactive, non-TTY snapshot path for the TUI while preserving the current TTY-only interactive explorer.

### Drivers
- `Terminal.init()` currently rejects the same pipe-oriented TUI ingestion shape the repo already documents.
- The renderer already knows how to build a full frame from app state.
- A bounded snapshot path is the smallest change that closes the usability gap without expanding scope into transport/process orchestration.

### Alternatives considered
- PTY-backed compatibility wrapper.
- Silent auto-fallback from interactive mode to static rendering.

### Why chosen
It best matches current repo structure, keeps behavior explicit, preserves the interactive experience, and yields the cleanest deterministic test surface.

### Consequences
- The TUI will now have two presentation paths: interactive TTY and one-shot non-TTY snapshot.
- Picker/help/navigation semantics remain intentionally limited to real TTY sessions.
- Snapshot output needs its own copy discipline so users do not see impossible keyboard guidance.
- The implementation must make an explicit choice about plain-vs-ANSI snapshot output rather than treating it as incidental.

### Follow-ups
- If later work wants ANSI snapshot output, recordings, or demos, treat that as a separate milestone rather than stretching this change.
- Executor handoff should preserve the frozen v1 contract unless Architect/Critic explicitly reopen it.

---

## 8) Execution staffing guidance

### Available agent types roster
- `planner`
- `architect`
- `critic`
- `executor`
- `debugger`
- `test-engineer`
- `verifier`
- `writer`
- `code-reviewer`
- `build-fixer`
- `explore`

### Suggested reasoning by lane
- `executor` — **high** for `src/tui/root.zig` flow split and renderer reuse
- `architect` — **high** for final CLI/mode boundary review
- `test-engineer` — **medium** for deterministic snapshot test shape and regression coverage
- `writer` — **medium** for README/help/usage tightening
- `verifier` — **high** for final evidence pass
- `debugger` / `build-fixer` — **medium/high** only if implementation hits Zig compile/test failures

### Ralph staffing guidance
Use `ralph` if one owner should land the feature sequentially with frequent verification.

**Recommended lane**
1. `executor` owns `src/tui/args.zig`, `src/tui/root.zig`, `src/tui/main.zig`, and any minimal `src/tui/render.zig` adjustment.
2. `test-engineer` (or the same owner) adds/strengthens TUI tests.
3. `writer` updates `README.md` once behavior is proven.
4. `verifier` runs the final evidence pass.

**Launch hint**
- `$ralph implement docs/roadmap/prd-m15-non-tty-tui-surface.md with docs/roadmap/test-spec-m15-non-tty-tui-surface.md`

### Team staffing guidance
Use `$team` if you want parallel lanes with a clear shared contract.

**Suggested split**
- **Lane 1 — core implementation (`executor`, high):** `src/tui/args.zig`, `src/tui/root.zig`, `src/tui/main.zig`
- **Lane 2 — render/test support (`test-engineer`, medium):** `src/tui/render.zig` tests / snapshot assertions / regression coverage
- **Lane 3 — docs/verification (`writer` then `verifier`, medium/high):** `README.md`, usage strings, command audit, final verification capture

**Launch hints**
- `$team implement docs/roadmap/prd-m15-non-tty-tui-surface.md with verification from docs/roadmap/test-spec-m15-non-tty-tui-surface.md`
- If using OMX CLI directly: `omx team start ...` with one executor lane, one test lane, and one verification/docs lane

---

## 9) Explicit team verification path
1. **Contract check first**
   - confirm the chosen CLI flags and non-TTY semantics match this PRD before editing code
2. **Lane-local proof**
   - implementation lane shows the mode split and terminal-init gating
   - test lane proves deterministic snapshot output and invalid-combination coverage
   - docs lane updates README/help text to match the final contract
3. **Integrated verification**
   - run `zig build test --summary all`
   - run one documented interactive TTY command manually if available
   - run one non-TTY snapshot smoke command using `--input` or `--stdin`
4. **Final verifier gate**
   - verify no simulator/report contract changed
   - verify picker behavior is still explicitly TTY-only
   - verify documented commands match actual implemented flags/output

## Compact RALPLAN-DR summary
- **Principles:** preserve TTY explorer; keep non-TTY mode explicit; keep presentation separate from source selection; reuse render pipeline; stay stdlib-only.
- **Drivers:** fix the pipeability mismatch; exploit existing renderer/bootstrap split; choose the easiest deterministic test surface.
- **Options:** explicit snapshot mode (recommended, frozen as `--snapshot` + plain text) vs PTY wrapper vs silent auto-fallback.
