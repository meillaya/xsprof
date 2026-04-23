# RALPLAN: TUI domain-mode refactor for bounded M19 + M20 integration

## Scope and grounding

Goal: integrate M19 and M20 into the existing TUI by first refactoring the TUI shell around an explicit domain/data mode split, then adding a distinct observability lane for M19 and M20. This must preserve the simulator-first lane, keep `picker` / `explorer` / `drawer` / `diff` simulator-only, and avoid widening `zig-scheduler/report` or `src/analysis/*`.

Evidence used:
- `src/tui/root.zig` currently assumes a report-centered app state and many control flows branch on `app.report() != null`.
- `src/tui/render.zig` header/status/help/picker/explorer/drawer/diff rendering is report-first and assumes simulator semantics.
- `src/tui/args.zig` only models picker/report/simulator sources today.
- M19 already exposes `ObservabilitySummary` via `src/observability/root.zig`.
- M20 already exposes `ComparisonSummary` via `src/observability/comparison.zig`.
- Boundary docs/tests explicitly reject widening `zig-scheduler/report` and `src/analysis/*`.

## RALPLAN-DR short summary

### Principles
1. Refactor the TUI shell around explicit `DomainMode` / `DataMode` first; do not bolt observability onto report-centric control flow.
2. Keep simulator views simulator-only: `picker`, `explorer`, `drawer`, and `diff` remain report-lane surfaces.
3. Make observability a distinct top-level lane inside the same binary/shell, with dedicated M19/M20 views and copy guardrails.
4. Preserve the observability boundary in both types and wording: observability is bounded, observability-only, and non-fidelity.
5. Reuse shared shell/layout/status/help infrastructure where semantics truly match; do not reuse simulator semantics where they mislead.

### Decision drivers (top 3)
1. Remove hidden report-present assumptions before integrating a second domain.
2. Preserve hard product/contract boundaries: no report-schema widening, no fake replay/policy-diff semantics for observability.
3. Keep the change small but structurally correct so future TUI growth does not reintroduce simulator-only assumptions.

### Viable options

#### Option A — Domain-mode refactor first, then add distinct observability lane (recommended)
- Shape: introduce first-class `DomainMode` / `DataMode`, audit report invariants, then add explicit M19/M20 views and inputs.
- Pros:
  - Fixes the real architectural constraint instead of layering exceptions.
  - Makes simulator-only vs observability-only behavior explicit.
  - Best fit for one binary / one shell with distinct lanes.
- Cons:
  - Slightly larger first diff than direct additive wiring.
  - Requires careful audit of existing report assumptions.

#### Option B — Add observability loaders/views inside the current report-centric shell
- Shape: keep current shell assumptions and thread optional M19/M20 state through special cases.
- Pros:
  - Lower short-term coding overhead.
  - Faster first render path.
- Cons:
  - Leaves hidden `report != null` invariants in place.
  - Higher regression risk in help/escape/snapshot/status routing.
  - Harder to keep observability as a clean separate lane.

#### Option C — Separate observability TUI binary
- Shape: keep current TUI untouched and ship a second dedicated TUI entrypoint.
- Pros:
  - Strongest semantic separation.
  - Lowest regression risk to simulator views.
- Cons:
  - Violates the preferred one-shell integration direction.
  - Splits UX/docs and weakens the “existing TUI” requirement.

## Recommended architecture

**Execution recommendation: one binary / one shell, distinct observability lane.**

Refactor the TUI shell so `src/tui/root.zig` and `src/tui/render.zig` both dispatch first on a top-level domain/data concept, then on domain-specific views.

### Proposed mode split
- `DomainMode`:
  - `simulator`
  - `observability`
- `DataMode` / source family:
  - simulator picker
  - simulator report input
  - simulator scenario input
  - observability M19 summary input
  - observability M20 comparison input

This mode split should become the first routing decision in bootstrap, snapshot rendering, event handling, and rendering.

