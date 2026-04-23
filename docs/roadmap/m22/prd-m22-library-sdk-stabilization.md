# PRD — M22 library / SDK stabilization for embedders

## Status
Draft for consensus review on 2026-04-22

## 1) Task framing and evidence grounding

### Framing
M22 should turn the current broad, internal-facing Zig module surface into a
**small, documented, versioned embedder contract** without changing the repo's
truthful identity: `zig-scheduler` remains a simulator-first teaching and
experimentation project whose library branch is optional and intentionally
narrow.

This milestone is about **public library boundaries and proof of embedding**,
not about browser delivery, service/product scope, TUI teaching polish, or
packaging/distribution.

### Grounding from repo evidence
- `.omx/context/m22-library-sdk-stabilization-20260422T174800Z.md` defines M22
  as the optional library/SDK stabilization branch and calls out the current
  surface as too broad for a trustworthy public promise.
- `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md` defines M22 as:
  documented/versioned public library boundaries plus example embedding usage.
- `docs/roadmap/test-spec-multi-horizon-zig-scheduler-roadmap.md` requires:
  library/API tests, example embedding smoke, and compatibility/docs audit.
- `src/lib.zig` currently does only `pub usingnamespace @import("root.zig")`.
  That means **every re-export in `src/root.zig` is effectively public** today.
- `src/root.zig` currently re-exports broad surfaces: `cli`, `engine`,
  `metrics`, `policies.*`, `scenario`, `scenario_packs`, `trace`, `property`,
  `observability`, `observability_comparison`, plus many raw types/functions.
- `build.zig` already defines a `zig_scheduler` module, but it is rooted at
  `src/root.zig` and is currently consumed by internal tools (`sim_cli_app`,
  `bench`, `report_pipeline`, `tui`) rather than a deliberately stabilized
  external contract.
- Internal consumers show the current module is used for **internal breadth**,
  not just embedding:
  - `src/sim_cli_app.zig` uses `scheduler.cli.*`, scenario loaders, and
    `simulate`.
  - `src/bench/root.zig` and `src/report_pipeline/root.zig` use scenario
    loading, simulation, and JSON report helpers.
  - `src/tui/*` imports observability surfaces, CLI parsing helpers, and policy
    enums from the same module.
- `README.md` and `docs/project-architecture-and-status.md` still define the
  repo as a deterministic simulator, not a product/runtime/service. M22 must
  preserve that wording.
- The current public export contract for reports already exists in
  `src/contract/report.zig`, which is a good precedent for **versioned public
  boundaries**.

### Public-surface inventory implied by the current root
Today the effective public surface falls into these categories:
1. **Core simulation model** — `ScenarioOwned`, `TaskSpec`, `TaskPhase`,
   `GroupSpec`, `PolicyKind`, `SimulationResult`, metrics/trace/result types.
2. **Scenario I/O helpers** — parse/load helpers and built-in scenario lookup.
3. **Simulation execution** — `simulate`, `engine`, `metrics`, `trace`.
4. **Report/export helpers** — `cli.report`, `cli.output`, report contract
   constants.
5. **Internal-only tool surfaces accidentally public** — CLI arg parsing,
   TUI/observability-adjacent helpers, policy module internals, property test
   helpers, scenario pack registry.

M22 should keep (1)-(4) only where truly needed for embedders, and should make
(5) clearly non-public.

### Scope boundary
M22 may produce:
- a documented stable embedder module boundary
- an exact symbol-inventory and compatibility-promise document for the library API
- a narrow public namespace for model + simulation + export helpers
- one or two example embedding programs/tests proving the boundary works
- build/test wiring that compiles/runs the embedding proof path

M22 must not produce:
- browser/WASM support
- service/daemon/automation scope
- packaging/distribution/courseware breadth (M23)
- TUI-first teaching-polish work (M21)
- public commitment to all current `src/root.zig` exports
- a promise that policy internals, observability, analysis, bench, or report
  pipeline modules are stable embeddable APIs

---

## 2) RALPLAN-DR short summary

### Principles
1. **Simulator-first identity stays truthful.** The SDK is an optional way to
   embed the simulator, not a re-charter into a broader production platform.
2. **Promise less, prove more.** Stabilize only the smallest API surface needed
   for embedding examples and downstream tool use.
