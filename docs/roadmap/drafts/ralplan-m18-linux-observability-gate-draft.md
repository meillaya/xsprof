# RALPLAN-DR Draft — M18 Linux-observability planning gate

- Status: Draft for consensus review
- Date: 2026-04-21
- Milestone: M18
- Scope: planning gate only; no Linux trace ingestion or calibration implementation is authorized by this draft

## Repo-local evidence base
- `docs/adr/0001-m5-project-identity.md`
  - M5 approved a broader scheduler-laboratory roadmap with a simulator-only mainline and explicitly gated optional branches.
  - The optional Linux-observability branch (`M19 -> M20`) is blocked on `M18` approval.
- `docs/project-architecture-and-status.md`
  - States that `M18` is the gate "before any Linux-facing import/calibration work".
  - Lists Linux kernel scheduler docs, `sched(7)`, cgroups/CPU controller docs, deadline docs, and NUMA/scheduler-domain docs as required grounding references before stronger claims.
- `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md`
  - Defines `M18` as the approval event for deciding whether the repo may ingest or reference real Linux scheduler traces/data.
  - Requires ADR coverage for provenance, support burden, privacy/safety, and scope wording.
- `docs/roadmap/test-spec-multi-horizon-zig-scheduler-roadmap.md`
  - Requires ADR approval, explicit provenance/support policy, and an audit that no ingestion code begins before approval.
- `docs/linux-mapping.md`
  - Current truthfulness boundary: simulator-only, user-space only, no kernel integration/eBPF hooks, no Linux-fidelity claims.

## RALPLAN-DR

### Principles
1. **Truthfulness before capability** — repo wording must stay narrower than the implementation can prove.
2. **Gate before code** — `M18` is a decision milestone, not an implementation milestone.
3. **Provenance-first observability** — any future Linux-facing artifact must carry source, capture method, license/redistribution basis, and curation metadata.
4. **Privacy/safety by default** — future trace handling must assume host/process metadata may be sensitive unless explicitly scrubbed and documented.
5. **Support burden must be budgeted, not implied** — supported formats, kernel/version assumptions, and maintenance obligations must be explicitly bounded before approval.
6. **Mainline identity remains simulator-first** — even a GO outcome must not blur current simulator-local wording or rebrand the repo as a Linux trace tool.

### Decision drivers
1. Preserve the M5 identity contract: simulator-only mainline, optional branches only through explicit gates.
2. Avoid accidental overclaiming from importing real Linux scheduler data.
3. Decide whether maintainers are willing to own provenance, privacy review, and format/version support obligations.
4. Keep future verification objective: approval must produce auditable go/no-go criteria, not soft intent.
5. Reuse the repo's existing documentation posture that already points to Linux scheduler docs as terminology/grounding references.

### Viable options

#### Option A — **NO-GO / keep Linux-observability branch closed**
- Decision: do not authorize `M19 -> M20` now.
- Pros:
  - lowest privacy/support burden
  - preserves the cleanest simulator-only message
  - no new provenance or redistribution risk surface
- Cons:
  - blocks real-trace comparison work entirely
  - reduces the roadmap's external observability branch to dormant backlog
- When to choose:
  - maintainers do not want ongoing trace-format/support obligations
  - provenance/licensing/privacy posture is not yet strong enough

#### Option B — **Conditional GO for curated observability-only branch**
- Decision: authorize `M19` only under a narrow observability charter; `M20` remains separately gated by scope wording and calibration caveats.
- Guardrails:
  - **offline snapshot fixtures only**
  - **approved capture families only**: Linux scheduler trace snapshots derived from official observability interfaces such as `perf sched` / perf tracepoint recordings or tracefs/ftrace scheduler event snapshots
  - **no live ingestion, live tracing, capture tooling, automation, eBPF workflows, or perf/ftrace execution workflows in-repo for M19**
  - **no replay-fidelity, calibration-semantic, Linux-performance, or kernel-faithful claim**
  - mandatory provenance manifest + privacy scrub policy + **version-tuple support matrix** before code lands
  - **committed scrubbed fixtures only** for in-repo samples; manifest-only references are insufficient for approved M19 fixtures
