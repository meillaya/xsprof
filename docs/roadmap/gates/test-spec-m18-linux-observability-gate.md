# Test Spec — M18 Linux-observability planning gate

## Status
Approved planning gate artifact on 2026-04-21

## Scope under test
- the ADR/governance decision itself
- provenance/support/privacy/scope completeness
- explicit blocking of M19/M20 until approval
- correctness of future execution handoff guidance

## Required verification
1. **ADR approval exists before any implementation begins**
   - M18 must produce an explicit GO or NO-GO ADR.
2. **Provenance policy is explicit**
   - allowed source classes are stated
   - required manifest metadata is stated
   - approved capture families are stated
3. **Privacy/safety policy is explicit**
   - sensitive identifiers/fields are called out
   - scrub or exclusion expectations are documented
4. **Support burden is explicit**
   - supported version tuples are bounded:
     - kernel
     - capture tool + version
     - snapshot/export format version
     - scrub-policy version
   - unsupported-by-default rule is explicit
   - non-goals and unsupported areas are named
5. **Fixture admission policy is explicit**
   - committed scrubbed fixtures only
   - mandatory manifest per fixture
   - manifest-only external references are either forbidden or explicitly marked out of scope for approved in-repo fixtures
6. **Scope wording is explicit**
   - offline observability-only wording is present if GO
   - replay-fidelity / calibration-semantic / Linux-performance claims are explicitly rejected
   - live capture, automation, and in-repo perf/ftrace execution workflows are explicitly rejected for M19
7. **No-code-before-approval audit**
   - confirm M19/M20 code or trace-data admission does not begin before the M18 decision is approved
   - confirm repo proof surfaces are updated atomically with the decision:
     - `README.md`
     - `docs/project-architecture-and-status.md`
     - roadmap docs / ADR links
     - governance test surface analogous to `src/tests/identity_gate_test.zig`
8. **Execution-path audit**
   - if GO, future execution re-enters planning/execution only through approved PRD/test-spec artifacts
   - if NO-GO, branch remains blocked with no implementation handoff

## Minimum checks
- ADR review against provenance, support burden, privacy/safety, and scope wording
- docs/roadmap/README audit confirming M18 is a gate, not an implementation milestone
- no-code-before-approval audit for the Linux-observability branch
- capture-boundary audit: M19 is offline-only and excludes live tracing/tooling/automation
- version-tuple audit: supported tuples are named and unsupported tuples are explicitly out of scope
- fixture admission audit: committed fixtures must be scrubbed and manifested
- explicit GO/NO-GO decision audit
- follow-up mode audit: M19 must re-enter via approved planning/execution path, not direct coding from the M18 draft alone

## Non-goals for this milestone
- trace import code
- trace parsing dependency adoption
- perf/ftrace capture automation in-repo
- simulator-to-trace comparison/calibration logic