### Simulator lane stays unchanged in meaning
- `picker`, `explorer`, `drawer`, `diff`, and current compare behavior remain simulator/report-lane only.
- Observability does **not** appear as picker entries.
- Observability does **not** reuse simulator diff framing.

### Observability lane is explicit and separate
- Add dedicated observability views, e.g.:
  - `observability_summary` (M19)
  - `observability_comparison` (M20)
- These live under the same shell, header/status/help system, but render observability-specific panes and copy.

### Entry contract
- Add explicit flags in `src/tui/args.zig` for M19 and M20 entry, with explicit choice required:
  - M19 flag: summary lane, optional manifest path override, default manifest only when the M19 flag is explicitly selected.
  - M20 flag: comparison lane, optional pairing path override, default pairing only when the M20 flag is explicitly selected.
- Reject mixed simulator/report/observability combinations.
- If CLI usage/help text changes, update `src/main.zig` and `src/tui/main.zig` in parity.

### Copy guardrails
Required wording in observability lane/help/docs/status as appropriate:
- `observability-only`
- `bounded`
- `non-fidelity` or equivalent explicit non-fidelity disclaimer

Forbidden framing in observability views:
- report-schema framing
- replay framing
- policy-diff framing
- wording that implies Linux truth / validation / calibration / faithful replay

### Report-invariant audit sites that must be explicitly reviewed
In `src/tui/root.zig` and `src/tui/render.zig`, audit and refactor each current `Report`-present assumption site before wiring observability views:
1. bootstrap
2. snapshot path
3. `?` help routing
4. `esc` routing
5. picker toggle
6. diff toggle
7. header rendering
8. status-bar rendering
9. help rendering
10. background/fallback rendering paths

## Tightened implementation steps

1. **Refactor TUI shell around `DomainMode` / `DataMode`**
   - Files: `src/tui/root.zig`, `src/tui/render.zig`
   - Introduce first-class domain/data mode state in app + app view.
   - Audit and replace report-present assumptions at the listed invariant sites.
   - Acceptance criteria:
     - Simulator lane behavior remains unchanged.
     - Shell can render/help/navigate without assuming a report exists.

2. **Extend CLI/input contract for explicit observability entry**
   - Files: `src/tui/args.zig`, `src/main.zig`, `src/tui/main.zig` if present/used for usage parity
   - Add explicit M19/M20 flags and validation.
   - Reject mixed source families.
   - Allow approved default manifest/pairing only when their respective observability flag is chosen.
   - Acceptance criteria:
     - New args are explicit and mutually exclusive with simulator/report sources.
     - Usage text accurately describes the distinct observability lane.

3. **Add observability bootstrap/state loaders as a separate lane**
   - Files: `src/tui/root.zig`
   - Add owned observability state parallel to simulator report state.
   - Implement M19/M20 loaders and deinit/reset semantics.
   - Acceptance criteria:
     - App can enter M19 or M20 directly.
     - Switching/reset paths do not leak simulator semantics into observability state or vice versa.

4. **Add dedicated observability render views**
   - Files: `src/tui/render.zig`
   - Implement M19 and M20 views using shared shell chrome where safe.
   - Keep simulator-only views untouched in semantics.
   - Bake required/forbidden wording guardrails into titles, help, status, and pane copy.
   - Acceptance criteria:
     - M19 shows approved tuple/fixture/count/span/cardinality/boundary details.
     - M20 shows pairing/metric/caveat/bounded non-fidelity details.
     - No observability screen looks like a report explorer or policy diff.

5. **Update docs and proof surfaces**
   - Files: `README.md`, `docs/project-architecture-and-status.md`, `docs/m19-curated-linux-observability.md`, `docs/m20-simulator-to-trace-comparison.md`, tests
   - Document one binary / one shell with a distinct observability lane.
   - Add snapshot/boundary wording proof.
   - Acceptance criteria:
     - Docs consistently describe observability as explicit, bounded, observability-only integration.

