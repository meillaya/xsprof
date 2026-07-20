#include <catch2/catch_test_macros.hpp>
#include <string>

#include "xsprof/advisor.hpp"

using namespace xsprof::advisor;

// ---------------------------------------------------------------------------
// Baseline: healthy / uncollected signals produce no findings (fail-closed).
// ---------------------------------------------------------------------------

TEST_CASE("advisor stays silent on healthy/uncollected baseline", "[advisor]") {
    Advisor advisor;
    Aggregates healthy; // all signals zero, uncollected
    REQUIRE(advisor.analyze(healthy).empty());
}

TEST_CASE("advisor stays silent on healthy stressed-but-collected baseline", "[advisor]") {
    Advisor advisor;
    Aggregates healthy;
    healthy.pmu_collected = true;
    healthy.sched_collected = true;
    // All metrics within healthy range.
    healthy.remote_fault_ratio = 0.05;
    healthy.dominant_node = 0;
    healthy.task_cpu_node = 0;
    healthy.migrations = 10;
    healthy.cross_llc_migration = false;
    healthy.wakeups = 1000;
    healthy.unnecessary_wakeups = 50;
    healthy.lock_contentions = 0;
    healthy.avg_lock_wait_ms = 0.1;
    healthy.remote_hitm = 0.01;
    healthy.buddy_fragmentation = 0.2;
    healthy.priority_inversion_observed = false;
    REQUIRE(advisor.analyze(healthy).empty());
}

// ---------------------------------------------------------------------------
// Rule 1: False sharing
// ---------------------------------------------------------------------------

TEST_CASE("advisor detects false sharing only with PMU evidence", "[advisor][false-sharing]") {
    Advisor advisor;
    Aggregates fs;
    fs.pmu_collected = true;
    fs.remote_hitm = 0.4;
    auto findings = advisor.analyze(fs);
    bool found_critical = false;
    for (const auto& f : findings)
        if (f.id == "false-sharing" && f.sev == Severity::Critical) found_critical = true;
    REQUIRE(found_critical);
}

TEST_CASE("false sharing fires at threshold boundary", "[advisor][false-sharing]") {
    Thresholds t;
    t.false_sharing_hitm_min = 0.10;
    Advisor advisor(t);

    Aggregates at_boundary;
    at_boundary.pmu_collected = true;
    at_boundary.remote_hitm = 0.11; // just above threshold
    auto findings = advisor.analyze(at_boundary);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "false-sharing" && f.sev == Severity::Critical) found = true;
    REQUIRE(found);
}

TEST_CASE("false sharing silent below threshold", "[advisor][false-sharing]") {
    Thresholds t;
    t.false_sharing_hitm_min = 0.10;
    Advisor advisor(t);

    Aggregates below;
    below.pmu_collected = true;
    below.remote_hitm = 0.05; // below threshold
    auto findings = advisor.analyze(below);
    for (const auto& f : findings)
        REQUIRE(f.id != "false-sharing");
}

TEST_CASE("false sharing heuristic without PMU", "[advisor][false-sharing]") {
    Advisor advisor;
    Aggregates agg;
    agg.pmu_collected = false;
    agg.llc_misses = 5000;
    auto findings = advisor.analyze(agg);
    bool found_heuristic = false;
    for (const auto& f : findings)
        if (f.id == "false-sharing" && f.confidence == Confidence::Heuristic)
            found_heuristic = true;
    REQUIRE(found_heuristic);
}

// ---------------------------------------------------------------------------
// Rule 2: Excessive locking
// ---------------------------------------------------------------------------

TEST_CASE("advisor detects excessive locking", "[advisor][excessive-locking]") {
    Advisor advisor;
    Aggregates agg;
    agg.lock_contentions = 500;
    agg.avg_lock_wait_ms = 5.0;
    auto findings = advisor.analyze(agg);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "excessive-locking") {
            found = true;
            REQUIRE(f.sev == Severity::Warning);
            REQUIRE(!f.recs.empty());
        }
    REQUIRE(found);
}