3. **Separate public contract from internal convenience.** Internal tools may
   keep broader access, but embedders should get a curated facade.
4. **Version the boundary explicitly.** The stable library promise must be
   documented and machine-checkable enough to guard against accidental drift.
5. **Prefer proof through compile/run tests.** Embedding should be demonstrated
   by real consumer-shaped code, not prose alone.

### Decision drivers (top 3)
1. **Avoid over-commitment.** The current `pub usingnamespace` pattern makes it
   too easy to accidentally freeze internal modules as public API.
2. **Keep optional-branch scope tight.** M22 should not absorb M21 docs polish
   or M23 packaging/distribution responsibilities.
3. **Preserve future simulator evolution.** The stable contract must leave room
   for internal engine/policy/docs growth without repeated breaking API churn.

### Viable options

#### Option A — Document the current broad `src/root.zig` surface as the SDK
Treat the existing `zig_scheduler` module as the stable API and document its
current exports.

**Pros**
- smallest immediate implementation diff
- minimal build rewiring
- internal tools continue unchanged

**Cons**
- freezes too much: CLI, policy internals, observability, property helpers,
  scenario-pack details
- makes future cleanup/refactors much harder
- violates the “do not over-commit” boundary

#### Option B — Recommended: keep `zig_scheduler` as the curated public module and add a separate internal module/root
Keep `zig_scheduler` as the deliberate public embedder boundary rooted at the
curated facade, and introduce a separate clearly named internal module/root for
repo-owned tools. Document only the curated `zig_scheduler` surface as stable.

**Pros**
- cleanly separates public contract from internal breadth
- lets internal tools keep using broader surfaces without widening the public
  promise
- best fit for a versioned compatibility policy and embedder examples

**Cons**
- requires build rewiring and likely some internal import churn
- needs explicit decisions on which types/helpers stay public

#### Option C — Add a new high-level façade object and hide most raw types
Create a wrapper API that exposes only a very small “run scenario / get report”
entrypoint and hides most current model/result types.

**Pros**
- tightest long-term public surface
- strongest insulation from engine refactors

**Cons**
- larger design jump than current milestone needs
- risks unnecessary abstraction over a codebase that already has useful value
  types
- could make embedding examples feel artificial relative to current repo usage

### Recommended direction
**Option B wins.** It is the best balance between discipline and practicality:
- `zig_scheduler` remains the curated public module for embedders
- a separate internal module/root serves repo-owned tools
- explicit public/non-public split
- room to stabilize only the categories that embedders actually need

---

## 3) Recommended M22 scope (tight and precise)

### Core milestone decision
M22 should stabilize a **narrow embedder API** around four categories only:

1. **Model types needed to describe inputs and inspect results**
2. **Scenario ingestion helpers**
3. **Simulation execution**
4. **Versioned report/export helpers**

Everything else remains internal or explicitly unsupported for public stability.

### Recommended public API categories

#### A. Stable model namespace
Document and export only the model/value types embedders plausibly need. Split
them into **shape-stable enums/value helpers** versus **allocator-owning raw
structs with narrower promises**.

**Shape-stable / directly documented public items**
- `PolicyKind`
- `TaskSpec`
- `TaskPhase`
- `TaskPhaseKind`
- `GroupSpec`
- `DomainSpec` / `CoreId` if topology input is retained in stable examples
- `TaskMetrics`
- `AggregateMetrics`
- `TraceEntry`
- `TraceEventKind`
- `ValidationError`
- public constants such as task-weight bounds when they affect valid input

**Allocator-owning raw structs with narrower compatibility promises**
- `ScenarioOwned`
- `SimulationResult`

For M22, these raw types are **usable public workflow types**, but M22 should
not promise that every field, field order/layout, or all helper methods are
frozen forever. The stable promise should instead cover:
- construction/ownership workflow needed by documented examples
- documented fields/access patterns used by embedder examples/tests
- deinit/ownership expectations that embedders must follow

This keeps the API practical without freezing the full internal shape of every
allocator-owning struct.

**Intent:** embedders can build or inspect scenarios/results without importing
engine/policy internals, while the repo avoids overcommitting every raw field
and layout detail.

#### B. Stable scenario-ingestion namespace
Keep only the ingestion helpers needed for embedder convenience:
- `parseScenarioText`
- `parseScenario`
- `loadScenarioFile`
- `freeScenario` only if ownership ergonomics require it alongside parser APIs

