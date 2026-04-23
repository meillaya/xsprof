# PRD — M21 simulator-first teaching surface polish

## Status
Draft for consensus review on 2026-04-22

## 1) Task framing and evidence grounding

### Framing
M21 should make the existing simulator-first surfaces easier to discover, teach,
demo, and review from committed artifacts without opening a new platform or
widening any existing public contract.

### Grounding from repo evidence
- `docs/m21-simulator-first-teaching-surface.md` already defines M21 as a
  simulator-first teaching-surface polish cut, not a new platform branch.
- `docs/project-architecture-and-status.md` explicitly positions M21 after the
  implemented M15-M20 surfaces and calls for walkthrough/docs polish plus more
  deterministic snapshot/golden proof surfaces.
- `README.md` already exposes the main TUI path, snapshot path, canonical
  scenarios, and the bounded M19/M20 picker shortcuts.
- `src/tui/root.zig` already builds canonical picker entries from
  `src/sim/scenario_pack.zig`, so the TUI already has curriculum metadata it can
  surface more clearly.
- `src/tests/cli_smoke_test.zig` already exists as the repo’s CLI-smoke lane, so
  command validation for README/index-doc commands fits the current test shape.
- `src/tui/root.zig` and `src/tui/render.zig` already contain deterministic
  snapshot-oriented tests for picker/help/explorer/observability views, which
  makes snapshot-proof expansion a low-risk next step.
- `src/tests/scenario_pack_test.zig` already enforces canonical scenario
  metadata and explanation-doc links, giving M21 a stable metadata base.

### Scope boundary
This milestone may produce:
- a clearer simulator-first "start here" path in README/docs/TUI copy
- a small set of first-class teaching scenarios with explicit walkthrough paths
- deterministic TUI snapshot proof for selected canonical simulator scenarios
- one committed teaching/review index doc plus tests/snapshots reproducible from repo inputs

This milestone must not produce:
- a browser/WASM surface
- widened `zig-scheduler/report` or `src/analysis/*`
- Linux-performance, replay-fidelity, calibration, or kernel-accuracy claims
- a re-centering of repo identity around M19/M20
- M23-style packaging/courseware breadth

---

## 2) RALPLAN-DR short summary

### Principles
1. Simulator-first identity stays primary; observability remains a bounded side lane.
2. The exact three-anchor shortlist must come from one shared code source of truth.
3. Proof should stay tight: tests plus one index doc beat new artifact trees unless strictly necessary.
4. Scope should favor a few high-signal teaching paths over broad curriculum expansion.
5. Every new teaching claim must stay within what current deterministic fixtures and tests can prove.

### Decision drivers (top 3)
1. Reduce time-to-first-good-demo for reviewers/instructors using existing repo-native surfaces.
2. Increase reviewability through deterministic tests/snapshots and one index doc, not broader artifact trees.
3. Preserve current product/contract boundaries while making the simulator lane easier to navigate than the observability lane.

### Viable options

#### Option A — Docs-only playbook refresh
Tighten README and milestone docs, but leave TUI teaching affordances and snapshot proof mostly unchanged.

**Pros**
- smallest diff
- lowest regression risk
- mostly docs/test work

**Cons**
- leaves the best teaching metadata buried in code and corpus docs
- weaker improvement to in-product discoverability
- less convincing committed-artifact review path

#### Option B — Simulator teaching-path polish across docs + existing TUI metadata + deterministic snapshots (recommended)
Surface a small set of teaching-first scenario affordances in the existing picker/help/docs flow, explicitly reusing existing scenario-pack metadata plus one minimal shared helper for the exact M21 shortlist, and add deterministic snapshot proof for selected canonical simulator scenarios.

**Pros**
- improves actual discoverability, not just prose
- stays inside existing TUI/snapshot architecture
- creates stronger review proof without widening contracts or adding new artifact trees

**Cons**
- touches both docs and TUI rendering/tests
- requires discipline to keep M19/M20 clearly secondary

#### Option C — Broad teaching pack / courseware expansion
Add a large curated lesson pack, many scenario walkthroughs, broader artifact generation, and heavier docs structure.

**Pros**
- richest teaching package
- strongest standalone instructional value

**Cons**
- drifts toward M23-scale work
- expands review/maintenance cost too early
- risks shifting identity from simulator core polish to packaging

