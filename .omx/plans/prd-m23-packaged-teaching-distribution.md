# PRD — M23 packaged teaching distribution and courseware

## Status
Draft for consensus review on 2026-04-22

## 1) Task framing and evidence grounding

### Framing
M23 should package the existing simulator-first teaching material into **one
bounded, repo-native courseware shell over M21** that an instructor or
self-guided learner can follow from onboarding through a first reproducible
assignment set.

This milestone is about **packaging the already-proven M21 teaching path**,
not creating a second canonical teaching spine and not expanding platform
scope, widening the observability branch, or re-chartering the repo into a
browser, WASM, service, or production system.

### Grounding from repo evidence
- `.omx/context/m23-packaged-teaching-distribution-20260422T201500Z.md`
  identifies the current gap clearly: strong simulator teaching materials exist,
  but there is not yet an obvious courseware index, onboarding bundle, or
  reproducible assignment pack.
- `.omx/plans/prd-multi-horizon-zig-scheduler-roadmap.md` defines M23 as the
  optional teaching/distribution branch with acceptance criteria centered on a
  documented teaching path, easier onboarding, and reproducible assignments.
- `README.md` already presents the project as a **simulator-first teaching and
  experimentation environment** with M19/M20 explicitly bounded as an offline
  observability side lane and M22 explicitly bounded as a narrow embedder lane.
- `docs/labs/simulator-teaching-pack.md` already gives M21 a tight three-anchor
  simulator-first path:
  - `short-vs-long` + `fcfs`
  - `sleep-wakeup` + `cfs-like`
  - `multicore-balancing` + `fcfs`
- `src/sim/scenario_pack.zig` already exposes `listM21TeachingEntries()` as a
  machine-checkable source of truth for that exact shortlist.
- `docs/m22-library-sdk.md` and `zig build m22-embed-smoke` already establish a
  narrow optional SDK branch that M23 may reference, but must not broaden.
- `src/tests/scenario_pack_test.zig`, `src/tests/cli_smoke_test.zig`, and
  `src/tests/identity_gate_test.zig` already provide the repo’s normal pattern
  for docs alignment, command-smoke, and identity-boundary enforcement.

### Scope boundary
M23 may produce:
- one **canonical package entrypoint** for the first packaged teaching cut
- one **student onboarding path** that starts from repo checkout and lands on
  the M21 three-anchor teaching loop
- one **bounded assignment/exercise pack** built from committed scenarios and
  exact commands already supported by the repo
- one **instructor-facing guide** for pacing, expected observations, and
  boundary-safe usage of the package shell
- docs/tests proving that the package path is reproducible from committed
  artifacts and does not hide project boundaries

M23 must not produce:
- a second canonical teaching spine
- a redefinition of the required anchor set or primary M21 commands
- browser/WASM delivery
- hosted/lab service infrastructure
- live Linux capture, replay automation, or production observability scope
- a broad curriculum for every scenario/policy in the repo
- M22 API expansion beyond citing the already-approved narrow embedder smoke
- a repositioning of M19/M20 from side lane to main teaching spine

### Package-shell rule
M23 is explicitly a **package shell over M21**:
- it **may** reorganize, sequence, and cross-link the M21 teaching path for
  onboarding and coursework use
- it **may not** redefine the required anchor set
- it **may not** replace the primary M21 commands with a new required command set
- the exact required anchors must derive from `listM21TeachingEntries()`

---

## 2) RALPLAN-DR short summary

### Principles
1. **M23 is a package shell over M21, not a new teaching spine.** It may wrap,
   sequence, and explain M21, but not redefine M21’s required anchors or
   primary commands.
2. **One bounded first package beats courseware sprawl.** Land a single
   instructor/student package around the existing M21 anchors instead of
   attempting a semester-scale curriculum.
3. **Reproducibility is part of the package contract.** Every required exercise
   must resolve to committed scenarios, exact commands, and reviewable outputs.
4. **Optional branches stay secondary and explicit.** M19/M20 remain a bounded
   observability appendix; M22 remains a narrow optional embedder appendix.
5. **Docs should be machine-auditable where possible.** Packaging should reuse
   existing shortlist metadata and command-smoke patterns rather than becoming
   prose-only.

### Decision drivers (top 3)
1. **Reduce onboarding friction** for instructors/students who can currently run
   the simulator but do not yet have a single package entrypoint through the repo.
