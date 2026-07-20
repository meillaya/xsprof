# ADVISOR — Performance Advisor & Recommendation Engine

Research deliverable for mission `cpp-sched-mem-profiler`. The advisor turns correlated scheduler +
memory evidence into findings and concrete, evidence-backed optimization recommendations.

## 1. Design principle

The advisor is a **pure function over aggregates**: it never touches the kernel and never mutates
anything. It reads the aggregation tables produced by the pipeline and emits a report. Every finding
carries the evidence rows that justify it and a confidence label (`measured` vs. `heuristic`). This
keeps the advisor read-only and testable against golden fixtures.

## 2. Rule engine

```cpp
struct Finding {
  std::string id;            // e.g. "false-sharing", "priority-inversion"
  Severity sev;              // info | warning | critical
  std::string summary;
  std::vector<EvidenceRef> evidence;  // pointers into the aggregate/journal
  std::vector<Recommendation> recs;
  Confidence confidence;     // measured | heuristic
};

class Rule {
public:
  virtual std::string id() const = 0;
  virtual std::vector<Finding> evaluate(const Aggregates&) = 0;
};
```

Rules are registered in a table; the report is the union of all rule outputs, de-duplicated and
ranked by severity then evidence strength.

## 3. Detection rules (vision coverage)

| Finding | Detection (from aggregates) | Evidence |
| --- | --- | --- |
| **false sharing** | two+ threads incur high cache-line write traffic / LLC misses on the same 64B line region (sampled callchains + `perf c2c`-style HITM via IBS/PEBS) | per-line remote-HITM counts |
| **excessive locking** | high `lock:contention_begin` rate or long lock wait time per site; lock hold time >> work time | contention wait histogram |
| **unnecessary wakeups** | `sched_wakeup` events whose woken task is not switched to within a window, or wakeups of a task that immediately sleeps again | wakeup->switch correlation |
| **CPU affinity issues** | frequent `sched_migrate_task` for a task that would fit on one LLC domain; cross-LLC migrations with cold caches | migration count + LLC topology |
| **poor NUMA placement** | task's CPU node != its dominant memory node (from `numa_maps` + `numa_hint_faults` remote ratio) | local/remote fault ratio |
| **allocator inefficiencies** | high small-alloc churn, fragmentation in `/proc/buddyinfo`, large resident-but-unmapped slack | alloc-site hotspot + buddyinfo |
| **priority inversion** | high-prio task blocked on a lock owned by a low-prio task that was preempted | lock-owner + sched_switch chain |

## 4. Recommendation synthesis (the "bonus")

For affinity/NUMA findings the advisor emits concrete, copy-pasteable calls — labeled as
**suggestions**, never auto-applied:

```c
// suggestion: pin worker threads 4121,4122 to LLC domain 0 (cpus 0-7) to stop cross-LLC migration
sched_setaffinity(4121, {0xff});        // cpus 0-7
sched_setaffinity(4122, {0xff});
// NUMA placement hint: bind allocations of pid 4121 to node 0 (local fault ratio 0.42 -> target >0.9)
numa_bind(node 0);  // or: numactl --membind=0 --cpunodebind=0 ./app
```

Recommendation rules:
- **Affinity**: group tasks by communication (shared wakeups) and by LLC domain; propose a mask that
  minimizes observed migrations while respecting the measured run-queue load (do not oversubscribe).
- **NUMA**: when remote-fault ratio > threshold and a dominant node exists, recommend
  `--membind`/`mbind` to that node; otherwise recommend interleaving for bandwidth-bound workloads.
- Every recommendation prints the metric that triggered it and the expected effect, and is gated by
  `safety`: the framework can *print* `sched_setaffinity`/NUMA hints but will not *call* them on a
  target process unless an explicit, audited opt-in path is enabled (and on the host that path is
  refused by default).

## 5. Report formats

- `report.json` — machine-readable findings + recommendations + evidence refs.
- `report.md` — human markdown with a ranked table and per-finding detail.
- Both embed the collection capability table so a reader knows which signals were `SKIP`/`REFUSE`
  (a finding is never emitted from a signal that was not actually collected).

## 6. Testability

Each rule is unit-tested against synthetic aggregates and against golden fixtures derived from the
deterministic simulator scenarios (e.g. `multicore-contention`, `topology-domains`). A rule must
produce zero findings on a healthy baseline fixture and the expected finding on the stressed fixture.

## 7. Evidence vs. inference

Grounded: detection signals map to the collectors in `COLLECTORS.md` (tracepoints, PMU/IBS,
`/proc/<pid>/numa_maps`, `/proc/buddyinfo`). Assumption (labeled): precise false-sharing detection
benefits from `perf c2c`/PEBS/IBS HITM data which requires `CAP_PERFMON`; without it the rule degrades
to a heuristic based on LLC-miss callchain clustering and marks `confidence=heuristic`.