---

## 3) Recommended scope for M21

Recommend **Option B**, but keep it deliberately small:

### Core milestone shape
M21 should polish the simulator-first teaching surface around **three anchor scenarios** plus one cross-linking doc path:
- `short-vs-long` — convoy / first-demo contrast
- `sleep-wakeup` — blocked/wakeup teaching path
- `multicore-balancing` — multicore rebalance story

**Exact source of truth:** add one minimal shared helper in `src/sim/scenario_pack.zig` that returns the exact M21 shortlist (`scenario path/key + required policy + explanation doc path`). TUI ranking/copy, tests, and docs validation should consume that helper rather than re-encoding the shortlist in multiple places.

**Canonical teaching index path:** `docs/labs/simulator-teaching-pack.md`

These three cover the most legible teaching stories across single-core,
blocked/wakeup, and multicore behavior without turning M21 into a full-course
rewrite.

### In-scope deliverables
1. **Teaching-path discoverability polish in the TUI simulator lane**
   - make the picker/help surface clearer about which scenarios are the M21
     start-here shortlist and which policy/doc pair goes with them
   - rank this simulator-first anchor path above M19/M20 shortcuts in copy and layout
   - consume existing `src/sim/scenario_pack.zig` metadata before considering any new core fields
2. **One explicit committed walkthrough/index doc for the M21 teaching path**
   - scenario → command → artifact → what-to-look-for
   - centered on the three anchor scenarios above
3. **Deterministic snapshot proof for the teaching path**
   - picker/help snapshot proof for discoverability copy
   - explorer snapshots for the three anchor scenarios under recommended policy
   - keep report artifacts secondary; proof stays mostly TUI/snapshot/docs
4. **README/project-status alignment**
   - make the fastest local demo/review path obvious
   - document observability as side-lane evidence, not mainline identity

### Out of scope for M21
- new rendering modes or browser delivery
- widening the scenario corpus beyond the exact three-scenario M21 start-here shortlist
- new analysis/report contracts
- expanding M19/M20 beyond discoverability reminders and boundary wording
- general courseware packaging, lesson sequencing, downloadable bundles, or extra committed artifact trees unless strictly required

### Why three anchor scenarios is the right size
- enough coverage to teach the project shape well
- small enough to land with high-confidence snapshot proof
- keeps the M21 “start here” shortlist exact and testable
- avoids turning every canonical scenario into a first-class walkthrough in one cut

---

## 4) Concrete implementation steps with likely files

### Step 1 — Define the M21 teaching-path contract in docs
**Goal:** freeze the exact milestone shape before code changes.

**Likely files**
- `docs/m21-simulator-first-teaching-surface.md`
- `docs/project-architecture-and-status.md`
- `docs/labs/simulator-teaching-pack.md`
- `docs/roadmap/m21/prd-m21-simulator-first-teaching-surface.md`
- `docs/roadmap/m21/test-spec-m21-simulator-first-teaching-surface.md`

**Work**
- expand M21 doc from intent-only into a concrete scope statement
- name the three anchor scenarios and tighten proof surfaces to tests plus one index doc
- lock the canonical teaching index path to `docs/labs/simulator-teaching-pack.md`
- define the shared shortlist helper as the single source of truth that docs/TUI/tests follow
- state explicit non-goals and observability-side-lane boundary again

**Acceptance criteria**
- M21 doc names the exact three anchors, the exact shortlist boundary, proof surfaces, and non-goals
- project status doc and `docs/labs/simulator-teaching-pack.md` reflect the same bounded scope
- the shared shortlist helper is identified as the single source of truth
- wording keeps simulator-first identity primary and observability secondary

### Step 2 — Polish simulator-lane teaching discoverability in the TUI
**Goal:** make the best demo path more obvious from the existing picker/help flow.

**Likely files**
- `src/tui/root.zig`
- `src/tui/render.zig`
- `src/sim/scenario_pack.zig` (for the minimal shared shortlist helper)

**Work**
- add a minimal shared helper in `src/sim/scenario_pack.zig` that returns the exact three-anchor M21 shortlist
- surface a small teaching-oriented label/card/hint for those anchors in the picker using existing scenario-pack metadata
- expose recommended policy and doc pointer/hint for the selected teaching scenario using existing `description`, `recommended_policy`, `theme`, and `explanation_doc` first
- update help/picker copy so the simulator-first demo path is explicit and ranked above `m`/`c` observability shortcuts
- keep `m`/`c` observability shortcuts present but visually secondary

