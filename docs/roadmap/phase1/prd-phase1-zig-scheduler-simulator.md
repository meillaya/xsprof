# PRD — Phase 1 User-Space CPU Scheduling Simulator in Zig

## Status
Draft — ralplan consensus artifact

## Scope
Phase 1 only: a user-space, in-process CPU scheduling simulator in Zig for learning Linux scheduler concepts.

## Repo-grounded facts
- Inputs reviewed:
  - `.omx/specs/deep-interview-linux-scheduler-in-zig.md`
  - `.omx/context/linux-scheduler-in-zig-20260420T051336Z.md`
  - `.omx/interviews/linux-scheduler-in-zig-20260420T053432Z.md`
- Current repo state:
  - No Zig implementation files yet
  - Reference docs only:
    - `docs/zig-master-language-reference.txt`
    - `docs/zig-master-stdlib-reference.txt`
- Local Zig version:
  - `0.15.2`

---

## Requirements Summary

### Goal
Build a focused Zig project that teaches CPU scheduling concepts in a Linux-relevant way through a simulator, not through real process control or kernel integration.

### In scope
- Pure user-space CPU scheduling simulator
- Linux-inspired policies that can be compared
- Deterministic simulation inputs and outputs
- Traces, timelines, and metrics showing scheduler behavior
- Documentation mapping simulator constructs to Linux concepts
- Explicit documentation of simplifications versus real Linux scheduling

### Out of scope
- Running or controlling real Linux processes
- Kernel hooks, modules, eBPF, or scheduler integration
- Daemon, service, cron, or task-runner behavior
- Phase 2 or Phase 3 work

### Functional requirements
1. Model tasks/jobs with arrival time and CPU burst demand.
2. Support multiple selectable scheduling policies.
3. Produce per-run observable outputs:
   - execution trace
   - per-task completion stats
   - aggregate metrics
4. Allow reproducible scenarios from fixed inputs.
5. Include documentation connecting simulator behavior to Linux scheduling ideas.
6. Define deterministic simulation semantics for:
   - tick ordering within a simulation step
   - same-arrival tie breaking
   - Round Robin quantum-expiry versus completion ordering
   - idle-tick handling
   - trace event kinds and their meaning

### Recommended Phase 1 policy set
- FCFS/FIFO baseline
- Round Robin
- Simplified CFS-inspired policy using virtual runtime style accounting

### Minimum simulation semantics contract
- Each tick processes work in a fixed order: incorporate arrivals for the current tick, decide dispatch/preemption, execute one tick of work, then record resulting completion/preemption state.
- Same-arrival ties use a deterministic stable order from scenario input declaration order, and policy-specific overrides fall back to that same stable order when their primary comparison keys are equal.
- If a task both exhausts its remaining burst and reaches a Round Robin quantum boundary on the same tick, completion wins over preemption.
- Idle ticks are represented explicitly in the engine and trace layer even if the CLI later compresses them for readability.
- `TraceEntry` must support at least these event kinds: `arrival`, `dispatch`, `tick`, `preempt`, `complete`, `idle`.

### Minimum Phase 1 CFS-inspired contract
- Phase 1 selects the runnable task with the lowest virtual-runtime-style accounting value, then uses a deterministic tie-breaker.
- Phase 1 does **not** model nice weights, sleeper bonus heuristics, SMP balancing, cgroups/group scheduling, or kernel timing precision.
- Documentation and CLI output must describe this policy as **CFS-inspired** or **simplified CFS-like**, never as faithful Linux CFS.

### Non-functional requirements
- Educational clarity first
- Deterministic behavior for tests
- Small, reviewable codebase
- No external dependencies beyond Zig stdlib unless later justified
- Compatible with Zig `0.15.2`

---

## Testable Acceptance Criteria

Phase 1 is complete when all of the following are true:

1. **Build scaffold exists**
   - A Zig project builds successfully on local Zig `0.15.2`.

2. **Simulator core exists**
   - The code simulates a finite set of tasks in-process without spawning OS processes.

3. **Policy comparison exists**
   - At least 3 policies are runnable against the same scenario:
     - FCFS/FIFO
     - Round Robin
     - simplified CFS-inspired policy

4. **Observability exists**
   - Each run emits:
     - a scheduling trace or timeline
     - per-task metrics including completion time, turnaround time, waiting time, and response time
     - aggregate metrics including at least average waiting time, average response time, throughput, and waiting-time spread
   - Metric formulas are fixed as:
     - `completion_time = tick immediately after the task’s final executed tick`
     - `turnaround_time = completion_time - arrival_tick`
     - `waiting_time = turnaround_time - burst_ticks`
     - `response_time = first_dispatch_tick - arrival_tick`
     - `throughput = completed_task_count / (last_completion_tick - earliest_arrival_tick)` in tasks per tick
     - `waiting_time_spread = max(waiting_time) - min(waiting_time)` across completed tasks
   - Latency visibility is satisfied by response time metrics, and fairness visibility is satisfied by waiting-time spread plus per-task waiting time comparison.
   - Engine traces preserve deterministic underlying events even if CLI output compresses repeated idle or execution spans for readability.

