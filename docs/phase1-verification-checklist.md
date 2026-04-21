# Phase 1 Verification Checklist

Use this checklist when reviewing the implementation against:
- `.omx/plans/prd-sequential-milestones-zig-scheduler-roadmap.md` (M1.5 section)
- `.omx/plans/test-spec-sequential-milestones-zig-scheduler-roadmap.md` (M1.5 section)

## 1. Build and project scaffold

- [ ] `zig build` succeeds on Zig `0.15.2`
- [ ] `zig build test` succeeds
- [ ] the project is still stdlib-only unless a later decision explicitly changes that
- [ ] source layout cleanly separates simulator core, policies, tests, and CLI concerns

## 2. Scope-boundary checks

Implementation must remain Phase-1 only:
- [ ] no real process execution
- [ ] no kernel integration
- [ ] no daemon/service/cron behavior
- [ ] no SMP or multi-core scheduling claims

Suggested review search terms for accidental phase creep:
- `std.process`
- `fork`
- `exec`
- `clone`
- `sched_`
- `epoll`
- `daemon`
- `systemd`

## 3. Policy coverage

- [ ] FCFS/FIFO baseline exists
- [ ] Round Robin exists
- [ ] simplified CFS-inspired policy exists
- [ ] the CFS-inspired policy is documented as simplified and not kernel-faithful

## 4. Deterministic engine semantics

- [ ] arrivals for tick `t` are applied before dispatch for tick `t`
- [ ] same-arrival ties are stable and deterministic
- [ ] policy-specific ties fall back to scenario declaration order
- [ ] idle ticks are represented in the raw trace
- [ ] completion beats Round Robin preemption when both occur on the same tick
- [ ] repeated runs on the same scenario produce identical raw results

## 5. Trace and metrics surface

- [ ] raw trace access exists for tests
- [ ] CLI output includes scenario name and policy name
- [ ] CLI output includes completion order
- [ ] CLI output includes per-task metrics
- [ ] CLI output includes aggregate metrics
- [ ] CLI supports mutually exclusive `--scenario` / `--scenario-file` run inputs
- [ ] JSON export includes the expected schema/version markers

Required per-task metrics:
- [ ] completion time
- [ ] turnaround time
- [ ] waiting time
- [ ] response time

Required aggregate metrics:
- [ ] average waiting time
- [ ] average response time
- [ ] throughput
- [ ] waiting-time spread

## 6. Scenario coverage

- [ ] Scenario A: staggered arrivals
- [ ] Scenario B: equal-arrival contention
- [ ] Scenario C: short-job versus long-job contention

## 7. Golden oracle for Scenario C

Scenario C definition:
- `L`: arrival `0`, burst `8`
- `S1`: arrival `1`, burst `2`
- `S2`: arrival `2`, burst `1`
- Round Robin quantum: `2`

### FCFS expected oracle
- [ ] completion order `L -> S1 -> S2`
- [ ] completion times `L=8`, `S1=10`, `S2=11`
- [ ] turnaround times `L=8`, `S1=9`, `S2=9`
- [ ] waiting times `L=0`, `S1=7`, `S2=8`
- [ ] response times `L=0`, `S1=7`, `S2=8`
- [ ] average waiting time `5`
- [ ] average response time `5`
- [ ] throughput `3/11`

### Round Robin expected oracle
- [ ] slice dispatch order `L -> S1 -> S2 -> L`
- [ ] completion order `S1 -> S2 -> L`
- [ ] completion times `S1=4`, `S2=5`, `L=11`
- [ ] turnaround times `S1=3`, `S2=3`, `L=11`
- [ ] waiting times `S1=1`, `S2=2`, `L=3`
- [ ] response times `L=0`, `S1=1`, `S2=2`
- [ ] average waiting time `2`
- [ ] average response time `1`
- [ ] throughput `3/11`

### CFS-inspired required invariants
- [ ] at least one short task completes before `L`
- [ ] repeated runs are deterministic
- [ ] docs explain why the observed order follows the chosen vruntime update rule

## 8. Documentation checks

- [ ] docs state that Phase 1 is a simulator only
- [ ] docs explicitly say no real process execution occurs
- [ ] docs explicitly say no kernel integration occurs
- [ ] docs explain Linux inspiration without overclaiming fidelity
- [ ] docs list major omitted Linux concerns

Recommended omissions to verify are named:
- [ ] nice weights
- [ ] sleeper bonus heuristics
- [ ] SMP or multi-core balancing
- [ ] per-CPU run queues
- [ ] cgroups or group scheduling
- [ ] kernel timing precision and interrupts

## 9. Suggested final verification commands

Run these once implementation lands in the integration branch:

```sh
zig build
zig build test
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario-file scenarios/basic/arrivals.zon --policy fcfs
zig build run -- --scenario short-vs-long --policy rr --quantum 2 --format json
```

## 10. Review outcome template

Use this structure in the final integration report:

- Build: PASS/FAIL
- Tests: PASS/FAIL
- Determinism: PASS/FAIL
- Metrics formulas: PASS/FAIL
- Docs fidelity wording: PASS/FAIL
- Scope boundaries preserved: PASS/FAIL
- Notes: follow-up fixes or mismatches