**Acceptance criteria**
- picker makes the three anchor scenarios from the shared helper the only M21 “start here” shortlist
- selected scenario copy includes enough context to know what to run/look for
- help/picker copy ranks the simulator shortlist above M19/M20 shortcuts
- existing scenario-pack metadata plus the helper are sufficient, or any unavoidable metadata change is explicitly justified and minimal
- no new simulator/report/analysis contract fields are introduced

### Step 3 — Add deterministic teaching snapshots for reviewable committed proof
**Goal:** make the teaching path auditable from committed artifacts/tests.

**Likely files**
- `src/tui/root.zig`
- `src/tests/identity_gate_test.zig`
- `src/tests/scenario_pack_test.zig`
- `src/tests/cli_smoke_test.zig`

**Work**
- add/expand snapshot tests covering:
  - picker discoverability copy
  - help copy for simulator-first path
  - explorer snapshots for the three anchor scenarios under recommended policy
- openly reject new committed artifact trees unless snapshot proof cannot be expressed cleanly in tests

**Acceptance criteria**
- deterministic snapshot coverage exists for all three anchor scenarios
- snapshot proof is simulator-lane focused and remains inside tests
- snapshot wording stays truthful and bounded

### Step 4 — Add one committed teaching/review index document
**Goal:** give reviewers/instructors a single repo-native path through the best surfaces.

**Likely files**
- `README.md`
- `docs/m17-scenario-corpus.md`
- `docs/labs/simulator-teaching-pack.md`

**Work**
- create one concise document that maps each anchor scenario to:
  - scenario file
  - recommended command(s)
  - recommended TUI/snapshot artifact
  - what to notice
  - linked deeper explanation doc
- add README links to `docs/labs/simulator-teaching-pack.md` and to the fastest local demo commands
- update the scenario corpus doc to point at the exact three-scenario teaching shortlist from the shared helper
- if `multicore-balancing` needs a clearer explanation link, resolve it within docs/current metadata scope and call that out explicitly

**Acceptance criteria**
- `docs/labs/simulator-teaching-pack.md` lets a reviewer/demo leader run the best three stories without hunting across the repo
- README exposes a clear simulator-first "start here" path
- the three anchors from the shared helper are the only M21 shortlist surfaced as “start here”
- deeper milestone docs remain linked but are not required to discover the basics

### Step 5 — Lock the boundary and docs identity in tests
**Goal:** ensure M21 polish cannot accidentally drift into wider product claims.

**Likely files**
- `src/tests/identity_gate_test.zig`
- `src/tests/scenario_pack_test.zig`

**Work**
- add assertions that README/project docs mention the M21 teaching path and keep observability secondary/bounded
- add checks that the three anchors from the shared helper are the only M21 “start here” shortlist
- add checks that selected teaching docs and scenario metadata remain aligned
- add CLI smoke coverage for every README/index-doc command in `src/tests/cli_smoke_test.zig`

**Acceptance criteria**
- tests fail if M21 docs drift away from simulator-first wording
- tests fail if the three-anchor shortlist or links become stale
- no tests imply replay/performance/calibration meaning

---

## 5) Risks and tradeoffs

1. **Docs-first but not discoverability-first**
   - Risk: the milestone lands as prose only and does not materially improve the live picker/TUI path.
   - Mitigation: require Step 2 and Step 3, not docs alone.

2. **Scope creep into M23-style courseware**
   - Risk: too many walkthroughs, too many artifacts, or a large new content tree.
   - Mitigation: lock scope to three anchor scenarios, one index doc, and tests as the main proof surface.

3. **Observability lane steals attention**
   - Risk: M19/M20 become visually framed as co-equal teaching entrypoints.
   - Mitigation: keep observability shortcuts and docs present but explicitly secondary and bounded.

4. **Snapshot proof becomes brittle/noisy**
   - Risk: too many large golden surfaces create maintenance drag.
   - Mitigation: snapshot only the picker/help teaching copy and three anchor explorer views; reject extra committed snapshot trees unless strictly needed.