**Not recommended as stable for M22 unless specifically justified:**
- built-in scenario registry lookup
- scenario pack registry metadata
- teaching/demo-specific scenario helpers

Those are useful for repo demos and TUI flows, but they are not core embedder
contract.

#### C. Stable simulation namespace
Expose a narrow execution entrypoint:
- `simulate`

**Do not** make the raw `engine`, `metrics`, or `trace` modules themselves part
of the stable public boundary. Embedders should depend on the stable function
and result/model types, not internal module layout.

#### D. Stable report/export namespace
Stabilize report/export as a **public namespace move or re-export** of the
existing report helpers, not as a redesign of the report model. The goal is to
let embedders reach the already useful report/export path without going through
CLI-owned naming.

Likely stable exports:
- contract constants from `src/contract/report.zig`
- contract checker (`assertSupportedContract`)
- public event-kind accessor
- `SourceInfo` / source-kind type
- `SimulationReport`
- JSON serialization helper(s) for the versioned report

**Important:** `writeJsonReport` and report construction should be moved or
re-exported into the public namespace from the existing CLI-owned code, with CLI
becoming a consumer/re-exporter where helpful. This is a namespace split, not a
new report architecture.

### Public API categories that should remain explicitly unstable / internal
Do **not** stabilize these in M22:
- `cli` arg parsing and CLI-oriented option types
- `tui/*`
- `analysis/*`
- `bench/*`
- `report_pipeline/*`
- `observability/*`
- `property` / generator helpers
- concrete `policies/*` modules and policy-extension internals
- scenario-pack registry/builtin-curation APIs unless later justified

### Recommended compatibility-promise shape
M22 should document a **two-level compatibility model**:

#### Stable in M22
Only the symbols explicitly exported from the curated public facade and listed in
the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution) (or equivalent) are covered by compatibility promises.

Promise shape:
- additive exports are allowed without breaking the API level
- removal/rename/semantic break of documented public symbols requires an API
  level bump and docs update
- report JSON remains governed by its own existing schema/version contract
- undocumented exports or internal modules carry **no stability promise**

#### Unstable / internal in M22
Anything outside the curated public module boundary can change without embedder
compatibility guarantees.

### Versioning recommendation
Because M22 is **library stabilization**, not M23 packaging, keep versioning
modest and local:
- add a public `sdk_api_version` (or similarly named constant) for the embedder
  surface
- keep `zig-scheduler/report` schema version separate
- document that the embedder API version and the report schema version are
  related but independent contracts

This keeps M22 honest: API boundary stabilization first, packaging/distribution
semantics later.

### Embedding-example proof path
The proof path should show a real embedder using only the curated public API:
1. import the public module from `build.zig`
2. build or parse a scenario without using CLI parsing
3. call `simulate`
4. inspect one or two stable result fields
5. serialize a versioned report through the stable report namespace

**Preferred example shape:** an inline-code or fixture-backed Zig example under a
new `examples/embedding/` or `src/examples/` path, compiled and run by build
steps/tests.

**Better than a CLI wrapper example:** it proves library embedding rather than
just shelling the simulator through existing app code.

---

## 4) Concrete implementation steps with likely files

### Step 1 — Freeze the public-vs-internal API decision in docs first
**Goal:** define exactly what M22 will and will not promise before changing
exports.

**Likely files**
- the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution) (new, exact documented stable-subset inventory)
- `README.md`
- `docs/project-architecture-and-status.md`
- `docs/roadmap/m22/prd-m22-library-sdk-stabilization.md`
- `docs/roadmap/m22/test-spec-m22-library-sdk-stabilization.md`

**Work**
- write the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution) as the exact documented stable-subset inventory, plus explicit public API categories, non-goals, compatibility promise, and example-proof path
- update README/project-status to describe the library branch as optional and
  intentionally narrow
- explicitly state that simulator-first identity still governs the project

**Acceptance criteria**
- the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution) names the exact stable public symbols/namespaces and the exact unstable categories
- docs clearly distinguish M22 from M21 and M23
- compatibility promise language is precise enough to test/audit later

### Step 2 — Keep `zig_scheduler` public and add an explicit internal module/root
**Goal:** stop treating `src/root.zig` breadth as the public contract while
explicitly preserving `zig_scheduler` as the curated public module name.