2. **Provide reproducible assignments** that can be re-run from committed repo
   state without hidden tooling, external services, or ad hoc setup.
3. **Protect scope discipline** by packaging the proven M21 teaching core rather
   than reopening M19/M20 breadth, M22 API design, or platform delivery.

### Viable options

#### Option A — Docs-only package wrapper layered on top of M21
Create a package landing page that links existing docs and commands, but keep
student/instructor materials minimal and avoid dedicated assignment documents.

**Pros**
- smallest implementation diff
- lowest maintenance burden
- keeps work concentrated in docs alignment

**Cons**
- weak “packaged distribution” feeling
- does not fully satisfy reproducible assignment/exercise intent
- onboarding remains scattered across README + labs + milestone docs

#### Option B — One bounded package shell with four primary docs over M21 (recommended)
Build a single repo-native package shell around the existing M21 shortlist: an
index, student onboarding guide, instructor guide, and one three-module
assignment pack that includes reproducibility guidance inline, with explicit
optional M19/M20 and M22 appendices.

**Pros**
- fully addresses onboarding + packaged courseware + reproducible exercises
- stays tightly bounded around already-proven M21 artifacts
- avoids extra doc sprawl by folding reproducibility into the package docs

**Cons**
- larger docs/test surface than option A
- requires careful wording to keep appendices secondary
- touches several docs and alignment tests together

#### Option C — Broader multi-week curriculum package with many labs, rubrics, and solution tracks
Create a large courseware tree spanning beginner-to-advanced content across most
repo features and optional branches.

**Pros**
- strongest standalone teaching value
- richest instructor handoff

**Cons**
- too large for a first package
- high maintenance cost and high risk of scope drift
- likely re-centers the repo around curriculum breadth instead of simulator core

### Recommended direction
**Option B wins.** M23 should ship **one bounded first package shell over M21**
with:
- one package entrypoint
- learner onboarding
- instructor delivery guidance
- one reproducible exercise/assignment pack
- explicit, secondary appendices for M19/M20 and M22

---

## 3) Recommended M23 scope (right-sized and precise)

### Core milestone decision
M23 should produce **exactly one first packaged teaching distribution** as a
shell over M21, with **four primary docs** and two bounded appendices.

### Recommended package shape

#### Primary artifacts
1. **Courseware index / package landing page**
   - one canonical “start here for teaching” document
   - explains audience, prerequisites, package structure, expected outputs, and
     time-boxed teaching flow
   - includes the package-level reproducibility checklist and entry semantics
2. **Student onboarding guide**
   - repo checkout/build/test/run path
   - exact first commands to execute
   - how to read simulator output and snapshots
   - where to go when confused
3. **Instructor guide**
   - how to run the package in one session or split across multiple sessions
   - expected observations for each anchor
   - bounded notes on common misunderstandings and what not to claim
4. **Assignment pack (single bounded first pack)**
   - three exercises/modules aligned to the M21 three-anchor shortlist
   - each exercise includes exact inputs, commands, questions, expected artifact
     types, and inline reproducibility notes

#### Bounded appendices
5. **Observability appendix (secondary only)**
   - a short appendix explaining when to show M19/M20 as offline comparison
     evidence, with explicit “not part of the main learning path” language
6. **Embedder appendix (secondary only)**
   - a short appendix pointing advanced readers to `docs/m22-library-sdk.md` and
     `zig build m22-embed-smoke` as an optional narrow extension, not part of the
     core assignment path

### Recommended courseware artifacts and likely file layout
Use a new dedicated docs subtree so M23 reads as a package rather than another
scattered milestone note.

**Recommended docs layout**
- `docs/courseware/m23-teaching-distribution.md` — canonical package index,
  single package entrypoint, and package-level reproducibility checklist
- `docs/courseware/student-onboarding.md` — learner quickstart and environment
  validation
- `docs/courseware/instructor-guide.md` — delivery notes and expected takeaways
- `docs/courseware/assignment-pack-01.md` — bounded three-module assignment set
  with inline reproducibility notes

**Recommended supporting updates**
- `README.md` — add exactly one explicit M23 courseware link below the M21 start path
- `docs/project-architecture-and-status.md` — add M23 section with scope and
  non-goals
- `docs/labs/simulator-teaching-pack.md` — remain the canonical M21 shortlist,
  but cross-link as the underlying teaching spine for M23