5. **Metadata pressure on scenario-pack structures**
   - Risk: adding too much new scenario metadata creates a larger design change than M21 needs.
   - Mitigation: reuse existing `description`, `recommended_policy`, `theme`, and `explanation_doc`; add fields only if unavoidable and justify the change explicitly.

---

## 6) Verification plan

### Primary automated checks
- `zig build test --summary all`
- targeted review of TUI snapshot assertions covering picker/help/anchor scenarios
- docs/identity tests covering README, M21 doc, scenario corpus doc, project status doc, and `docs/labs/simulator-teaching-pack.md`
- command smoke validation in `src/tests/cli_smoke_test.zig` for every README/index-doc command in the M21 path

### Required verification matrix
1. **Docs alignment audit**
   - README, M21 doc, scenario corpus doc, project status doc, and `docs/labs/simulator-teaching-pack.md` all describe the same exact three-scenario teaching path.
2. **Teaching-path discoverability snapshot proof**
   - picker snapshot shows clear simulator-first entry guidance
   - help snapshot reinforces the same starting path
   - both snapshots rank the anchor path above M19/M20 shortcuts
3. **Anchor-scenario explorer proof**
   - deterministic snapshots for:
     - `short-vs-long` + `fcfs`
     - `sleep-wakeup` + `cfs_like`
     - `multicore-balancing` + `fcfs`
4. **Boundary audit**
   - no widening of `src/contract/report.zig`, `src/cli/report.zig`, `src/analysis/*`
   - no new Linux-performance, replay-fidelity, or calibration wording
   - report artifacts stay secondary to TUI/snapshot/docs proof
5. **Metadata/link audit**
   - the shared shortlist helper returns exactly the three approved `(scenario, policy)` pairs
   - any surfaced teaching scenario still maps to an existing scenario file and explanation doc
   - `multicore-balancing` has a clear explanation link, resolved within docs/current metadata scope if needed
6. **Command smoke audit**
   - `src/tests/cli_smoke_test.zig` executes every command shown in README or `docs/labs/simulator-teaching-pack.md` for the three-anchor path

### Manual smoke expectations
- from README alone, a reviewer can identify the fastest simulator-first demo path
- from the TUI picker/help alone, a contributor can identify the three anchor scenarios as the only M21 “start here” shortlist and their recommended policy/doc hints
- observability lane remains reachable but obviously secondary

---

## 7) ADR-style mini section

### Decision
Ship M21 as a **small simulator-teaching polish milestone**: improve the existing simulator-lane picker/help/docs path around exactly three anchor scenarios from one shared helper and back it with deterministic tests/snapshots plus one committed review index at `docs/labs/simulator-teaching-pack.md`.

### Drivers
- fastest path to a better demo/review loop without widening architecture
- strong existing metadata and snapshot infrastructure already present in repo
- need to preserve simulator-first identity after M19/M20 became reachable in the TUI

### Alternatives considered
- **Docs-only refresh**: rejected because it under-improves in-product discoverability.
- **Broad teaching/courseware expansion**: rejected because it is too close to M23-scale packaging.
- **Observability-forward teaching framing**: rejected because it conflicts with the simulator-first identity and current governance boundaries.

### Consequences
- M21 lands as a meaningful but small polish cut, not a new branch of product scope.
- The repo gains a clearer first-demo path and stronger test-backed review proof.
- Some TUI copy/snapshot tests and command smokes become more central to regression safety.

### Follow-ups
- If M21 works well, M23 can later expand packaging/courseware using the same anchor scenarios and committed artifacts.
- If additional canonical scenarios need first-class walkthroughs later, they should be added only in a later milestone with matching snapshot proof and updated shortlist tests.

---

## 8) Execution recommendation: solo / ralph / team

Recommend **solo execution with a Ralph-style finish loop**, not team mode.

### Why
- likely change surface is modest: roughly 8-10 files across docs, TUI copy/rendering, and tests
- the work is tightly coupled around one teaching-path narrative, so parallel lanes would spend more time coordinating copy and snapshot expectations than they save
- the main risk is boundary drift, which is better handled by one owner iterating through inspect → edit → snapshot/test → wording audit

### Suggested execution posture
- single owner implements docs + TUI copy/snapshot changes
- use a Ralph-style verification loop until docs alignment, snapshot proof, and full tests are green
- do **not** use team mode unless the scope widens beyond the three-anchor plan or picks up new artifact-generation machinery