**Likely files**
- `src/lib.zig`
- `src/root.zig` or a new internal root/module file
- `build.zig`
- possibly a new internal/public split file such as:
  - `src/sdk/root.zig` or
  - `src/internal_root.zig`

**Recommended implementation shape**
- keep `zig_scheduler` rooted at the curated public facade (`src/lib.zig`)
- introduce a separate internal module/root (for example `zig_scheduler_internal`)
  that preserves the broader aggregator needed by repo-owned tools
- update `build.zig` so repo-owned tools import the internal module by default whenever they need anything outside the curated facade; only the embedding example and dedicated library contract tests use `zig_scheduler` alone

**Work**
- replace `pub usingnamespace @import("root.zig")` with explicit public exports
- create or rename an internal root/module for the broad internal surface
- retarget repo-owned tools to that internal module where appropriate
- document the fixed module-name rule: `zig_scheduler` is public, repo-owned tools use the separate internal module by default if they need anything outside the curated facade; only the embedding example and dedicated library contract tests use `zig_scheduler` alone

**Acceptance criteria**
- `zig_scheduler` no longer implicitly exposes the whole internal root
- repo-owned tools still compile through the internal module without expanding
  the public promise
- build wiring makes the public/internal split obvious to future contributors
- the internal-consumer routing rule is explicit and enforceable

### Step 3 — Re-export report/export under the public namespace without redesign
**Goal:** make report/export reachable as a true library concern without redesigning
existing report code.

**Likely files**
- `src/cli/report.zig`
- `src/cli/output.zig`
- `src/cli/root.zig`
- `src/contract/report.zig`
- new public namespace files such as:
  - `src/sdk/report.zig`
  - `src/sdk/root.zig`

**Work**
- move or re-export the existing report helpers from CLI-owned files into a
  public namespace entrypoint with minimal logic churn
- keep CLI convenience re-exports if helpful, but make the public namespace the
  documented home for embedders
- ensure embedders do not need `scheduler.cli.*` to produce versioned JSON

**Acceptance criteria**
- report serialization can be reached entirely through the documented public
  embedder surface
- CLI remains functional but is no longer the canonical public API home for
  report generation
- the implementation is a namespace move/re-export, not a redesigned report
  pipeline
- report schema/version checks remain explicit and stable

### Step 4 — Add explicit build wiring plus a real embedding example
**Goal:** prove that the curated boundary is sufficient for a real embedder.

**Likely files**
- `build.zig`
- new example file(s), for example:
  - `examples/embedding/basic.zig`
  - `examples/embedding/report_export.zig`
- optional doc companion:
  - `docs/examples/embedding/basic.md`

**Recommended example shape**
One minimal example is enough if it proves the full path:
- import `zig_scheduler` only
- `parseScenarioText` from inline source text (no repo fixture paths)
- `simulate` with `PolicyKind`
- inspect documented aggregate/result data
- emit versioned JSON report through the non-CLI public namespace

**Work**
- add `build.zig` wiring for both module tracks: `zig_scheduler` public facade
  plus the separate internal module for repo-owned tools
- add explicit test wiring so existing internal-root tests are still collected
  after `zig_scheduler` points at the curated facade
- add one exact build step for smoke verification, e.g. `zig build m22-embed-smoke`, that compiles/runs the embedding example against `zig_scheduler` only
- keep the example consumer-shaped and small; no TUI, no CLI parser, no
  observability path

**Acceptance criteria**
- `zig build m22-embed-smoke` compiles and runs successfully against `zig_scheduler` only
- internal tests do not disappear when the public module narrows
- example code would remain valid even if internal modules were renamed
- example docs explain this is simulator embedding, not product/service hosting

### Step 5 — Add explicit library API contract tests and concrete negative boundary checks
**Goal:** create regression proof for the public boundary itself.

**Likely files**
- `src/tests/library_sdk_test.zig` (new)
- `src/tests/identity_gate_test.zig`
- `src/tests/scenario_test.zig` and/or `src/tests/simulator_test.zig`
- `src/lib.zig` test import list or a dedicated test root
- `build.zig`