- `docs/m22-library-sdk.md` — link target only; no expansion expected
- `docs/m19-curated-linux-observability.md` / `docs/m20-simulator-to-trace-comparison.md`
  — link targets only; no scope broadening expected

### Recommended assignment shape
Keep the assignment pack bounded to **three modules**, each mapping directly to
one M21 anchor and one reproducibility pattern.

#### Assignment 1 — Convoy and baseline output reading
- scenario: `short-vs-long`
- policy: `fcfs`
- student task:
  - run the existing M21 primary commands
  - identify convoy effects in trace/metrics
  - answer short observation prompts
- proof artifact:
  - command transcript or pasted observations only; no new generated fixture set

#### Assignment 2 — Blocked/wakeup reasoning
- scenario: `sleep-wakeup`
- policy: `cfs-like`
- student task:
  - run the existing M21 primary commands
  - compare runnable vs blocked phases
  - explain wakeup timing in simulator terms
  - identify what is a teaching simplification vs a kernel claim
- proof artifact:
  - short written answers keyed to visible trace events / TUI inspection

#### Assignment 3 — Multicore balancing and bounded extension path
- scenario: `multicore-balancing`
- policy: `fcfs`
- student task:
  - run the existing M21 primary commands
  - inspect deterministic rebalance behavior
  - connect observations back to simulator-first wording
  - optionally note how M19/M20 or M22 relate without becoming required
- proof artifact:
  - brief explanation plus one optional extension question

### Explicitly out of scope for this first package
- a second assignment pack
- solution keys for every exercise in public student docs
- auto-grading infrastructure
- browser notebooks, web playgrounds, or hosted environments
- broad scenario-corpus repackaging beyond the M21 shortlist
- making M19/M20 or M22 required for passing the package
- redefining M21’s required anchors or replacing its primary commands

---

## 4) Concrete implementation steps with likely files

### Step 1 — Use the approved planning artifacts as implementation inputs
**Goal:** treat the saved PRD/test-spec as the implementation contract, not as
implementation outputs.

**Implementation inputs**
- `.omx/plans/prd-m23-packaged-teaching-distribution.md`
- `.omx/plans/test-spec-m23-packaged-teaching-distribution.md`
- `.omx/context/m23-packaged-teaching-distribution-20260422T201500Z.md`

**Likely implementation files**
- `README.md`
- `docs/project-architecture-and-status.md`
- `docs/labs/simulator-teaching-pack.md`

**Work**
- update README and project-status docs to describe M23 as a package shell over M21
- state explicitly that M23 may reorganize/cross-link M21, but may not redefine
  the required anchor set or primary commands
- restate that M19/M20 and M22 are optional appendices, not prerequisites

**Acceptance criteria**
- implementation docs treat the planning artifacts as inputs already decided
- README and project-status docs describe M23 as one bounded package shell over M21
- docs explicitly preserve simulator-first identity and side-lane boundaries

### Step 2 — Create the canonical M23 package entrypoint and supporting docs
**Goal:** give the repo one obvious package entrypoint with minimal doc sprawl.

**Likely files**
- `docs/courseware/m23-teaching-distribution.md`
- `docs/courseware/student-onboarding.md`
- `docs/courseware/instructor-guide.md`

**Work**
- create one landing page that describes package purpose, audiences,
  prerequisites, time estimates, navigation order, and package-level
  reproducibility checklist
- write a student onboarding guide from clone/build/test through first scenario
- write an instructor guide with suggested pacing, expected observations, and
  warnings against over-claiming Linux fidelity or production scope

**Acceptance criteria**
- a new reader can find exactly one canonical M23 entrypoint from README
- onboarding instructions are executable from repo checkout with no hidden setup
- instructor guide and student guide stay aligned on the exact M21 anchors
- the index includes package-level reproducibility guidance without needing a fifth doc

### Step 3 — Author one bounded assignment pack around the M21 shortlist
**Goal:** satisfy the roadmap’s reproducible assignment/exercise requirement
without creating endless curriculum breadth or a second teaching spine.

**Likely files**
- `docs/courseware/assignment-pack-01.md`
- `docs/labs/simulator-teaching-pack.md`
- `docs/m17-scenario-corpus.md`

**Work**
- create one assignment pack containing exactly three modules, one per M21
  anchor scenario derived from `listM21TeachingEntries()`
- for each module, specify:
  - objective
  - scenario file
  - required M21 command(s)
  - expected observable behaviors
  - short-answer prompts
  - inline reproducibility notes