5. **Deterministic test scenarios exist**
   - At least 3 fixed scenarios are included:
     - staggered arrivals
     - CPU-bound equal-arrival contention case
     - short-job versus long-job contention case

6. **Linux relevance is documented**
   - Documentation explains:
     - what each implemented policy represents
     - how the CFS-inspired model differs from real Linux CFS
     - which Linux scheduler concerns are intentionally omitted

7. **Phase boundaries are preserved**
   - No real process execution
   - No kernel integration
   - No daemon, service, or cron behavior

---

## RALPLAN-DR Summary

### Principles
1. **Educational clarity over kernel fidelity**
2. **Linux relevance without kernel coupling**
3. **Deterministic, test-first simulation behavior**
4. **Small greenfield design with room for later phases**
5. **Observability is a feature, not an afterthought**

### Decision Drivers
1. **Learning value** — the simulator must teach scheduler tradeoffs, not just run tasks.
2. **Linux mapping** — Phase 1 must stay recognizably Linux-inspired.
3. **Scope discipline** — the first milestone must remain small enough to complete cleanly.

### Viable Options

#### Option A — Tick-driven discrete-time simulator
Model time in integer ticks; at each tick update arrivals, select a runnable task, execute one tick (or one quantum step), and record trace events.

**Pros**
- Easy to reason about and visualize
- Natural fit for Round Robin
- Simple deterministic traces
- Good pedagogically for step-by-step scheduler behavior

**Cons**
- Less elegant for long idle gaps and event jumps
- CFS-inspired accounting is somewhat more approximate
- More loop iterations for longer scenarios

#### Option B — Event-driven simulator
Advance time from event to event (arrival, quantum expiry, completion, preemption point) instead of iterating every tick.

**Pros**
- Cleaner representation of sparse scheduling changes
- Lower conceptual runtime cost for sparse scenarios
- Easier later extension toward richer simulations

**Cons**
- Harder to teach initially
- More bookkeeping complexity in a greenfield repo
- Less transparent traces unless extra trace infrastructure is added

### Recommendation
**Choose Option A: tick-driven discrete-time simulator.**

### Why Chosen
- Best matches the educational-first requirement
- Simplifies deterministic testing and trace generation
- Keeps the initial architecture small and comprehensible
- Still leaves room to evolve internals later if Phase 2 or Phase 3 needs richer mechanics

---

## Implementation Steps

### Step 1 — Scaffold Zig project and simulation domain
**Likely files**
- `build.zig`
- `build.zig.zon`
- `src/main.zig`
- `src/lib.zig`
- `src/sim/types.zig`
- `src/sim/scenario.zig`

**Deliverable**
- Minimal Zig build and test entrypoints
- Core domain types:
  - `Task`
  - `TaskState`
  - `SimulationConfig`
  - `TraceEntry`
  - `Metrics`
  - deterministic tie-break metadata or scenario ordering contract

**Acceptance check**
- `zig build`
- `zig build test`

### Step 2 — Implement simulation engine
**Likely files**
- `src/sim/engine.zig`
- `src/sim/queue.zig`
- `src/sim/trace.zig`
- `src/sim/metrics.zig`

**Deliverable**
- Tick-driven simulation loop
- Task arrival and completion handling
- Trace recording
- Aggregate metric calculation
- Explicit engine ordering rules for arrivals, dispatch, execution, completion, preemption, and idle ticks
- Library-level access to the raw deterministic trace so tests can assert engine semantics without scraping CLI presentation output

**Acceptance check**
- Deterministic tests for arrivals, execution, completion, and metrics

### Step 3 — Implement policies
**Likely files**
- `src/policies/policy.zig`
- `src/policies/fcfs.zig`
- `src/policies/round_robin.zig`
- `src/policies/cfs_like.zig`

**Deliverable**
- Shared policy dispatch interface
- FCFS baseline
- Round Robin with configurable quantum
- Simplified CFS-inspired scheduler using vruntime-like accounting with a documented minimum rule: select the runnable task with the lowest vruntime and resolve ties deterministically
- Explicit exclusions for Phase 1: no nice weights, no sleeper bonus, no SMP balancing, no cgroups/group scheduling

**Acceptance check**
- Same scenario runs under all policies
- Tests verify distinct scheduling behavior