TEST_CASE("excessive locking respects configurable threshold", "[advisor][excessive-locking]") {
    Thresholds t;
    t.excessive_lock_wait_ms = 10.0;
    t.excessive_lock_contentions_min = 100;
    Advisor advisor(t);

    Aggregates agg;
    agg.lock_contentions = 50;  // below min
    agg.avg_lock_wait_ms = 5.0; // below threshold
    REQUIRE(advisor.analyze(agg).empty());

    agg.lock_contentions = 200;
    agg.avg_lock_wait_ms = 15.0;
    auto findings = advisor.analyze(agg);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "excessive-locking") found = true;
    REQUIRE(found);
}

TEST_CASE("excessive locking silent on healthy baseline", "[advisor][excessive-locking]") {
    Advisor advisor;
    Aggregates agg;
    agg.lock_contentions = 0;
    agg.avg_lock_wait_ms = 0.0;
    REQUIRE(advisor.analyze(agg).empty());
}

// ---------------------------------------------------------------------------
// Rule 3: Unnecessary wakeups
// ---------------------------------------------------------------------------

TEST_CASE("advisor detects unnecessary wakeups", "[advisor][unnecessary-wakeups]") {
    Advisor advisor;
    Aggregates agg;
    agg.sched_collected = true;
    agg.wakeups = 1000;
    agg.unnecessary_wakeups = 500; // 50% > 30% threshold
    auto findings = advisor.analyze(agg);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "unnecessary-wakeups") {
            found = true;
            REQUIRE(f.sev == Severity::Info);
        }
    REQUIRE(found);
}

TEST_CASE("unnecessary wakeups respects configurable ratio", "[advisor][unnecessary-wakeups]") {
    Thresholds t;
    t.unnecessary_wakeup_ratio = 0.60;
    Advisor advisor(t);

    Aggregates agg;
    agg.sched_collected = true;
    agg.wakeups = 1000;
    agg.unnecessary_wakeups = 500; // 50% < 60% threshold
    REQUIRE(advisor.analyze(agg).empty());

    agg.unnecessary_wakeups = 700; // 70% > 60%
    auto findings = advisor.analyze(agg);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "unnecessary-wakeups") found = true;
    REQUIRE(found);
}

TEST_CASE("unnecessary wakeups silent without sched_collected", "[advisor][unnecessary-wakeups]") {
    Advisor advisor;
    Aggregates agg;
    agg.sched_collected = false;
    agg.wakeups = 1000;
    agg.unnecessary_wakeups = 900;
    REQUIRE(advisor.analyze(agg).empty());
}

// ---------------------------------------------------------------------------
// Rule 4: CPU affinity churn
// ---------------------------------------------------------------------------

TEST_CASE("advisor detects CPU affinity churn", "[advisor][affinity-churn]") {
    Advisor advisor;
    Aggregates agg;
    agg.sched_collected = true;
    agg.cross_llc_migration = true;
    agg.migrations = 500;
    agg.llc_domains = 4;
    auto findings = advisor.analyze(agg);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "cpu-affinity-churn") {
            found = true;
            REQUIRE(f.sev == Severity::Warning);
            REQUIRE(!f.recs.empty());
            REQUIRE(f.recs[0].kind == "sched_setaffinity");
        }
    REQUIRE(found);
}

TEST_CASE("affinity churn respects configurable migration threshold", "[advisor][affinity-churn]") {
    Thresholds t;
    t.affinity_churn_migrations_min = 1000;
    Advisor advisor(t);

    Aggregates agg;
    agg.sched_collected = true;
    agg.cross_llc_migration = true;
    agg.migrations = 500; // below threshold
    REQUIRE(advisor.analyze(agg).empty());

    agg.migrations = 1500; // above threshold
    auto findings = advisor.analyze(agg);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "cpu-affinity-churn") found = true;
    REQUIRE(found);
}

TEST_CASE("affinity churn silent without cross-LLC migration", "[advisor][affinity-churn]") {
    Advisor advisor;
    Aggregates agg;
    agg.sched_collected = true;
    agg.cross_llc_migration = false;
    agg.migrations = 10000;
    REQUIRE(advisor.analyze(agg).empty());
}

// ---------------------------------------------------------------------------
// Rule 5: Poor NUMA placement
// ---------------------------------------------------------------------------

