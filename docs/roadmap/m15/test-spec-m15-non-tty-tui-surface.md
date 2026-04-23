# Test Spec — M15 follow-up: non-TTY TUI surface

## Status
Revised planner draft — architect + critic feedback incorporated on 2026-04-21

## Scope under test
- additive TUI presentation controls kept separate from source selection
- interactive TTY path remains intact
- one-shot non-TTY snapshot rendering path
- snapshot-specific copy / in-app text alignment
- README/help usage alignment

## Required verification
1. **CLI contract**
   - `--snapshot`, `--width`, and `--height` parse correctly
   - presentation config stays orthogonal to source-selection mode
   - `--stdin` is accepted only with `--snapshot`
   - `--width` / `--height` are accepted only with `--snapshot`
   - invalid combinations are rejected clearly
   - existing interactive invocations remain valid
2. **Interactive regression safety**
   - normal TTY mode still routes through terminal init / event loop
   - picker/help remain TTY-only
   - the old implicit non-TTY stdin bootstrap path is removed or otherwise proven unreachable without `--snapshot`
3. **Snapshot determinism**
   - fixed input + fixed dimensions => stable plain-text output
   - report-backed explorer frame renders without terminal init
   - snapshot output omits or replaces interactive-only keyboard hints
4. **Docs truthfulness**
   - README/help distinguish interactive vs non-interactive TUI usage
   - in-app picker/source text matches the implemented contract exactly
   - any pipe example matches the implemented contract exactly

## Minimum checks
- `zig build test --summary all`
- focused `src/tui/args.zig` tests for new flags and invalid combinations
- focused TUI render/root test asserting deterministic snapshot output for a fixed report and dimensions
- explicit assertion that snapshot execution does not call `Terminal.init()`
- focused copy test or assertion covering snapshot-specific hint removal/replacement
- non-TTY smoke: `zig build tui -- --input docs/examples/exports/multicore-contention-fcfs.report.json --snapshot`
- non-TTY smoke: `zig build run -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs --format json | zig build tui -- --stdin --snapshot`
- docs/usage audit for the TUI examples in `README.md`, usage text, and in-app picker copy

## Non-goals for this milestone
- PTY emulation
- browser/remote UI
- interactive keyboard input without a real terminal