### Step 4 — Add scenario fixtures and CLI output
**Likely files**
- `src/cli/args.zig`
- `src/cli/output.zig`
- `src/main.zig`
- `scenarios/basic/arrivals.zon`
- `scenarios/basic/contention.zon`
- `scenarios/basic/short-vs-long.zon`

**Deliverable**
- Run a named or file-based scenario
- Select policy
- Print timeline, trace, and metrics
- Keep scenario data in a Zig-native or easily parsed text format suitable for deterministic tests
- Permit `src/cli/output.zig` to compress repeated idle or uninterrupted execution spans while `src/sim/trace.zig` preserves deterministic event-level trace data
- Designate `scenarios/basic/short-vs-long.zon` as the golden-oracle scenario with this fixed fixture:
  - `L`: arrival `0`, burst `8`
  - `S1`: arrival `1`, burst `2`
  - `S2`: arrival `2`, burst `1`
  - Round Robin quantum: `2`
- Freeze golden-oracle assertions as:
  - **FCFS exact assertions**: completion order `L -> S1 -> S2`; completion times `8, 10, 11`; waiting times `0, 7, 8`; average waiting time `5`; average response time `5`; throughput `3/11`
  - **Round Robin exact assertions**: slice dispatch order `L -> S1 -> S2 -> L`; completion order `S1 -> S2 -> L`; completion times `4, 5, 11`; waiting times `S1=1`, `S2=2`, `L=3`; average waiting time `2`; average response time `1`; throughput `3/11`
  - **CFS-inspired assertions**: bounded invariants only in Phase 1 unless implementation docs freeze exact vruntime arithmetic before coding starts

**Acceptance check**
- Manual runs show deterministic output with explicit sections for scenario name, policy name, completion order, per-task metrics, and aggregate metrics
- At least 3 canned scenarios are runnable
- `scenarios/basic/short-vs-long.zon` is designated as the golden oracle with exact expected completion order and summary metrics

### Step 5 — Add docs and Linux mapping
**Likely files**
- `README.md`
- `docs/phase1-simulator.md`
- `docs/linux-mapping.md`

**Deliverable**
- Usage instructions
- What each policy teaches
- Simplifications versus Linux
- Clear phase-boundary statement

**Acceptance check**
- A new contributor can understand the simulator goal and limitations from docs alone

### Step 6 — Harden tests and finalize Phase 1 verification
**Likely files**
- `src/tests/simulator_test.zig`
- `src/tests/policies_test.zig`
- `src/tests/scenarios_test.zig`
- `src/tests/cli_smoke_test.zig`

**Deliverable**
- Coverage for invariants and representative scenarios
- Stable verification workflow

**Acceptance check**
- All tests pass
- No known mismatch between documented and actual simulator behavior

---

## Risks and Mitigations

### Risk 1 — “Linux-inspired” becomes too vague
**Mitigation**
- Explicitly document each policy’s Linux relationship
- Call the third policy “CFS-inspired” rather than “Linux CFS”

### Risk 2 — Scope creep into real scheduling or daemon work
**Mitigation**
- Preserve strict non-goals in docs and tests
- Keep interfaces simulation-centric, not OS-process-centric

### Risk 3 — CFS simplification becomes misleading
**Mitigation**
- Use bounded terminology such as “simplified”, “inspired by”, and “not kernel-faithful”
- List omitted concepts such as SMP load balancing, sleeper heuristics, priorities, group scheduling, and kernel timing details
- Freeze the minimum CFS-inspired selection rule in the plan and tests before implementation starts

### Risk 4 — Determinism claims drift because ordering rules are implicit
**Mitigation**
- Define tick ordering and tie-break rules up front in `src/sim/types.zig`, `src/sim/engine.zig`, and `src/sim/trace.zig`
- Require at least one golden scenario with exact expected ordering and metrics
### Risk 5 — Empty repo leads to over-architecture
**Mitigation**
- Start with a small module graph
- Avoid plugin-style abstractions until at least 3 policies exist

### Risk 6 — Zig 0.15.2 build friction on initial scaffold
**Mitigation**
- Keep build and test setup minimal
- Avoid premature package or dependency complexity

---

## Verification Steps

1. **Build verification**
   - Confirm project builds on Zig `0.15.2`
2. **Unit verification**
   - Validate task lifecycle transitions
   - Validate metric calculations
   - Validate policy-specific expected orderings
3. **Scenario verification**
   - Run fixed scenarios across all policies
   - Confirm outputs are deterministic
   - Confirm the frozen golden-oracle exact assertions for FCFS and Round Robin, plus bounded invariants for the CFS-inspired policy
4. **Behavior verification**
   - Confirm Round Robin differs from FCFS in preemption behavior
   - Confirm the CFS-inspired policy changes ordering or accounting relative to FCFS in at least one scenario
5. **Documentation verification**
   - Confirm docs state simplifications and non-goals
   - Confirm Linux concept mapping is explicit and bounded