TEST_CASE("advisor detects poor NUMA placement and recommends a bind", "[advisor][numa]") {
    Advisor advisor;
    Aggregates numa;
    numa.remote_fault_ratio = 0.6;
    numa.dominant_node = 1;
    numa.task_cpu_node = 0;
    auto findings = advisor.analyze(numa);
    bool found = false;
    for (const auto& f : findings) {
        if (f.id == "poor-numa-placement") {
            found = true;
            REQUIRE_FALSE(f.recs.empty());
            REQUIRE(f.recs[0].kind == "numa_bind");
        }
    }
    REQUIRE(found);
}

TEST_CASE("NUMA placement respects configurable ratio", "[advisor][numa]") {
    Thresholds t;
    t.numa_remote_fault_ratio = 0.50;
    Advisor advisor(t);

    Aggregates agg;
    agg.remote_fault_ratio = 0.30; // below threshold
    agg.dominant_node = 1;
    agg.task_cpu_node = 0;
    REQUIRE(advisor.analyze(agg).empty());

    agg.remote_fault_ratio = 0.60; // above threshold
    auto findings = advisor.analyze(agg);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "poor-numa-placement") found = true;
    REQUIRE(found);
}

TEST_CASE("NUMA placement silent when nodes match", "[advisor][numa]") {
    Advisor advisor;
    Aggregates agg;
    agg.remote_fault_ratio = 0.9;
    agg.dominant_node = 0;
    agg.task_cpu_node = 0; // same node
    REQUIRE(advisor.analyze(agg).empty());
}

// ---------------------------------------------------------------------------
// Rule 6: Allocator fragmentation
// ---------------------------------------------------------------------------

TEST_CASE("advisor detects allocator fragmentation", "[advisor][fragmentation]") {
    Advisor advisor;
    Aggregates agg;
    agg.buddy_fragmentation = 0.8;
    auto findings = advisor.analyze(agg);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "allocator-fragmentation") {
            found = true;
            REQUIRE(f.sev == Severity::Info);
            REQUIRE(!f.recs.empty());
        }
    REQUIRE(found);
}

TEST_CASE("fragmentation respects configurable threshold", "[advisor][fragmentation]") {
    Thresholds t;
    t.allocator_fragmentation_min = 0.90;
    Advisor advisor(t);

    Aggregates agg;
    agg.buddy_fragmentation = 0.70; // below threshold
    REQUIRE(advisor.analyze(agg).empty());

    agg.buddy_fragmentation = 0.95; // above threshold
    auto findings = advisor.analyze(agg);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "allocator-fragmentation") found = true;
    REQUIRE(found);
}

TEST_CASE("fragmentation silent on healthy baseline", "[advisor][fragmentation]") {
    Advisor advisor;
    Aggregates agg;
    agg.buddy_fragmentation = 0.3;
    REQUIRE(advisor.analyze(agg).empty());
}

// ---------------------------------------------------------------------------
// Rule 7: Priority inversion
// ---------------------------------------------------------------------------

TEST_CASE("advisor detects priority inversion", "[advisor][priority-inversion]") {
    Advisor advisor;
    Aggregates agg;
    agg.priority_inversion_observed = true;
    auto findings = advisor.analyze(agg);
    bool found = false;
    for (const auto& f : findings)
        if (f.id == "priority-inversion") {
            found = true;
            REQUIRE(f.sev == Severity::Critical);
            REQUIRE(!f.recs.empty());
        }
    REQUIRE(found);
}

TEST_CASE("priority inversion can be disabled via threshold", "[advisor][priority-inversion]") {
    Thresholds t;
    t.priority_inversion_enabled = false;
    Advisor advisor(t);

    Aggregates agg;
    agg.priority_inversion_observed = true;
    REQUIRE(advisor.analyze(agg).empty());
}

TEST_CASE("priority inversion silent when not observed", "[advisor][priority-inversion]") {
    Advisor advisor;
    Aggregates agg;
    agg.priority_inversion_observed = false;
    REQUIRE(advisor.analyze(agg).empty());
}

// ---------------------------------------------------------------------------
// Report output: JSON and Markdown
// ---------------------------------------------------------------------------

TEST_CASE("advisor reports carry host_mutation=false", "[advisor][report]") {
    Advisor advisor;
    Aggregates agg;
    REQUIRE(advisor.report_json(agg).dump().find("\"host_mutation\":false") != std::string::npos);
    REQUIRE_FALSE(advisor.report_markdown(agg).empty());
}