- Pros:
  - unlocks bounded, evidence-backed comparison inputs
  - keeps branch narrow and auditable
  - aligns with current roadmap wording for optional Linux-observability work
- Cons:
  - creates ongoing maintenance and documentation burden
  - requires strong wording discipline to avoid Linux-performance/fidelity drift
- When to choose:
  - maintainers explicitly want observability-only imports and accept bounded maintenance work

#### Option C — **Full GO for broader Linux-facing ingest/calibration work**
- Decision: broadly open `M19` and `M20` as normal next implementation work.
- Why it is not recommended now:
  - conflicts with the repo's current simulator-first truthfulness band
  - under-specifies privacy, provenance, and support obligations
  - risks converting a gate into an implementation shortcut

### Recommended plan
Recommend **Option B: Conditional GO for a curated observability-only branch**, with explicit ability to resolve to NO-GO if the ADR cannot close provenance/privacy/support questions convincingly.

Reasoning:
- It is the narrowest option that still honors the roadmap's explicit optional Linux-observability branch.
- It preserves the M5 identity contract by keeping the mainline simulator-first and the Linux-facing work opt-in and caveated.
- It turns `M18` into a real governance gate by requiring hard artifacts before any code starts.

### Explicit go / no-go outcomes

#### GO outcome
Approve `M19` planning-to-implementation handoff only if the ADR/PRD/test-spec set establishes all of the following:
- permitted source classes for **offline** trace snapshots
- approved capture-family boundary (for example `perf sched` / perf tracepoint-derived scheduler snapshots, tracefs/ftrace scheduler-event snapshots) and explicit exclusion of live capture automation
- provenance manifest requirements per imported artifact
- privacy/safety scrub policy for host/process/user-identifying fields
- redistribution/licensing position for **committed scrubbed sample traces**
- supported **version tuples** for each approved fixture family:
  - kernel version
  - capture tool + version
  - snapshot/export format version
  - scrub-policy version
- explicit unsupported-version rule: anything not listed is out of scope by default
- wording guardrails that forbid replay-fidelity, Linux-performance, or kernel-faithful claims
- verification plan for provenance checks, fixture admission, version-tuple enforcement, no-live-capture audits, fixture separation, and docs wording audits
- repo proof-surface updates covering:
  - `README.md`
  - `docs/project-architecture-and-status.md`
  - roadmap docs / ADR links
  - a governance/audit test surface analogous to `src/tests/identity_gate_test.zig`

#### NO-GO outcome
If any of the above remain unresolved, keep the Linux-observability branch closed:
- `M19` and `M20` stay blocked
- no parser/importer/calibration code starts
- roadmap/docs may record the branch as deferred or rejected, but repo identity remains unchanged

## ADR shape (for approval artifact)

### Proposed ADR title
`ADR 0002: M18 Linux-observability gate for curated trace snapshots`

### Required ADR sections
1. **Context**
   - M5 identity baseline
   - why Linux-observability is an optional branch rather than mainline work
   - current repo-local wording constraints from `docs/linux-mapping.md`
2. **Decision**
   - GO or NO-GO
   - if GO, explicitly state "observability-only" and what remains out of scope
3. **Decision drivers**
   - provenance
   - support burden
   - privacy/safety
   - truthfulness/scope wording
   - verification feasibility
4. **Alternatives considered**
   - closed branch / defer indefinitely
   - conditional curated-snapshot path
   - broader ingest/calibration opening
5. **Capture boundary decision**
   - offline-only rule
   - approved capture families
   - explicit ban on live capture/tooling/automation in M19
6. **Version support contract**
   - approved version tuples only
   - unsupported-by-default rule
7. **Fixture admission policy**
   - committed scrubbed fixtures only
   - manifest required per fixture
8. **Repo proof surfaces**
   - README / project-status / roadmap / governance test surfaces
9. **Consequences**
   - docs/roadmap wording changes required
   - maintenance obligations accepted or declined
   - what future milestones become eligible