## Concrete verification matrix

### Unit checks
- `src/tui/args.zig`
  - valid explicit M19 flag with default manifest
  - valid explicit M19 flag with manifest override
  - valid explicit M20 flag with default pairing
  - valid explicit M20 flag with pairing override
  - invalid mixed combinations with `--input`, `--stdin`, `--scenario`, `--scenario-file`, `--policy`
  - invalid implicit defaulting without the relevant observability flag
- `src/tui/root.zig`
  - mode/state reset helpers clear incompatible lane state
  - help/escape/picker/diff routing follows `DomainMode`

### Integration checks
- bootstrap into simulator report lane still lands in explorer
- bootstrap into simulator scenario lane still lands in explorer
- bootstrap into M19 lane lands in observability summary view
- bootstrap into M20 lane lands in observability comparison view
- snapshot path works for each explicit lane
- simulator diff toggle stays unavailable outside simulator lane

### Snapshot/render checks
- deterministic large-tier M19 render
- deterministic compact-tier M19 render
- deterministic large-tier M20 render
- deterministic compact-tier M20 render
- simulator snapshot regressions still pass unchanged
- too-small fallback remains deterministic for both domains

### Boundary/copy checks
- no new fields added to `src/contract/report.zig`, `src/analysis/model.zig`, or `src/analysis/root.zig`
- TUI copy contains required observability wording (`observability-only`, `bounded`, non-fidelity disclaimer)
- TUI observability copy omits forbidden report/replay/policy-diff framing
- identity/boundary docs continue to state no widening of report/analysis surfaces

### Full regression checks
- targeted TUI tests
- observability tests
- identity/boundary tests
- full `zig build test`

## Pre-mortem

1. **Failure: observability is wired as a special case inside report-only control flow**
   - Symptom: `?`, `esc`, snapshot, or status bar break because they still assume `app.report() != null`.
   - Prevention: do the domain-mode refactor first and audit every invariant site explicitly.

2. **Failure: observability screens inherit simulator semantics by accident**
   - Symptom: M20 appears as a policy diff, or M19 looks like replay/explorer state.
   - Prevention: keep simulator views simulator-only; create dedicated observability views with copy guards.

3. **Failure: CLI contract silently defaults into observability inputs**
   - Symptom: users get M19/M20 accidentally or mixed-source validation becomes ambiguous.
   - Prevention: explicit M19/M20 flags required; defaults only activate after explicit lane selection.

4. **Failure: boundary erosion through convenience type reuse**
   - Symptom: report/analysis contract gains observability fields or adapters that imply equivalence.
   - Prevention: keep observability state/types parallel and enforce boundary tests.

## ADR-style mini section

### Decision
Refactor the TUI around first-class `DomainMode` / `DataMode` and integrate M19/M20 as a distinct observability lane within the same binary/shell, while preserving simulator-only picker/explorer/drawer/diff semantics.

### Drivers
- Hidden report-present assumptions must be removed before multi-domain TUI support is safe.
- Observability requires distinct semantics and copy guardrails.
- One binary / one shell is preferable to a second TUI surface, if lanes remain explicit.

### Alternatives considered
- **Additive loader/view wiring only**: rejected because it leaves report-centric shell assumptions in place.
- **Synthetic reuse of picker/diff/report semantics**: rejected because it weakens the boundary and misframes observability.
- **Separate binary**: rejected for now because one shell with distinct lanes is the better product fit.

### Consequences
- First milestone is a shell/domain-mode refactor, not just new loaders.
- Existing simulator views stay cleaner because domain routing becomes explicit.
- Verification scope must include copy semantics and control-flow routing, not just data loading.

### Follow-ups
- If the render file grows too large, split simulator-lane and observability-lane rendering into submodules after the domain split lands.
- After launch, consider whether the shell needs an explicit domain switch affordance beyond CLI entry flags.