**Work**
- add tests that compile/use only the curated public surface
- add an explicit allowlist-style compile-time audit for the public root using the exact symbol inventory in the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution) as source of truth
- assert documented stable symbols are present and usable
- make negative checks concrete using compile-time absence checks for at least:
  `engine`, `metrics`, `policies`, `scenario_packs`, `cli`, `property`, `observability`, `observability_comparison`
- add docs audits asserting that the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution) is the exact documented stable-subset inventory and that only curated namespaces are documented as stable
- add explicit internal-module import usage in repo-owned tools, proving those
  broader namespaces were intentionally moved out of the public contract
- add docs audit coverage so README/M22 docs do not overclaim SDK scope

**Acceptance criteria**
- tests fail if the public facade deviates from the allowlisted documented stable-subset inventory in the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution)
- tests cover `parseScenarioText -> simulate -> non-CLI report export` through the public API
- tests prove no CLI dependency and no repo fixture-path dependency are required for library embedding
- negative boundary checks make accidental re-export regressions visible where practical

### Step 6 — Audit internal consumers, test roots, and finish the compatibility story
**Goal:** ensure the new public split is sustainable.

**Likely files**
- `src/sim_cli_app.zig`
- `src/bench/root.zig`
- `src/report_pipeline/root.zig`
- `src/tui/*`
- `README.md`
- `docs/project-architecture-and-status.md`

**Work**
- decide which repo-owned tools should move to the internal module versus the
  curated public module, following the default rule that repo-owned tools import the internal module whenever they need anything outside the curated facade
- explicitly preserve internal test coverage by ensuring test roots for the
  internal module/root remain wired in `build.zig` after the public split
- document the rule: repo-owned tools import the internal module by default if they need anything outside the curated facade; embedder guidance points only at `zig_scheduler`, and only the embedding example plus dedicated library contract tests are required to use `zig_scheduler` alone
- confirm observability/TUI/analysis remain outside the stable library promise

**Acceptance criteria**
- internal consumers are intentionally assigned to either public or internal
  module usage according to the explicit routing rule
- internal tests remain discoverable and runnable after the split
- docs and code agree on the supported embedder path
- no accidental stable promise is made for non-embedder surfaces

---

## 5) Risks and tradeoffs

### Risk 1 — Public surface still ends up too broad
If M22 exports built-in scenario registries, policy modules, CLI helpers, or
observability surfaces “for convenience,” the milestone will recreate the same
problem under a new filename.

**Mitigation:** keep the stable facade category-based and doc-audited; require
new public exports to justify embedder value.

### Risk 2 — Internal/public split causes churn in repo-owned tools
Changing `build.zig` module wiring may require multiple internal tools to update
imports.

**Mitigation:** prefer a clean dual-module setup (`public facade` + `internal
root`) rather than forcing internal tools through premature restriction.

### Risk 3 — Promise on raw allocator-owning types may constrain future evolution
Exposing `ScenarioOwned` and `SimulationResult` is practical, but freezing every
field/layout/helper would create a stronger compatibility burden than M22 needs.

**Mitigation:** document them as usable workflow types with narrower promises:
only documented access patterns, ownership rules, and example-covered fields are
stable; additive growth remains allowed and full raw layout is not promised.

### Risk 4 — Example proves the wrong thing
If the example uses CLI parsing or TUI helpers, it will not actually prove an
embedder contract.

**Mitigation:** require the example to use only the public module and no CLI
arg-parsing path.

### Risk 5 — Versioning becomes bigger than the milestone
Trying to fully solve package/release/distribution semantics in M22 would blur
into M23.

**Mitigation:** keep M22 versioning local to API boundary + report contract;
leave packaging/release semantics to M23.

---

## 6) Verification plan

### Required proof themes
1. **Public boundary proof** — the curated module exports exactly what docs say
2. **Embedding proof** — a consumer-shaped example compiles/runs against the
   public module only
3. **Compatibility proof** — docs and code agree on what is stable vs unstable
4. **Identity proof** — simulator-first wording remains truthful

### Minimum checks
- `zig build test --summary all`
- targeted library/API test suite exercising public facade only
- exact `build.zig` smoke step `zig build m22-embed-smoke` using `zig_scheduler` only
- explicit internal-module test wiring check so internal test coverage still runs after the split
- docs/compatibility audit against `README.md`, `docs/project-architecture-and-status.md`, and the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution)

