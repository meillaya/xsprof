# PRD — M18 Linux-observability planning gate

## Status
Draft for consensus review on 2026-04-21

## 1) Task framing and assumption check

### Framing
M18 is a governance/approval milestone, not an implementation milestone. Its job is to decide whether this repository may open the optional Linux-observability branch for curated scheduler trace snapshots, and under what constraints.

### Assumption check
The working assumption is valid from repo and official evidence:
- `docs/adr/0001-m5-project-identity.md` approved a simulator-only mainline with optional branches gated explicitly.
- `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md` and `docs/roadmap/test-spec-multi-horizon-zig-scheduler-roadmap.md` define M18 as the approval event for the optional Linux-observability branch.
- `docs/linux-mapping.md` keeps the current truthfulness boundary simulator-only, user-space only, and non-kernel-integrated.
- Official Linux docs establish that any future observability path would rely on version-sensitive scheduler behavior, tracepoints/tracefs/ftrace, and `perf sched`, with non-trivial privilege/privacy/support implications.

### Scope boundary
This milestone may produce:
- an ADR decision (GO or NO-GO)
- explicit provenance/privacy/support/scope rules
- planning artifacts for future work only if GO is chosen

This milestone must not produce:
- Linux trace ingestion code
- live tracing capture features
- replay-fidelity or Linux-performance claims
- implicit approval of M19/M20 without explicit decision artifacts

---

## 2) Principles
1. **Truthfulness before capability.** The repo must not claim more Linux fidelity than it can prove.
2. **Gate before code.** M18 is the approval event; no ingest/calibration code starts before it is approved.
3. **Observability is not replay.** Any future Linux-facing branch must stay observability-only unless a later gate re-charters it.
4. **Provenance and privacy are first-class.** Data origin, scrub policy, and redistribution posture must be explicit before code lands.
5. **Support burden must be bounded.** Supported kernels, formats, and tool assumptions must be documented as a contract, not discovered ad hoc.
6. **Mainline remains simulator-first.** Even a GO outcome must not blur the M5 identity contract.

---

## 3) Decision drivers
1. Preserve the approved M5 simulator-first mainline identity.
2. Avoid accidental overclaiming from real Linux scheduler trace data.
3. Decide whether maintainers accept provenance/privacy/licensing/support obligations.
4. Make approval auditable through ADR + PRD + test-spec artifacts.
5. Keep M19/M20 blocked unless scope is narrow enough to verify honestly.

---

## 4) Viable options

### Option A — NO-GO / keep the Linux-observability branch closed
Do not authorize M19/M20 now.

**Pros**
- lowest privacy and maintenance burden
- preserves the simplest simulator-only message
- avoids redistribution/provenance risk

**Cons**
- blocks real-trace comparison work entirely
- leaves the optional branch dormant

### Option B — Conditional GO for a curated observability-only branch
Authorize M19 planning/execution only under a narrow observability-only charter.

**Hard constraints**
- offline snapshot fixtures only
- approved capture families only (for example `perf sched` / perf tracepoint-derived scheduler snapshots or tracefs/ftrace scheduler-event snapshots)
- no live capture in-repo
- no capture tooling or automation in-repo
- no eBPF / ftrace / perf execution workflows in-repo for M19
- no replay-fidelity claim
- no Linux-performance benchmarking claim
- provenance manifest required per imported artifact
- privacy scrub policy required before committed fixtures land
- version-tuple support matrix required for formats/kernel/tool assumptions
- committed scrubbed fixtures only; manifest-only references are not sufficient for approved in-repo M19 fixtures

**Pros**
- unlocks bounded educational comparison inputs
- keeps the branch explicit and auditable
- aligns best with the existing roadmap structure

**Cons**
- creates lasting maintenance and wording burden
- requires strict governance to avoid branch creep

### Option C — Broad GO for general Linux ingest/calibration work
Open M19/M20 as ordinary next implementation milestones.

