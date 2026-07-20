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
