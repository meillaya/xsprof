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
- committed teaching/review artifacts that are reproducible from repo inputs

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
2. Discovery and teaching polish should reuse committed scenarios, docs, and snapshots before adding new machinery.
3. Reviewable committed artifacts beat ad hoc demo instructions.
4. Scope should favor a few high-signal teaching paths over broad curriculum expansion.
5. Every new teaching claim must stay within what current deterministic fixtures and tests can prove.

### Decision drivers (top 3)
1. Reduce time-to-first-good-demo for reviewers/instructors using existing repo-native surfaces.
2. Increase reviewability through deterministic committed artifacts and snapshot coverage.
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

#### Option B — Simulator teaching-path polish across docs + TUI metadata + deterministic snapshots (recommended)
Surface a small set of teaching-first scenario affordances in the existing picker/help/docs flow and add committed snapshot proof for selected canonical simulator scenarios.

**Pros**
- improves actual discoverability, not just prose
- stays inside existing TUI/snapshot architecture
- creates stronger review artifacts without widening contracts

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

These three cover the most legible teaching stories across single-core,
blocked/wakeup, and multicore behavior without turning M21 into a full-course
rewrite.

### In-scope deliverables
1. **Teaching-path discoverability polish in the TUI simulator lane**
   - make the picker/help surface clearer about which scenarios are best for a
     first demo and which policy/doc pair goes with them
   - keep this simulator-lane framing separate from M19/M20
2. **One explicit committed walkthrough/index doc for the M21 teaching path**
   - scenario → command → artifact → what-to-look-for
   - centered on the three anchor scenarios above
3. **Deterministic snapshot proof for the teaching path**
   - picker/help snapshot proof for discoverability copy
   - explorer snapshots for the three anchor scenarios under recommended policy
4. **README/project-status alignment**
   - make the fastest local demo/review path obvious
   - document observability as side-lane evidence, not mainline identity

### Out of scope for M21
- new rendering modes or browser delivery
- widening the scenario corpus beyond a small teaching-first shortlist
- new analysis/report contracts
- expanding M19/M20 beyond discoverability reminders and boundary wording
- general courseware packaging, lesson sequencing, or downloadable bundles

### Why three anchor scenarios is the right size
- enough coverage to teach the project shape well
- small enough to land with high-confidence snapshot proof
- avoids turning every canonical scenario into a first-class walkthrough in one cut

---

## 4) Concrete implementation steps with likely files

### Step 1 — Define the M21 teaching-path contract in docs
**Goal:** freeze the exact milestone shape before code changes.

**Likely files**
- `docs/m21-simulator-first-teaching-surface.md`
- `docs/project-architecture-and-status.md`
- `.omx/plans/prd-m21-simulator-first-teaching-surface.md`
- `.omx/plans/test-spec-m21-simulator-first-teaching-surface.md`

**Work**
- expand M21 doc from intent-only into a concrete scope statement
- name the three anchor scenarios and the committed proof surfaces
- state explicit non-goals and observability-side-lane boundary again

**Acceptance criteria**
- M21 doc names exact anchor scenarios, proof surfaces, and non-goals
- project status doc reflects the same bounded scope
- wording keeps simulator-first identity primary and observability secondary

### Step 2 — Polish simulator-lane teaching discoverability in the TUI
**Goal:** make the best demo path more obvious from the existing picker/help flow.

**Likely files**
- `src/tui/root.zig`
- `src/tui/render.zig`
- possibly `src/sim/scenario_pack.zig` only if tiny metadata additions are needed

**Work**
- surface a small teaching-oriented label/card/hint for canonical entries in the picker
- expose recommended policy and doc pointer/hint for the selected teaching scenario
- update help/picker copy so the simulator-first demo path is explicit
- keep `m`/`c` observability shortcuts present but visually secondary

**Acceptance criteria**
- picker makes the three anchor scenarios feel like the obvious first stops
- selected scenario copy includes enough context to know what to run/look for
- help/picker copy does not imply M19/M20 are the main teaching path
- no new simulator/report/analysis contract fields are introduced

### Step 3 — Add deterministic teaching snapshots for reviewable committed proof
**Goal:** make the teaching path auditable from committed artifacts/tests.

**Likely files**
- `src/tui/root.zig`
- `src/tests/identity_gate_test.zig`
- `src/tests/scenario_pack_test.zig`
- optional new checked-in artifacts under `docs/examples/` or `docs/labs/` if the implementation chooses committed text snapshots

**Work**
- add/expand snapshot tests covering:
  - picker discoverability copy
  - help copy for simulator-first path
  - explorer snapshots for the three anchor scenarios under recommended policy
- if committed snapshot artifacts are added, keep them text-based and reproducible from existing commands

