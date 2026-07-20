#include <catch2/catch_test_macros.hpp>
#include <string>

#include "xsprof/pipeline.hpp"

using namespace xsprof::pipeline;

TEST_CASE("aggregates defaults are fail-closed", "[pipeline]") {
    Aggregates agg;
    REQUIRE(agg.remote_fault_ratio == 0.0);
    REQUIRE(agg.dominant_node == -1);
    REQUIRE(agg.task_cpu_node == -1);
    REQUIRE(agg.migrations == 0);
    REQUIRE_FALSE(agg.pmu_collected);
    REQUIRE_FALSE(agg.sched_collected);
    REQUIRE_FALSE(agg.priority_inversion_observed);
}

TEST_CASE("aggregates to_json carries schema and host_mutation=false", "[pipeline]") {
    Aggregates agg;
    const std::string s = agg.to_json().dump();
    REQUIRE(s.find("\"schema\":\"xsprof/aggregates/v1\"") != std::string::npos);
    REQUIRE(s.find("\"host_mutation\":false") != std::string::npos);
    REQUIRE(s.find("\"pmu_collected\":false") != std::string::npos);
    REQUIRE(s.find("\"sched_collected\":false") != std::string::npos);
}

TEST_CASE("counting sink tracks events and snapshots", "[pipeline]") {
    CountingSink sink;
    xsprof::RawEvent e;
    e.kind = xsprof::EventKind::SchedSwitch;
    REQUIRE(sink.on_event(e));
    REQUIRE(sink.events() == 1);
    Aggregates agg;
    sink.on_aggregates(agg);
    REQUIRE(sink.snapshots() == 1);
    REQUIRE_FALSE(sink.complete());
    sink.on_complete();
    REQUIRE(sink.complete());
}

TEST_CASE("aggregates round-trips populated fields", "[pipeline]") {
    Aggregates agg;
    agg.remote_fault_ratio = 0.6;
    agg.dominant_node = 1;
    agg.task_cpu_node = 0;
    agg.pmu_collected = true;
    agg.sched_collected = true;
    agg.migrations = 500;
    agg.llc_misses = 12345;
    const std::string s = agg.to_json().dump();
    REQUIRE(s.find("\"remote_fault_ratio\":") != std::string::npos);
    REQUIRE(s.find("\"dominant_node\":1") != std::string::npos);
    REQUIRE(s.find("\"pmu_collected\":true") != std::string::npos);
    REQUIRE(s.find("\"migrations\":500") != std::string::npos);
    REQUIRE(s.find("\"llc_misses\":12345") != std::string::npos);
}