- cross-link to the deeper explanation docs already in the repo instead of
  rewriting all underlying theory

**Acceptance criteria**
- the assignment pack uses exactly the M21 shortlist and no broader required set
- each assignment module uses the existing M21 primary commands
- theory references link outward to existing docs instead of duplicating them
- optional appendix references to M19/M20 and M22 are clearly marked optional

### Step 4 — Add machine-auditable alignment and smoke verification
**Goal:** make the package reviewable and drift-resistant.

**Likely files**
- `src/tests/scenario_pack_test.zig`
- `src/tests/cli_smoke_test.zig`
- `src/tests/identity_gate_test.zig`

**Work**
- add doc-alignment assertions that the M23 package derives its required anchors
  from `listM21TeachingEntries()` and preserves simulator-first wording
- add command-smoke coverage for every command shown in the onboarding guide,
  package index, and assignment pack
- add identity/boundary assertions that M23 docs do not imply browser/WASM,
  service scope, Linux-performance claims, or M19/M20-as-mainline teaching
- add checks that M19/M20 and M22 appear only as optional appendices, with M22
  limited to the existing doc plus `zig build m22-embed-smoke`

**Acceptance criteria**
- every M23 package command shown in docs is covered by smoke validation
- tests prove M23 derives the exact three-anchor simulator path from M21
- tests fail if courseware docs drift into forbidden identity claims or make appendices required

### Step 5 — Final polish for single-entrypoint semantics and package coherence
**Goal:** ensure the package feels coherent without overshooting scope.

**Likely files**
- `README.md`
- `docs/courseware/*.md`
- `docs/project-architecture-and-status.md`

**Work**
- tighten cross-links so readers move cleanly from README to the single M23
  package entrypoint, then onward to onboarding/instructor/assignment docs
- verify that every appendix is marked secondary and non-required
- keep public wording honest: simulator teaching model, not Linux fidelity or
  production platform

**Acceptance criteria**
- README presents one canonical M23 package link, not multiple competing starts
- appendices are discoverable but clearly not required
- the final docs tree reads as one bounded first package shell over M21, not an
  open-ended curriculum rewrite

---

## 5) Risks and tradeoffs

### Risk 1 — Package shell drifting into a second teaching spine
M23 could accidentally redefine the required anchors or commands while trying to
make the courseware more polished.

**Mitigation**
- codify the package-shell rule in docs and tests
- derive required anchors from `listM21TeachingEntries()`
- require M23 to reuse existing M21 primary commands

### Risk 2 — Courseware sprawl
Because “courseware” invites breadth, M23 could easily expand into many labs,
answer keys, rubrics, or advanced modules.

**Mitigation**
- cap the first package at one assignment pack with exactly three modules
- reuse M21 anchors as the required spine
- defer any second package or broader curriculum to a later milestone

### Risk 3 — Blurring simulator-first identity
Instructor/student docs may accidentally overstate Linux realism or imply that
M19/M20 are part of the mainline teaching workflow.

**Mitigation**
- repeat the simulator-first boundary in all package entry docs
- require identity/boundary assertions in tests
- keep M19/M20 and M22 in explicit appendix sections only

### Risk 4 — Reproducibility becoming prose-only
If the package is just narrative, it will drift from executable repo commands.

**Mitigation**
- keep reproducibility guidance in the package index and assignment pack
- cover all published commands with `cli_smoke_test.zig`
- tie required scenarios to committed paths and existing shortlist helpers

### Tradeoff summary
This plan favors **coherent packaging and reproducibility** over broad content
coverage. That keeps the first M23 cut intentionally small, but auditable,
maintainable, and faithful to the repo’s actual strengths.

---

## 6) Verification plan

### Required verification
1. **Single-entrypoint audit**
   - README links to exactly one canonical M23 package entrypoint
   - the package entrypoint links onward to onboarding, instructor, and
     assignment docs without creating competing “start here” paths
2. **M21 derivation audit**
   - required anchors derive exactly from `listM21TeachingEntries()`
   - M23 does not widen the required anchor set
   - M23 does not replace the existing M21 primary commands
3. **Appendix-optional audit**
   - M19/M20 references are appendix-only and explicitly non-required
   - M22 remains a narrow optional appendix limited to
     `docs/m22-library-sdk.md` and `zig build m22-embed-smoke`
