// Performance Advisor — a pure function over aggregates that emits findings
// and concrete, evidence-backed recommendations (sched_setaffinity / NUMA
// placement hints). It never touches the kernel and never mutates anything;
// recommendations are printed suggestions, never auto-applied.
// See docs/rewrite/ADVISOR.md.
#pragma once

#include <string>
#include <vector>

#include "xsprof/json.hpp"
#include "xsprof/pipeline.hpp"
#include "xsprof/proc.hpp"

namespace xsprof::advisor {

// Re-export the frozen pipeline Aggregates so existing advisor consumers
// (tests, CLI) can keep using xsprof::advisor::Aggregates unchanged.
using Aggregates = xsprof::pipeline::Aggregates;

enum class Severity { Info, Warning, Critical };
enum class Confidence { Measured, Heuristic };

std::string severity_name(Severity s);
std::string confidence_name(Confidence c);

struct Recommendation {
    std::string kind;   // "sched_setaffinity" | "numa_bind" | "tuning"
    std::string detail; // copy-pasteable suggestion
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

// Configurable named thresholds for all seven detection rules.
// Defaults are sensible production-tuned values; override per-deployment.
struct Thresholds {
    // Rule 1: False sharing — minimum remote HITM rate to fire (PMU path).
    double false_sharing_hitm_min = 0.05;

    // Rule 2: Excessive locking — minimum average lock wait (ms).
    double excessive_lock_wait_ms = 1.0;
    // Minimum lock contentions count to consider.
    long long excessive_lock_contentions_min = 1;

    // Rule 3: Unnecessary wakeups — ratio threshold (unnecessary / total).
    double unnecessary_wakeup_ratio = 0.30;

    // Rule 4: CPU affinity churn — minimum migrations to fire.
    long long affinity_churn_migrations_min = 100;

    // Rule 5: Poor NUMA placement — minimum remote fault ratio.
    double numa_remote_fault_ratio = 0.20;

    // Rule 6: Allocator fragmentation — minimum buddy fragmentation index.
    double allocator_fragmentation_min = 0.50;

    // Rule 7: Priority inversion — boolean observation (no numeric threshold,
    // but included here for structural completeness and future extension).
    bool priority_inversion_enabled = true;
};

class Advisor {
  public:
    // Construct with default thresholds.
    Advisor() = default;
    // Construct with custom thresholds.
    explicit Advisor(Thresholds t) : thresholds_(t) {}

    // Access the active thresholds (for introspection / testing).
    const Thresholds& thresholds() const { return thresholds_; }

    // Run all rules; returns findings ranked by severity then evidence strength.
    std::vector<Finding> analyze(const Aggregates& agg) const;
    json::Value report_json(const Aggregates& agg) const;
    std::string report_markdown(const Aggregates& agg) const;

  private:
    Thresholds thresholds_;
};

// Derive a read-only Aggregates from a SystemFacts snapshot (Phase-1 path that
// works without privilege; signals that need PMU/tracepoints stay at zero and
// are marked uncollected so no false findings are emitted).
Aggregates aggregates_from_facts(const SystemFacts& facts);

} // namespace xsprof::advisor