10. **Approval conditions / follow-ups**
   - PRD/test-spec artifacts required before coding
   - explicit statement that `M19` is blocked until this ADR is approved

## PRD shape (post-approval execution brief)

### Proposed PRD title
`prd-m19-curated-linux-observability.md`

### Required PRD sections
- **Goal**: bounded import of curated Linux scheduler trace snapshots for observability/comparison only
- **Non-goals**:
  - no live kernel instrumentation in this milestone
  - no fidelity/replay claim
  - no production monitoring/tooling charter
- **User/value statement**: why curated traces help teaching/comparison without redefining the repo
- **Input scope**:
  - allowed **offline** trace source classes
  - approved capture families
  - explicit exclusion of live capture/tooling/automation for M19
  - allowed sample sizes / artifact forms
  - required provenance manifest fields
- **Version support contract**:
  - approved tuple table
  - unsupported versions are out of scope unless explicitly added
- **Privacy/safety policy**:
  - required scrubbed fields
  - forbidden sensitive fields unless explicitly anonymized
- **Fixture admission policy**:
  - committed scrubbed fixtures only
  - manifest required per fixture
  - manifest-only external references are not sufficient for approved in-repo M19 fixtures
- **Support policy**:
  - supported formats/versions
  - unsupported capture stacks and kernels
  - maintenance boundary for parser breakage
- **Acceptance criteria**:
  - fixture separation from simulator-native assets
  - provenance metadata present and validated
  - docs wording stays observability-only
- **Risks**
- **Milestone-specific verification commands/checks**

## Test-spec shape (post-approval verification brief)

### Proposed test-spec title
`test-spec-m19-curated-linux-observability.md`

### Required verification categories
1. **ADR approval audit** — confirm approved ADR exists before code or data ingestion lands.
2. **Provenance checks** — each imported sample has manifest metadata and source traceability.
3. **Privacy/safety checks** — sample fixtures match scrub policy; forbidden fields are absent or normalized.
4. **Fixture admission checks** — only committed scrubbed fixtures with manifests are admitted.
5. **Version-tuple checks** — unsupported kernel/tool/format/scrub tuples fail clearly; supported tuples are explicit.
6. **Boundary checks** — imported data remains separated from simulator-native fixtures and report contracts.
7. **Docs wording audit** — README / roadmap / Linux-mapping wording stays within approved offline observability-only scope.
8. **No-live-capture audit** — M19 docs/tests do not authorize live tracing, automation, or in-repo perf/ftrace execution workflows.

## Available agent types for follow-up
Use only after `M18` approval outcome is accepted.

- `planner` — finalize ADR/PRD/test-spec package or re-open consensus if GO/NO-GO is disputed
- `architect` — own ADR wording, scope boundaries, and approval conditions
- `researcher` — gather official Linux scheduler doc references and licensing/provenance guidance if external confirmation is needed
- `dependency-expert` — evaluate whether any future trace parsing dependency is justified before adoption
- `explore` — map current repo touchpoints for docs, fixtures, and import boundaries
- `executor` — implement approved `M19` scope only after gate approval
- `writer` — tighten wording audits and user-facing caveats
- `verifier` — block merge until provenance/privacy/support/doc checks pass
- `critic` / `code-reviewer` — challenge scope creep and overclaiming before approval or merge

## Suggested execution mode after approval
- **For M18 itself:** stay in `ralplan` / planning-architect mode only.
- **If GO:** execute `M19` under `$team` with dedicated lanes for:
  1. provenance/data-model contract,
  2. import boundary/parsing,
  3. docs + wording + privacy policy,
  4. verification.
- **If NO-GO:** no implementation mode; land ADR/roadmap wording only and keep branch blocked.

## Consensus handoff notes
- This draft intentionally does **not** authorize Linux trace ingestion code.
- Approval should be binary and recorded in ADR form.
- If reviewers want narrower scope, the safest fallback is Option A (NO-GO) rather than broadening Option B informally.
- The governing phrase for M19 should be: **approved offline snapshot fixtures with strict version tuples and auditable repo boundaries**.
