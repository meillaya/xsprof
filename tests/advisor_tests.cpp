#include <catch2/catch_test_macros.hpp>
#include <string>

#include "xsprof/advisor.hpp"

using namespace xsprof::advisor;

TEST_CASE("advisor stays silent on healthy/uncollected baseline", "[advisor]") {
    Advisor advisor;
    Aggregates healthy; // all signals zero, uncollected
    REQUIRE(advisor.analyze(healthy).empty());
}

TEST_CASE("advisor detects poor NUMA placement and recommends a bind", "[advisor]") {
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

TEST_CASE("advisor detects false sharing only with PMU evidence", "[advisor]") {
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

TEST_CASE("advisor reports carry host_mutation=false", "[advisor]") {
    Advisor advisor;
    Aggregates agg;
    REQUIRE(advisor.report_json(agg).dump().find("\"host_mutation\":false") != std::string::npos);
    REQUIRE_FALSE(advisor.report_markdown(agg).empty());
}