**Why not recommended**
- too broad for the current truthfulness band
- under-specifies privacy/provenance/support obligations
- turns a gate into an implementation shortcut

---

## 5) Recommendation
Recommend **Option B: Conditional GO for a curated observability-only branch**, with explicit fallback to NO-GO if the ADR cannot close the required concerns convincingly.

### Why this is the right shape
- It preserves the M5 simulator-first mainline while still honoring the roadmap’s optional Linux-observability branch.
- It forces approval to be earned through explicit provenance, privacy, support, and wording commitments.
- It keeps M19/M20 narrow enough to verify without overstating Linux fidelity.

### GO conditions
A GO outcome must establish all of the following before any M19 code starts:
- allowed source classes for imported trace snapshots
- allowed **capture families** and explicit exclusion of live-capture workflows
- provenance manifest requirements
- privacy/safety scrub policy
- redistribution/licensing stance for committed sample traces
- supported **version tuples**:
  - kernel version
  - capture tool + version
  - snapshot/export format version
  - scrub-policy version
- unsupported-by-default rule for anything not listed
- explicit wording guardrails forbidding replay-fidelity and Linux-performance claims
- verification plan for provenance, fixture admission, version-tuple, boundary, and wording audits
- repo proof-surface updates for:
  - `README.md`
  - `docs/project-architecture-and-status.md`
  - roadmap/ADR link surfaces
  - governance/audit test surfaces analogous to `src/tests/identity_gate_test.zig`

### NO-GO conditions
If any of the above remain unresolved, the branch stays closed:
- M19 and M20 remain blocked
- no importer/parser/calibration code lands
- docs/roadmap may record deferral, but repo identity stays unchanged

---

## 6) ADR package shape

### Proposed ADR title
`ADR 0002: M18 Linux-observability gate for curated trace snapshots`

### Required ADR sections
1. Context
2. Decision (GO or NO-GO)
3. Decision drivers
4. Alternatives considered
5. Capture boundary decision
6. Version support contract
7. Fixture admission policy
8. Repo proof surfaces
9. Consequences
10. Approval conditions / follow-ups

### Required ADR decision content
- If GO: explicitly say observability-only, curated snapshots only, and what remains out of scope.
- If NO-GO: explicitly say the Linux-observability branch remains closed and why.

---

## 7) Follow-on PRD shape if GO is approved

### Proposed title
`prd-m19-curated-linux-observability.md`

### Required sections
- goal
- non-goals
- allowed source classes
- approved capture families
- explicit ban on live capture/tooling/automation for M19
- provenance manifest fields
- approved version-tuple table
- unsupported-by-default rule
- privacy/safety scrub policy
- committed fixture + manifest policy
- support matrix
- acceptance criteria
- risks
- milestone-specific verification

---

## 8) Follow-on test-spec shape if GO is approved

### Proposed title
`test-spec-m19-curated-linux-observability.md`

### Required verification categories
1. gate audit
2. provenance checks
3. privacy/safety checks
4. boundary checks
5. docs wording audit
6. support-matrix checks

---

## 9) Available agent types for follow-up
- `planner`
- `architect`
- `critic`
- `researcher`
- `explore`
- `writer`
- `verifier`
- `executor` (only after GO)
- `dependency-expert` (if future parser/dependency choices arise)

---

## 10) Suggested execution mode after approval
- **For M18 itself:** remain in planning/ADR mode only.
- **If GO:** use `$team` for M19 because provenance, parsing, docs, and verification are independent lanes.
- **If NO-GO:** no implementation mode; land ADR/roadmap wording only.

---

## 11) Team verification path for a future GO outcome
1. verify approved ADR exists
2. verify allowed source classes + approved capture families + support matrix are explicit
3. verify privacy scrub policy is documented and testable
4. verify committed fixture + manifest policy is enforced
5. verify imported fixtures are separated from simulator-native fixtures
6. verify wording stays offline observability-only and rejects replay/performance overclaims
7. verify no live capture/tooling/automation scope has slipped into M19
