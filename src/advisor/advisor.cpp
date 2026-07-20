#include "xsprof/advisor.hpp"

#include <algorithm>
#include <sstream>

namespace xsprof::advisor {

std::string severity_name(Severity s) {
    switch (s) {
        case Severity::Info: return "info";
        case Severity::Warning: return "warning";
        case Severity::Critical: return "critical";
    }
    return "info";
}

std::string confidence_name(Confidence c) {
    return c == Confidence::Measured ? "measured" : "heuristic";
}

json::Value Finding::to_json() const {
    json::Value v = json::Value::make_object();
    v.set("id", json::Value(id));
    v.set("severity", json::Value(severity_name(sev)));
    v.set("confidence", json::Value(confidence_name(confidence)));
    v.set("summary", json::Value(summary));
    json::Value ev = json::Value::make_array();
    for (const auto& e : evidence) ev.push_back(json::Value(e));
    v.set("evidence", ev);
    json::Value rs = json::Value::make_array();
    for (const auto& r : recs) {
        json::Value rj = json::Value::make_object();
        rj.set("kind", json::Value(r.kind));
        rj.set("detail", json::Value(r.detail));
        rj.set("rationale", json::Value(r.rationale));
        rs.push_back(rj);
    }
    v.set("recommendations", rs);
    return v;
}

namespace {
int severity_rank(Severity s) {
    switch (s) {
        case Severity::Critical: return 2;
        case Severity::Warning: return 1;
        case Severity::Info: return 0;
    }
    return 0;
}
} // namespace

std::vector<Finding> Advisor::analyze(const Aggregates& agg) const {
    std::vector<Finding> out;

    // Rule: poor NUMA placement.
    if (agg.remote_fault_ratio > 0.20 && agg.dominant_node >= 0 &&
        agg.task_cpu_node >= 0 && agg.dominant_node != agg.task_cpu_node) {
        Finding f;
        f.id = "poor-numa-placement";
        f.sev = Severity::Warning;
        f.confidence = Confidence::Measured;
        std::ostringstream ev;
        ev << "remote_fault_ratio=" << agg.remote_fault_ratio
           << " dominant_mem_node=" << agg.dominant_node << " task_cpu_node=" << agg.task_cpu_node;
        f.summary = "Task memory is dominated by a NUMA node different from where it runs.";
        f.evidence.push_back(ev.str());
        Recommendation r;
        r.kind = "numa_bind";
        r.detail = "numactl --membind=" + std::to_string(agg.dominant_node) +
                   " --cpunodebind=" + std::to_string(agg.dominant_node) + " ./app";
        r.rationale = "Bind memory and CPU to node " + std::to_string(agg.dominant_node) +
                      " to raise the local-fault ratio toward >0.9.";
        f.recs.push_back(r);
        out.push_back(std::move(f));
    }

    // Rule: CPU affinity issues (excessive cross-LLC migration).
    if (agg.sched_collected && agg.cross_llc_migration && agg.migrations > 100) {
        Finding f;
        f.id = "cpu-affinity-churn";
        f.sev = Severity::Warning;
        f.confidence = Confidence::Measured;
        f.summary = "Frequent cross-LLC migrations are cooling caches for a migratory task group.";
        f.evidence.push_back("migrations=" + std::to_string(agg.migrations) +
                             " llc_domains=" + std::to_string(agg.llc_domains));
        Recommendation r;
        r.kind = "sched_setaffinity";
        r.detail = "sched_setaffinity(<pid>, mask_of_one_llc_domain);  // e.g. cpus 0-7 for domain 0";
        r.rationale = "Pin the task group to a single LLC domain to stop cross-LLC migration.";
        f.recs.push_back(r);
        out.push_back(std::move(f));
    }

    // Rule: unnecessary wakeups.
    if (agg.sched_collected && agg.wakeups > 0 &&
        static_cast<double>(agg.unnecessary_wakeups) / static_cast<double>(agg.wakeups) > 0.30) {
        Finding f;
        f.id = "unnecessary-wakeups";
        f.sev = Severity::Info;
        f.confidence = Confidence::Measured;
        f.summary = "A large share of wakeups are not followed by a run within the window.";
        f.evidence.push_back("unnecessary_wakeups=" + std::to_string(agg.unnecessary_wakeups) +
                             "/" + std::to_string(agg.wakeups));
        Recommendation r;
        r.kind = "tuning";
        r.detail = "Batch/coalesce wakeups or use polling for the affected producer/consumer pair.";
        r.rationale = "Reduce wakeup-to-idle churn that wastes CPU and perturbs the scheduler.";
        f.recs.push_back(r);
        out.push_back(std::move(f));
    }

    // Rule: excessive locking.
    if (agg.lock_contentions > 0 && agg.avg_lock_wait_ms > 1.0) {
        Finding f;
        f.id = "excessive-locking";
        f.sev = Severity::Warning;
        f.confidence = Confidence::Measured;
        f.summary = "Lock contention wait time is high relative to useful work.";
        f.evidence.push_back("lock_contentions=" + std::to_string(agg.lock_contentions) +
                             " avg_wait_ms=" + std::to_string(agg.avg_lock_wait_ms));
        Recommendation r;
        r.kind = "tuning";
        r.detail = "Shard the contended lock, reduce critical-section length, or go lock-free.";
        r.rationale = "Cut average lock wait below ~1ms to remove the serialization bottleneck.";
        f.recs.push_back(r);
        out.push_back(std::move(f));
    }

    // Rule: false sharing (needs PMU HITM/IBS data).
    if (agg.pmu_collected && agg.remote_hitm > 0.0) {
        Finding f;
        f.id = "false-sharing";
        f.sev = Severity::Critical;
        f.confidence = Confidence::Measured;
        f.summary = "Cross-core cache-line ping-pong (remote HITM) indicates false sharing.";
        f.evidence.push_back("remote_hitm_rate=" + std::to_string(agg.remote_hitm));
        Recommendation r;
        r.kind = "tuning";
        r.detail = "Pad hot fields to a 64B cache line (alignas(64)) or split per-thread.";
        r.rationale = "Eliminate shared writable cache lines between cores.";
        f.recs.push_back(r);
        out.push_back(std::move(f));
    } else if (!agg.pmu_collected && agg.llc_misses > 0) {
        Finding f;
        f.id = "false-sharing";
        f.sev = Severity::Info;
        f.confidence = Confidence::Heuristic;
        f.summary = "Elevated LLC misses may indicate false sharing (PMU HITM unavailable).";
        f.evidence.push_back("llc_misses=" + std::to_string(agg.llc_misses) +
                             " (heuristic; CAP_PERFMON needed for confirmation)");
        out.push_back(std::move(f));
    }

    // Rule: allocator fragmentation.
    if (agg.buddy_fragmentation > 0.5) {
        Finding f;
        f.id = "allocator-fragmentation";
        f.sev = Severity::Info;
        f.confidence = Confidence::Measured;
        f.summary = "High-order buddy lists are depleted relative to low-order (fragmentation).";
        f.evidence.push_back("buddy_fragmentation_index=" + std::to_string(agg.buddy_fragmentation));
        Recommendation r;
        r.kind = "tuning";
        r.detail = "Use huge pages / a slab-friendly allocator; reduce small-allocation churn.";
        r.rationale = "Lower fragmentation to keep high-order allocations cheap.";
        f.recs.push_back(r);
        out.push_back(std::move(f));
    }

    // Rule: priority inversion.
    if (agg.priority_inversion_observed) {
        Finding f;
        f.id = "priority-inversion";
        f.sev = Severity::Critical;
        f.confidence = Confidence::Measured;
        f.summary = "A high-priority task was blocked on a lock held by a preempted low-priority task.";
        f.evidence.push_back("priority_inversion observed via lock-owner + sched_switch chain");
        Recommendation r;
        r.kind = "tuning";
        r.detail = "Use priority-inheritance mutexes (PTHREAD_PRIO_INHERIT) or shorten the hold.";
        r.rationale = "Prevent unbounded priority inversion on the critical lock.";
        f.recs.push_back(r);
        out.push_back(std::move(f));
    }

    std::stable_sort(out.begin(), out.end(), [](const Finding& a, const Finding& b) {
        if (severity_rank(a.sev) != severity_rank(b.sev))
            return severity_rank(a.sev) > severity_rank(b.sev);
        return a.evidence.size() > b.evidence.size();
    });
    return out;
}

json::Value Advisor::report_json(const Aggregates& agg) const {
    json::Value doc = json::Value::make_object();
    doc.set("schema", json::Value("xsprof/advisor-report/v1"));
    json::Value caps = json::Value::make_object();
    caps.set("pmu_collected", json::Value(agg.pmu_collected));
    caps.set("sched_collected", json::Value(agg.sched_collected));
    doc.set("capabilities", caps);
    json::Value arr = json::Value::make_array();
    for (const auto& f : analyze(agg)) arr.push_back(f.to_json());
    doc.set("findings", arr);
    doc.set("host_mutation", json::Value(false));
    return doc;
}

std::string Advisor::report_markdown(const Aggregates& agg) const {
    std::ostringstream md;
    md << "# xsprof Performance Advisor Report\n\n";
    md << "- PMU collected: " << (agg.pmu_collected ? "yes" : "no") << "\n";
    md << "- Scheduler collected: " << (agg.sched_collected ? "yes" : "no") << "\n\n";
    auto findings = analyze(agg);
    if (findings.empty()) {
        md << "No findings. Either the workload is healthy or the signals needed for detection "
              "were not collected (see capabilities above; the framework fails closed).\n";
        return md.str();
    }
    md << "| # | Severity | Finding | Confidence |\n|---|----------|---------|------------|\n";
    int i = 1;
    for (const auto& f : findings) {
        md << "| " << i++ << " | " << severity_name(f.sev) << " | " << f.id << " | "
           << confidence_name(f.confidence) << " |\n";
    }
    md << "\n## Detail\n\n";
    for (const auto& f : findings) {
        md << "### " << f.id << " (" << severity_name(f.sev) << ", "
           << confidence_name(f.confidence) << ")\n\n";
        md << f.summary << "\n\n";
        md << "Evidence:\n";
        for (const auto& e : f.evidence) md << "- `" << e << "`\n";
        if (!f.recs.empty()) {
            md << "\nRecommendations (suggestions only — never auto-applied):\n";
            for (const auto& r : f.recs) {
                md << "- **" << r.kind << "**: `" << r.detail << "` — " << r.rationale << "\n";
            }
        }
        md << "\n";
    }
    return md.str();
}

Aggregates aggregates_from_facts(const SystemFacts& facts) {
    Aggregates agg;
    // Read-only Phase-1 path: PMU/tracepoint-derived signals are not collected
    // without privilege, so they stay zero and are marked uncollected.
    agg.pmu_collected = facts.perf_event_paranoid <= 1;
    agg.sched_collected = false; // tracepoint sched collection requires privilege (Phase 2)

    // NUMA topology informs the placement rule's domain count.
    agg.llc_domains = std::max<int>(1, static_cast<int>(facts.numa_nodes.size()));

    // Buddy fragmentation index: ratio of low-order free pages dominating the
    // total (a coarse, read-only fragmentation signal from /proc/buddyinfo).
    if (!facts.buddyinfo.empty()) {
        // Parse the last buddyinfo line's order counts as a representative zone.
        const std::string& line = facts.buddyinfo.back();
        auto comma = line.find(',');
        std::string counts = (comma == std::string::npos) ? line : line.substr(comma + 1);
        std::istringstream ss(counts);
        long long v;
        std::vector<long long> orders;
        while (ss >> v) orders.push_back(v);
        if (orders.size() >= 2) {
            long long low = 0, high = 0;
            for (std::size_t i = 0; i < orders.size(); ++i) {
                if (i < 4) low += orders[i];
                else high += orders[i];
            }
            long long total = low + high;
            agg.buddy_fragmentation = total > 0 ? static_cast<double>(low) / static_cast<double>(total) : 0.0;
        }
    }
    return agg;
}

} // namespace xsprof::advisor