### Recommended additional checks
- an allowlist-style stable-subset declaration audit plus compile-time absence checks (`@hasDecl` or equivalent) to prevent accidental public re-export of `engine`, `metrics`, `policies`, `scenario_packs`, `cli`, `property`, `observability`, and `observability_comparison`
- a small golden/assertion for public API version constant and report schema
  version relationship
- repeated-run example smoke if the example emits deterministic JSON

### Concrete verification matrix for M22 execution
- **Library API test:** `parseScenarioText -> simulate -> inspect documented result data` via public facade
- **Report API test:** construct/report JSON through the public namespace without importing `scheduler.cli`
- **Example smoke:** `zig build m22-embed-smoke` succeeds and runs using `zig_scheduler` only, inline scenario text, and non-CLI report export
- **Internal wiring check:** `zig build test --summary all` still exercises the internal-module test roots after the split
- **Boundary audit:** the stable subset of the public root matches the allowlisted documented inventory in the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution); compile-time absence checks and docs audits catch accidental public promotion of internal modules
- **Identity audit:** wording still says simulator-first, teaching/experimentation,
  not product/service/runtime automation

---

## 7) ADR-style mini section

### Decision
Keep `zig_scheduler` as the curated public embedder module for M22, backed by explicit API version
policy and example embedding proof, while introducing a separate broader internal module/root
for repo-owned tools.

### Drivers
- Current `pub usingnamespace` + `src/root.zig` breadth overexposes internal
  modules.
- Embedders need a real supported path, but the repo should not promise more API
  than it can sustain.
- M22 must remain distinct from teaching polish (M21) and packaging/distribution
  (M23).

### Alternatives considered
- Document the existing broad root as stable API.
- Introduce a much narrower high-level wrapper and hide most value types.

### Why this decision
It keeps the public promise small enough to be credible while still matching the
repo’s existing useful simulation/report primitives.

### Consequences
- `build.zig` likely gains separate public and internal module wiring plus explicit test-root wiring.
- Some internal consumers may need import updates.
- Future embedder work will have a clear place to land without widening TUI/CLI
  or observability surfaces.

### Follow-ups
- Revisit whether built-in scenario registry helpers belong in the public API
  only after real embedder demand exists.
- Keep report schema versioning and library API versioning explicitly separate.
- If packaging/distribution is later desired, carry that into M23 instead of
  widening M22.

---

## 8) Recommended execution mode

### Recommendation: `ralph`
M22 is best executed as a **single-owner, verification-heavy branch**:
- public-boundary design and docs need one coherent owner
- the code changes are cross-cutting but still sequential: docs -> facade split
  -> report extraction -> example -> tests
- the roadmap already lists M22 as a strong `ralph` candidate

### When `$team` would be justified instead
Use `$team` only if you intentionally split into disjoint lanes such as:
- lane 1: public facade/build wiring
- lane 2: report namespace extraction
- lane 3: docs + example + compatibility audit

That is viable, but it adds coordination overhead and shared-file collision risk
around `build.zig`, `src/lib.zig`, and docs. For the expected M22 size, `ralph`
is the better default.

---

## 9) Execution-ready milestone summary

**Recommended scope:**
- keep `zig_scheduler` as the curated public module and add a separate internal module/root
- use the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution) as the exact documented stable-subset inventory for the public API
- stabilize only model + scenario-ingestion + simulate + report/export helpers
- narrow promises on allocator-owning raw structs to documented workflows/fields rather than freezing all layout details
- keep CLI/TUI/analysis/observability/property/policy internals out of the
  stable public promise
- add explicit build/test wiring, a real embedder example, and contract tests

**Likely key files:**
- `src/lib.zig`
- `src/root.zig` or a new internal root/module file
- `build.zig`
- `src/contract/report.zig`
- `src/cli/report.zig`
- `src/cli/output.zig`
- `src/tests/library_sdk_test.zig` (new)
- `README.md`
- `docs/project-architecture-and-status.md`
- the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution) (new, exact documented stable-subset inventory)
- `examples/embedding/basic.zig` (new, or equivalent)

**Milestone succeeds when:**
- the public embedder surface is curated, documented, and versioned
- example embedding code compiles/runs against that surface
- compatibility promises are precise and intentionally narrow
- simulator-first identity remains truthful
- M22 stays clearly separate from M21 teaching polish and M23 packaging
