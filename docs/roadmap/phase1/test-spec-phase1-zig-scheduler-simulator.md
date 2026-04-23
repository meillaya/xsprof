# Test Spec — Phase 1 User-Space CPU Scheduling Simulator in Zig

## Status
Draft — ralplan consensus artifact

## Purpose
Define the verification shape for Phase 1 so implementation can be judged against explicit, deterministic criteria.

## Scope Under Test
- Zig project scaffold
- In-process scheduler simulation
- FCFS/FIFO policy
- Round Robin policy
- Simplified CFS-inspired policy
- Trace or timeline output
- Metrics output
- Linux-mapping documentation
- Phase-boundary compliance

## Out of Scope
- Real process execution
- Kernel integration
- Daemon or service behavior
- Performance benchmarking as a release gate

---

## Test Strategy

### Test levels
1. **Unit tests**
   - domain types
   - scheduler engine transitions
   - metrics calculations
   - policy behavior
2. **Scenario tests**
   - fixed multi-task scenarios
   - expected ordering and summary metrics
   - deterministic trace assertions where practical
   - one golden-oracle scenario with exact expected completion order and exact summary metrics
3. **CLI/integration smoke tests**
   - run selected scenario with chosen policy
   - verify output includes trace or timeline and metrics
4. **Documentation verification**
   - confirm docs map behavior to Linux concepts
   - confirm simplifications and non-goals are explicit
5. **Negative/scope-boundary verification**
   - confirm no process spawning, kernel hooks, or daemon semantics exist

---

## Required Scenarios

### Scenario A — Staggered arrivals
**Purpose**
Validate arrival handling and waiting-time accounting.

**Shape**
- 3 to 4 tasks
- different arrival times
- moderate CPU bursts

**Expected**
- tasks are not runnable before arrival
- waiting and turnaround metrics are stable and deterministic
- policy differences are visible

### Golden oracle requirement
`Scenario C — Short-job versus long-job contention` is the golden oracle and must be implemented via scenario fixture data plus assertions in `src/tests/scenarios_test.zig`.

**Minimum oracle assertions**
- exact completion order
- exact per-task waiting time
- exact per-task turnaround time
- exact per-task response time
- exact aggregate average waiting time
- exact aggregate average response time
- exact throughput
- stable trace-event ordering for key events

### Golden oracle assertions by policy
#### FCFS exact oracle
- completion order: `L -> S1 -> S2`
- completion times: `L=8`, `S1=10`, `S2=11`
- turnaround times: `L=8`, `S1=9`, `S2=9`
- waiting times: `L=0`, `S1=7`, `S2=8`
- response times: `L=0`, `S1=7`, `S2=8`
- average waiting time: `5`
- average response time: `5`
- throughput: `3/11`

#### Round Robin exact oracle
- slice dispatch order: `L -> S1 -> S2 -> L`
- completion order: `S1 -> S2 -> L`
- completion times: `S1=4`, `S2=5`, `L=11`
- turnaround times: `S1=3`, `S2=3`, `L=11`
- waiting times: `S1=1`, `S2=2`, `L=3`
- response times: `L=0`, `S1=1`, `S2=2`
- average waiting time: `2`
- average response time: `1`
- throughput: `3/11`

#### CFS-inspired oracle scope
- Phase 1 requires bounded invariants, not exact golden-oracle output, unless the implementation docs freeze exact vruntime arithmetic before coding starts.
- Minimum invariants on Scenario C:
  - at least one short task completes before `L`
  - deterministic output for repeated runs
  - documented explanation of why the observed order follows the chosen vruntime update rule

### Scenario B — Equal-arrival contention
**Purpose**
Validate queue ordering and fairness behavior when tasks compete at the same time.

**Shape**
- 3+ tasks arriving at time 0
- similar burst sizes

**Expected**
- FCFS preserves insertion/order semantics
- Round Robin interleaves execution by quantum
- CFS-inspired policy shows different selection/accounting behavior than FCFS

### Scenario C — Short-job versus long-job contention
**Purpose**
Show latency and fairness tradeoffs clearly.

**Shape**
- `L`: arrival `0`, burst `8`
- `S1`: arrival `1`, burst `2`
- `S2`: arrival `2`, burst `1`
- Round Robin quantum: `2`

**Expected**
- traces and metrics show policy tradeoffs
- docs can reuse this scenario as an explanatory example

---

## Testable Acceptance Matrix

| Capability | Verification |
| --- | --- |
| Build succeeds on Zig 0.15.2 | `zig build` and `zig build test` pass |
| In-process simulation only | code inspection + tests; no OS process launch paths |
| 3 policies supported | scenario tests execute FCFS, RR, and CFS-inspired |
| Deterministic behavior | repeated runs on same inputs match |
| Trace/timeline exists | output contains ordered execution events |
| Per-task metrics exist | includes completion time, turnaround time, waiting time, and response time |
| Aggregate metrics exist | includes average waiting time, average response time, throughput, and waiting-time spread |
| Linux mapping docs exist | docs review confirms mapping + simplifications |
| Phase boundaries preserved | verifier review confirms no phase creep |

---