**Acceptance criteria**
- deterministic snapshot coverage exists for all three anchor scenarios
- snapshot proof is simulator-lane focused
- snapshot wording stays truthful and bounded

### Step 4 — Add one committed teaching/review index document
**Goal:** give reviewers/instructors a single repo-native path through the best surfaces.

**Likely files**
- `README.md`
- `docs/m17-scenario-corpus.md`
- `docs/labs/simulator-teaching-pack.md` (new, recommended) **or** a tightly scoped extension to an existing lab/index doc if preferred

**Work**
- create one concise document that maps each anchor scenario to:
  - scenario file
  - recommended command(s)
  - recommended TUI/snapshot artifact
  - what to notice
  - linked deeper explanation doc
- add README links to this index and to the fastest local demo commands
- update the scenario corpus doc to point at the new teaching-first shortlist

**Acceptance criteria**
- one document lets a reviewer/demo leader run the best three stories without hunting across the repo
- README exposes a clear simulator-first "start here" path
- deeper milestone docs remain linked but are not required to discover the basics

### Step 5 — Lock the boundary and docs identity in tests
**Goal:** ensure M21 polish cannot accidentally drift into wider product claims.

**Likely files**
- `src/tests/identity_gate_test.zig`
- `src/tests/scenario_pack_test.zig`

**Work**
- add assertions that README/project docs mention the M21 teaching path and keep observability secondary/bounded
- add checks that selected teaching docs and scenario metadata remain aligned
- if new teaching-pack docs/artifacts are added, link/assert them from tests

**Acceptance criteria**
- tests fail if M21 docs drift away from simulator-first wording
- tests fail if the teaching shortlist or links become stale
- no tests imply replay/performance/calibration meaning

---

## 5) Risks and tradeoffs

1. **Docs-first but not discoverability-first**
   - Risk: the milestone lands as prose only and does not materially improve the live picker/TUI path.
   - Mitigation: require Step 2 and Step 3, not docs alone.

2. **Scope creep into M23-style courseware**
   - Risk: too many walkthroughs, too many artifacts, or a large new content tree.
   - Mitigation: lock scope to three anchor scenarios and one index doc.

3. **Observability lane steals attention**
   - Risk: M19/M20 become visually framed as co-equal teaching entrypoints.
   - Mitigation: keep observability shortcuts and docs present but explicitly secondary and bounded.

4. **Snapshot proof becomes brittle/noisy**
   - Risk: too many large golden surfaces create maintenance drag.
   - Mitigation: snapshot only the picker/help teaching copy and three anchor explorer views.

5. **Metadata pressure on scenario-pack structures**
   - Risk: adding too much new scenario metadata creates a larger design change than M21 needs.
   - Mitigation: prefer reusing existing `description`, `recommended_policy`, `theme`, and `explanation_doc`; add fields only if a tiny gap remains.

---

## 6) Verification plan

### Primary automated checks
- `zig build test --summary all`
- targeted review of TUI snapshot assertions covering picker/help/anchor scenarios
- docs/identity tests covering README, M21 doc, scenario corpus doc, and project status doc

### Required verification matrix
1. **Docs alignment audit**
   - README, M21 doc, scenario corpus doc, and project status doc all describe the same three-scenario teaching path.
2. **Teaching-path discoverability snapshot proof**
   - picker snapshot shows clear simulator-first entry guidance
   - help snapshot reinforces the same starting path
3. **Anchor-scenario explorer proof**
   - deterministic snapshots for:
     - `short-vs-long` + `fcfs`
     - `sleep-wakeup` + `cfs_like`
     - `multicore-balancing` + `fcfs`
4. **Boundary audit**
   - no widening of `src/contract/report.zig`, `src/cli/report.zig`, `src/analysis/*`
   - no new Linux-performance, replay-fidelity, or calibration wording
5. **Metadata/link audit**
   - any surfaced teaching scenario still maps to an existing scenario file and explanation doc

### Manual smoke expectations
- from README alone, a reviewer can identify the fastest simulator-first demo path
- from the TUI picker/help alone, a contributor can identify the three anchor scenarios and their recommended policy/doc hints
- observability lane remains reachable but obviously secondary

---

## 7) ADR-style mini section

### Decision
Ship M21 as a **small simulator-teaching polish milestone**: improve the existing simulator-lane picker/help/docs path around three anchor scenarios and back it with deterministic teaching snapshots plus one committed review index.

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
- The repo gains a clearer first-demo path and stronger committed review artifacts.
- Some TUI copy/snapshot tests become more central to regression safety.

### Follow-ups
- If M21 works well, M23 can later expand packaging/courseware using the same anchor scenarios and committed artifacts.
- If additional canonical scenarios need first-class walkthroughs later, they should be added one or two at a time with matching snapshot proof.

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