TEST_CASE("advisor report_json includes all fired findings", "[advisor][report]") {
    Advisor advisor;
    Aggregates agg;
    agg.pmu_collected = true;
    agg.sched_collected = true;
    agg.remote_hitm = 0.5;
    agg.priority_inversion_observed = true;
    agg.remote_fault_ratio = 0.6;
    agg.dominant_node = 1;
    agg.task_cpu_node = 0;

    auto doc = advisor.report_json(agg);
    std::string s = doc.dump();
    REQUIRE(s.find("false-sharing") != std::string::npos);
    REQUIRE(s.find("priority-inversion") != std::string::npos);
    REQUIRE(s.find("poor-numa-placement") != std::string::npos);
    REQUIRE(s.find("\"host_mutation\":false") != std::string::npos);
}

TEST_CASE("advisor report_markdown includes recommendations as suggestions only", "[advisor][report]") {
    Advisor advisor;
    Aggregates agg;
    agg.remote_fault_ratio = 0.6;
    agg.dominant_node = 1;
    agg.task_cpu_node = 0;

    std::string md = advisor.report_markdown(agg);
    REQUIRE(md.find("never auto-applied") != std::string::npos);
    REQUIRE(md.find("numa_bind") != std::string::npos);
}

// ---------------------------------------------------------------------------
// Thresholds struct: defaults and custom
// ---------------------------------------------------------------------------

TEST_CASE("default thresholds have sensible values", "[advisor][thresholds]") {
    Thresholds t;
    REQUIRE(t.false_sharing_hitm_min == 0.05);
    REQUIRE(t.excessive_lock_wait_ms == 1.0);
    REQUIRE(t.excessive_lock_contentions_min == 1);
    REQUIRE(t.unnecessary_wakeup_ratio == 0.30);
    REQUIRE(t.affinity_churn_migrations_min == 100);
    REQUIRE(t.numa_remote_fault_ratio == 0.20);
    REQUIRE(t.allocator_fragmentation_min == 0.50);
    REQUIRE(t.priority_inversion_enabled == true);
}

TEST_CASE("custom thresholds are accessible via advisor", "[advisor][thresholds]") {
    Thresholds t;
    t.false_sharing_hitm_min = 0.99;
    Advisor advisor(t);
    REQUIRE(advisor.thresholds().false_sharing_hitm_min == 0.99);
}

// ---------------------------------------------------------------------------
// All seven rules fire simultaneously on a fully-stressed fixture
// ---------------------------------------------------------------------------

TEST_CASE("all seven rules fire on fully stressed aggregates", "[advisor][integration]") {
    Advisor advisor;
    Aggregates agg;
    agg.pmu_collected = true;
    agg.sched_collected = true;

    // Rule 1: false sharing
    agg.remote_hitm = 0.5;
    // Rule 2: excessive locking
    agg.lock_contentions = 1000;
    agg.avg_lock_wait_ms = 10.0;
    // Rule 3: unnecessary wakeups
    agg.wakeups = 10000;
    agg.unnecessary_wakeups = 5000;
    // Rule 4: CPU affinity churn
    agg.cross_llc_migration = true;
    agg.migrations = 5000;
    agg.llc_domains = 4;
    // Rule 5: poor NUMA placement
    agg.remote_fault_ratio = 0.7;
    agg.dominant_node = 1;
    agg.task_cpu_node = 0;
    // Rule 6: allocator fragmentation
    agg.buddy_fragmentation = 0.9;
    // Rule 7: priority inversion
    agg.priority_inversion_observed = true;

    auto findings = advisor.analyze(agg);
    REQUIRE(findings.size() == 7);

    // Verify all rule IDs present.
    auto has = [&](const std::string& id) {
        for (const auto& f : findings)
            if (f.id == id) return true;
        return false;
    };
    REQUIRE(has("false-sharing"));
    REQUIRE(has("excessive-locking"));
    REQUIRE(has("unnecessary-wakeups"));
    REQUIRE(has("cpu-affinity-churn"));
    REQUIRE(has("poor-numa-placement"));
    REQUIRE(has("allocator-fragmentation"));
    REQUIRE(has("priority-inversion"));

    // Critical findings ranked first.
    REQUIRE(findings[0].sev == Severity::Critical);
}