## Unit Test Requirements

### Engine and domain invariants
- task state transitions are valid
- completion time is never before arrival
- total executed time per task equals required burst
- simulation terminates when all tasks complete
- idle ticks are handled correctly if no task is runnable
- arrivals for tick `t` are incorporated before dispatch for tick `t`
- if completion and quantum expiry coincide on the same tick, completion wins
- same-arrival ties are deterministic and stable
- policy-specific tie overrides fall back to stable scenario input declaration order when primary comparison keys are equal
- trace events preserve engine semantics even if CLI output is compressed

### Metric invariants
- completion_time = tick immediately after the task’s final executed tick
- turnaround = completion - arrival
- waiting time is never negative
- response_time = first_dispatch_tick - arrival_tick
- average waiting time equals the mean of per-task waiting times
- average response time equals the mean of per-task response times
- throughput = completed_task_count / (last_completion_tick - earliest_arrival_tick)
- waiting_time_spread = max(waiting_time) - min(waiting_time)

### Policy invariants
#### FCFS
- non-preemptive once a task is chosen, unless the implementation explicitly documents otherwise
- preserves ready-queue order for same-arrival tasks

#### Round Robin
- preempts at quantum boundary when peers are runnable
- no runnable task is starved in bounded finite scenarios
- completion beats preemption when both would occur on the same tick

#### Simplified CFS-inspired
- selection is based on accumulated virtual-runtime-style fairness accounting
- behavior differs from FCFS in at least one fixed scenario
- implementation is documented as not kernel-faithful Linux CFS
- deterministic tie-breaking for equal vruntime falls back to stable scenario input declaration order
- Phase 1 explicitly excludes nice weights, sleeper bonuses, SMP balancing, and cgroups/group scheduling

---

## Integration and Smoke Verification

### CLI expectations
For at least one canned scenario and one named or file-driven scenario path:
- select policy
- run simulation
- print readable summary
- print trace or timeline
- print aggregate metrics
- allow compressed human-readable output as long as the underlying event trace remains deterministic and testable
- include explicit sections for scenario name, policy name, completion order, per-task metrics, and aggregate metrics

### Output expectations
Output should include enough structure to verify:
- task identifier
- selected execution intervals or per-tick events
- completion ordering
- summary metrics

Exact formatting may evolve during implementation, but it must remain deterministic and testable.

### Raw trace access requirement
Tests must assert deterministic engine semantics through a library-level raw trace object or equivalent non-compressed programmatic interface; verification must not depend on scraping compressed CLI output.

---

## Documentation Verification Checklist

Implementation is incomplete unless documentation states:
- Phase 1 is a simulator only
- No real process execution occurs
- No kernel integration occurs
- The implemented policies are Linux-inspired, not full Linux scheduler replicas
- The CFS-like policy is simplified
- Major omitted Linux concerns are listed

### Recommended omitted concerns list
- SMP or multi-core balancing
- scheduler classes beyond current scope
- cgroups or group scheduling
- kernel timing precision and interrupts
- priority inheritance and many kernel edge cases

---

## Risk-Based Verification Focus

### Highest-risk areas
1. **CFS-inspired naming and correctness expectations**
   - verify docs do not overclaim fidelity
2. **Determinism**
   - verify repeated runs match for fixed inputs
   - verify ordering rules are encoded in tests rather than inferred from implementation
3. **Scope creep**
   - verify no accidental process-management abstractions appear
4. **Metric correctness**
   - verify formulas against manually reasoned small scenarios
   - verify the frozen Scenario C oracle values for FCFS and Round Robin exactly

---

## Failure Conditions

Phase 1 is incomplete if any of the following occur:
- fewer than 3 runnable policies are implemented
- outputs are not deterministic for fixed scenarios
- docs do not explain Linux mapping and simplifications
- simulator launches or controls real OS processes
- implementation markets the CFS-inspired policy as faithful Linux CFS
- tests exist only for happy-path build and not for scheduling behavior

---

## Verification Sequence
1. Build scaffold passes
2. Engine and unit invariants pass
3. Policy-specific tests pass
4. Required scenarios pass under all policies
5. CLI smoke output is reviewed
6. Docs are checked against actual implementation
7. Final verifier confirms acceptance criteria and phase boundaries

---

## Agent Staffing for Verification

### Ralph path
- `executor` — high
- `verifier` — high
- `test-engineer` — medium
- `architect` — medium/high optional

### Team path
- `executor` owns simulator core
- `test-engineer` owns scenarios and assertions
- `writer` owns doc conformance
- `verifier` owns acceptance-gate review

### Launch hints
- Run verification after each major step, not only at the end
- Treat documentation verification as mandatory, not polish
- If CFS-like behavior or naming becomes contentious, route to `critic` or `architect` before widening scope

---

## Improvements Applied
- Planner draft split cleanly between product scope and verification responsibilities
- Scenario requirements aligned with the Phase 1 Linux-learning outcomes
- Verification explicitly includes doc conformance and anti-scope-creep checks
- Architect review applied: added golden-oracle assertions, deterministic ordering invariants, and a narrower CFS-inspired Phase 1 contract