6. **Phase-boundary verification**
   - Confirm no code path launches processes, uses kernel APIs, or implements daemon semantics

---

## ADR

### Decision
Adopt a tick-driven, user-space CPU scheduling simulator with FCFS, Round Robin, and a simplified CFS-inspired policy for Phase 1.

### Drivers
- Learning system internals with Linux relevance
- Need for a narrow first milestone
- Greenfield repo with no existing implementation
- Need for deterministic tests and readable traces

### Alternatives considered
1. **Event-driven simulator**
   - Better event abstraction, but more complex for the first educational milestone
2. **Real process or task scheduler daemon**
   - More OS-realistic at the interface level, but violates the clarified Phase 1 scope
3. **Kernel-adjacent experiment first**
   - Highest Linux fidelity, but too large and risky for the initial milestone

### Why chosen
This path best matches the clarified interview outcome: start simple, stay Linux-relevant, and optimize for learning clarity rather than runtime realism.

### Consequences
**Positive**
- Faster path to a working artifact
- Clearer tests and documentation
- Better teaching value for scheduler basics
- A frozen semantics contract reduces avoidable engine and test churn

**Negative**
- Not a faithful Linux kernel scheduler
- Some Linux behaviors will be intentionally absent
- Later phases may justify internal refactoring
- Tick-driven internals still trade some semantic elegance for pedagogical transparency

### Follow-ups
- After Phase 1, evaluate whether Phase 2 should reuse the scenario and model layer
- Decide later whether to extend the policy set or pivot into daemon or kernel-adjacent work
- Reassess whether event-driven internals become worthwhile for later phases

---

## Available-Agent-Types Roster
- `explore`
- `planner`
- `architect`
- `executor`
- `debugger`
- `verifier`
- `test-engineer`
- `critic`
- `writer`
- `researcher`
- `build-fixer`
- `code-reviewer`
- `performance-reviewer`
- `security-reviewer`
- `code-simplifier`

## Follow-up Staffing Guidance

### Ralph path
Use `ralph` when one owner should implement and verify sequentially.

**Suggested lanes**
- `executor` — high — owns scaffold, simulator core, and policies
- `test-engineer` — medium — hardens scenario and invariant tests
- `verifier` — high — validates acceptance criteria and phase boundaries
- `architect` — medium/high optional — reviews module boundaries before policy growth

**Launch hints**
- Start only after both plan artifacts are approved
- Keep the first execution loop focused on scaffold plus engine
- Treat CFS-like behavior as bounded educational logic, not a fidelity race

**Ralph verification path**
1. Scaffold/build green
2. Core engine tests green
3. Policy comparison tests green
4. Scenario and CLI outputs verified
5. Linux-mapping docs reviewed against implementation
6. Final verifier pass confirms no phase-boundary violations

### Team path
Use `team` only if work is split into low-conflict lanes.

**Recommended staffing**
1. `executor` — high  
   Ownership: `build.zig`, `src/sim/**`, `src/policies/**`
2. `test-engineer` — medium  
   Ownership: `src/tests/**`, scenario assertions, deterministic validation
3. `writer` — medium  
   Ownership: `README.md`, `docs/phase1-simulator.md`, `docs/linux-mapping.md`
4. `verifier` — high  
   Ownership: end-to-end evidence and scope-boundary verification

**Optional support lanes**
- `architect` — medium/high for upfront review of module boundaries
- `build-fixer` — high only if Zig 0.15.2 build friction appears
- `critic` — high for pre-implementation challenge of policy/design assumptions

**Launch hints**
- Keep write ownership disjoint across simulator core, tests/scenarios, and docs
- Avoid parallel edits to the same policy dispatch files unless one executor owns them
- Do not add dependencies without revisiting the plan
- Suggested command hint: `$team docs/roadmap/phase1/prd-phase1-zig-scheduler-simulator.md`
- Alternative CLI hint: `omx team run docs/roadmap/phase1/prd-phase1-zig-scheduler-simulator.md`

**Team verification path**
1. Core executor lane merges scaffold and engine
2. Test lane validates deterministic scenarios against implemented policies
3. Writer lane aligns docs with actual behavior, not intended behavior
4. Verifier lane checks acceptance criteria, ADR alignment, and no phase creep
5. Final leader review resolves doc/code mismatches before completion

---

## Improvements Applied
- Initial planner draft normalized into repo-ready artifact paths
- Scenario fixtures narrowed toward Zig-native deterministic data files
- Acceptance criteria and follow-up staffing aligned to explicit Phase 1 boundaries
- Architect review applied: added deterministic tick-order contract, narrowed the CFS-inspired Phase 1 rule, and required a golden-oracle scenario plus trace/CLI separation
