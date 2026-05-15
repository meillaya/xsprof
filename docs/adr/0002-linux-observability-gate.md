# ADR 0002: M18 Linux-observability gate for curated trace snapshots

- Status: Approved
- Date: 2026-04-21
- Milestone: M18
- Related roadmap: `docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md`
- Related test spec: `docs/roadmap/gates/test-spec-m18-linux-observability-gate.md`

## Context
M5 approved the repository as a broader scheduler laboratory roadmap with a
**simulator-only mainline** and optional branches gated explicitly. The roadmap
already reserves an optional Linux-observability branch (`observability -> comparison`), but it
also states that no Linux-facing import/calibration work may begin until M18 is
approved.

The current implementation remains:
- simulator-only
- user-space only
- deterministic and testable
- not a kernel scheduler, capture tool, or performance-monitoring product

Official Linux documentation confirms that any future Linux-facing trace work is
not neutral:
- scheduler semantics are version-sensitive
- official observability surfaces include tracepoints, tracefs/ftrace, and
  `perf sched`
- perf/trace outputs can expose sensitive host/process identifiers, timestamps,
  addresses, and configuration details
- access and safety are bounded by `perf_event_paranoid`, `CAP_PERFMON`, and
  operational constraints around sampling/capture

M18 therefore must decide whether the repo opens any Linux-observability path at
all, and if so, how narrowly that path is constrained.

## Decision
Approve a **conditional GO** for the optional Linux-observability branch, but
only under a strictly bounded charter:

> future Linux-facing work is limited to **offline, observability-only,
> version-pinned, scrubbed snapshot fixtures**.

This approval does **not** authorize:
- live tracing in the repo
- capture tooling or automation in the repo
- eBPF, tracefs/ftrace, or `perf` execution workflows in the repo for observability
- replay-fidelity claims
- Linux-performance or calibration claims
- any code for observability/comparison before milestone-specific PRD/test-spec artifacts exist

This ADR approves eligibility for the optional branch only. It does not approve
implementation details for observability or comparison by itself.

## Decision drivers
1. Preserve the M5 simulator-first mainline identity.
2. Allow optional observability work only if it can stay narrower than the repo
   can truthfully support.
3. Force provenance, privacy, redistribution, and support obligations to be
   explicit before any code starts.
4. Keep future verification auditable through concrete repo proof surfaces and
   tests, not only prose.
5. Keep the Linux-observability branch useful for teaching/comparison without
   turning the repo into a live tracing or kernel tooling project.

## Alternatives considered

### Option A — NO-GO / keep the branch closed
Reject Linux-observability work entirely for now.

**Why not chosen**
- it is the cleanest simulator-only boundary, but it discards an explicitly
  planned optional branch that can still be kept narrow and truthful

### Option B — GO for offline observability-only snapshot fixtures
Authorize only offline, scrubbed, version-pinned snapshot fixtures with strong
governance rules.

**Why chosen**
- it is the narrowest option that still honors the roadmap’s optional
  Linux-observability branch
- it keeps the mainline simulator-first while making future work auditable

### Option C — broad GO for general ingest/calibration work
Open Linux-facing ingest/calibration work as ordinary implementation.

**Why rejected**
- too broad for the current truthfulness band
- under-specifies privacy, provenance, and support burden
- would turn a gate milestone into an implementation shortcut

## Capture boundary decision
If the optional Linux-observability branch proceeds, it is limited to:
- **offline snapshot fixtures only**
- **approved capture families only**, such as:
  - `perf sched` / perf tracepoint-derived scheduler snapshots
  - tracefs/ftrace scheduler-event snapshots

Out of scope for observability unless a later gate re-charters them:
- live tracing
- capture automation
- in-repo execution of `perf`, tracefs/ftrace, or eBPF collection workflows
- continuous/system monitoring
- replay or calibration semantics

## Version support contract
Supported imported fixtures must be approved as explicit tuples:
- kernel version
- capture tool + version
- snapshot/export format version
- scrub-policy version

Unsupported tuples are **out of scope by default** until they are explicitly
added to approved docs/tests.

The branch may describe Linux-facing observations only within the bounds of the
approved tuples; it must not generalize across unapproved kernel/tool versions.

## Fixture admission policy
Approved in-repo Linux-observability fixtures must be:
- committed
- scrubbed
- redistributable under an explicit documented basis
- accompanied by a provenance manifest

Manifest-only external references are not sufficient for approved in-repo observability
fixtures.

Each admitted fixture must document:
- source class
- capture family
- kernel/tool/version tuple
- scrub-policy version
- redistribution/licensing basis
- any caveats needed to keep observability-only wording truthful

## Repo proof surfaces
This decision must be reflected in:
- `README.md`
- `docs/project-architecture-and-status.md`
- roadmap / ADR link surfaces
- governance tests analogous to `src/tests/identity_gate_test.zig`

These surfaces must make the following clear:
- the mainline implementation remains simulator-only today
- the optional Linux-observability branch, if pursued, is offline and
  observability-only
- live capture/tooling/automation remains out of scope for observability

## Consequences
- The optional Linux-observability branch is now eligible in principle.
- observability remains blocked until its own PRD/test-spec package exists and follows
  this ADR.
- The repo still cannot claim Linux replay fidelity, Linux performance meaning,
  or kernel-faithful scheduling behavior.
- Future maintainers accept the governance overhead of provenance manifests,
  scrub policy, version tuples, and wording audits if they pursue observability.

## Approval conditions / follow-ups
Before any observability code or fixtures land:
1. create milestone-specific PRD and test-spec artifacts
2. define approved fixture families and version tuples concretely
3. define fixture manifests and scrub policy concretely
4. update README / project status / roadmap wording atomically
5. add governance/audit tests proving:
   - no-code-before-approval
   - offline-only observability scope
   - fixture admission policy
   - version-tuple enforcement
   - wording boundaries

## Approval signoff
M18 is approved by landing this ADR together with proof-surface updates that:
- keep the repo’s current implementation simulator-only
- authorize only an offline observability-only future branch
- block direct observability implementation until milestone-specific planning artifacts
  exist