4. **Assignment reproducibility audit**
   - every required exercise command uses committed scenario files and supported
     repo commands
   - no exercise depends on external services, browser tooling, or live Linux capture
5. **Command smoke verification**
   - smoke every published command in the package index, onboarding guide, and
     assignment pack through the existing CLI smoke test lane
6. **Identity/boundary audit**
   - confirm the package still describes the project as simulator-first
   - confirm docs do not imply browser/WASM, service scope, live capture,
     replay authority, or Linux-performance claims
7. **Full regression pass**
   - `zig build test --summary all`

### Minimum checks
- README links to `docs/courseware/m23-teaching-distribution.md` as the single M23 package entry
- package index links to onboarding, instructor guide, and assignment pack
- package index contains the package-level reproducibility checklist
- onboarding includes `zig build`, `zig build test --summary all`, and first-run simulator commands
- assignment pack lists committed scenario paths and exact commands for all three modules
- assignment pack does not require M19, M20, or M22 paths to complete the core package
- scenario-pack/doc alignment tests prove the M23 required anchors derive from `listM21TeachingEntries()`
- boundary tests fail if M23 docs drift into forbidden scope claims
- CLI smoke covers every command shown in M23 package docs

### Likely verification touchpoints
- `src/tests/scenario_pack_test.zig`
- `src/tests/cli_smoke_test.zig`
- `src/tests/identity_gate_test.zig`
- `README.md`
- `docs/courseware/*.md`
- `docs/labs/simulator-teaching-pack.md`
- `docs/project-architecture-and-status.md`

---

## 7) ADR-style mini section

### Decision
Adopt **one bounded repo-native package shell over M21** for M23: a canonical
courseware index, student onboarding guide, instructor guide, and one
three-module assignment pack with inline/package-level reproducibility guidance,
with M19/M20 and M22 limited to optional appendices.

### Drivers
- The roadmap requires a documented teaching path, easier onboarding, and
  reproducible assignments/exercises.
- M21 already provides the canonical simulator-first teaching spine that should
  be packaged rather than replaced.
- The repo’s identity and existing tests strongly favor deterministic,
  committed, machine-auditable proof over broad but weakly verified curriculum.

### Alternatives considered
- **Docs-only wrapper on top of M21** — rejected because it underdelivers on
  packaged distribution and reproducible assignment expectations.
- **Large multi-week curriculum package** — rejected because it creates open-
  ended curriculum sprawl and weakens milestone discipline.
- **Making M19/M20 or M22 part of the core package** — rejected because those
  branches are intentionally secondary and bounded.

### Consequences
- M23 will feel like a real first teaching distribution without pretending to be
  a complete curriculum.
- Docs/test work becomes the main implementation surface.
- Future teaching-package growth has a clear extension point, but the first
  package remains anchored to M21 rather than inventing a new spine.

### Follow-ups
- If M23 lands cleanly, a later milestone can decide whether to add a second
  package for advanced/optional work without disturbing the first package.
- If instructor demand emerges, solution/rubric material can be added later in a
  clearly segregated instructor-only or review-only surface.

---

## 8) Execution mode recommendation

### Recommended mode
**Solo `ralph` is the default recommendation.**

### Why
- The likely implementation surface is tightly coupled docs/test alignment,
  which benefits from a single owner maintaining boundary discipline.
- The package is deliberately bounded; it does not require broad parallel code
  architecture work.
- Verification is sequential and cross-cutting: README, courseware docs,
  assignment wording, and tests all need to stay aligned.

### When to prefer `$team`
Use **docs-heavy `$team`** only if execution is intentionally split into clearly
bounded lanes such as:
- one writer lane for courseware docs
- one verifier/test lane for smoke/alignment assertions
- one reviewer lane for identity/boundary wording audit

If `$team` is chosen, keep ownership disjoint:
- **Writer lane:** `README.md`, `docs/courseware/*.md`, `docs/project-architecture-and-status.md`
- **Verifier lane:** `src/tests/scenario_pack_test.zig`, `src/tests/cli_smoke_test.zig`, `src/tests/identity_gate_test.zig`
- **Boundary-review lane:** final audit of M19/M20/M22 wording and non-goals

### Staffing guidance
- **Best default:** `ralph`
- **Best team alternative:** small 3-lane docs-heavy `$team`
- **Not recommended:** large team or broad executor swarm; the scope is too
  bounded for that overhead
