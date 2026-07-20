// Performance Advisor — a pure function over aggregates that emits findings
// and concrete, evidence-backed recommendations (sched_setaffinity / NUMA
// placement hints). It never touches the kernel and never mutates anything;
// recommendations are printed suggestions, never auto-applied.
// See docs/rewrite/ADVISOR.md.
#pragma once

#include <string>
#include <vector>

#include "xsprof/json.hpp"
#include "xsprof/proc.hpp"

namespace xsprof::advisor {

enum class Severity { Info, Warning, Critical };
enum class Confidence { Measured, Heuristic };

std::string severity_name(Severity s);
std::string confidence_name(Confidence c);

struct Recommendation {
    std::string kind;    // "sched_setaffinity" | "numa_bind" | "tuning"
    std::string detail;  // copy-pasteable suggestion
    std::string rationale;
};

struct Finding {
    std::string id;
    Severity sev = Severity::Info;
    Confidence confidence = Confidence::Measured;
    std::string summary;
    std::vector<std::string> evidence;
    std::vector<Recommendation> recs;
    json::Value to_json() const;
};

// Aggregate inputs the rules reason over. These are derived from the pipeline
// (or directly from a read-only snapshot for the fail-closed Phase-1 path).
struct Aggregates {
    // NUMA / placement
    double remote_fault_ratio = 0.0;   // remote / (local+remote) hint faults
    int dominant_node = -1;            // node holding most of a task's memory
    int task_cpu_node = -1;            // node the task mostly runs on
    // affinity / migration
    long long migrations = 0;          // sched_migrate_task count for a task group
    int llc_domains = 1;               // number of LLC domains observed
    bool cross_llc_migration = false;
    // locking
    long long lock_contentions = 0;
    double avg_lock_wait_ms = 0.0;
    // wakeups
    long long wakeups = 0;
    long long unnecessary_wakeups = 0; // wakeup not followed by a switch in-window
    // cache / memory
    long long llc_misses = 0;
    long long tlb_misses = 0;
    long long page_faults = 0;
    double remote_hitm = 0.0;          // cross-cache-line HITM (false sharing signal)
    // allocator
    double buddy_fragmentation = 0.0;  // 0..1 derived from /proc/buddyinfo
    long long small_alloc_churn = 0;
    // priority inversion
    bool priority_inversion_observed = false;
    // capability context (a finding is never emitted from an uncollected signal)
    bool pmu_collected = false;
    bool sched_collected = false;
};

class Advisor {
public:
    // Run all rules; returns findings ranked by severity then evidence strength.
    std::vector<Finding> analyze(const Aggregates& agg) const;
    json::Value report_json(const Aggregates& agg) const;
    std::string report_markdown(const Aggregates& agg) const;
};

// Derive a read-only Aggregates from a SystemFacts snapshot (Phase-1 path that
// works without privilege; signals that need PMU/tracepoints stay at zero and
// are marked uncollected so no false findings are emitted).
Aggregates aggregates_from_facts(const SystemFacts& facts);

} // namespace xsprof::advisor
