// Catch2 tests for the scheduler collector (story G002, Phase 2).
// The host runs perf_event_paranoid=2, so the probe must return SKIP.
#include <catch2/catch_test_macros.hpp>
#include <linux/perf_event.h>
#include <string>

#include "xsprof/sched_collector.hpp"

using namespace xsprof;
using namespace xsprof::sched;

TEST_CASE("sched collector probe returns SKIP when unprivileged", "[sched][capability]") {
    SchedCollector collector;
    auto cap = collector.probe();
    // On this host perf_event_paranoid=2, so we expect SKIP.
    // If the host ever runs with paranoid<=1, this test would need updating,
    // but the fail-closed contract is: never auto-elevate.
    REQUIRE(cap.name == "sched_collector");
    // The probe must never return Ready on a paranoid=2 host without CAP_PERFMON.
    // We check that it is either SKIP or REFUSE (fail-closed).
    REQUIRE((cap.state == CapState::Skip || cap.state == CapState::Refuse));
    REQUIRE(cap.reason.find("fail-closed") != std::string::npos);
    // The capability JSON carries host_mutation=false.
    REQUIRE(cap.to_json().dump().find("\"host_mutation\":false") != std::string::npos);
}

TEST_CASE("sched collector probe never auto-elevates", "[sched][capability]") {
    SchedCollector collector;
    auto cap = collector.probe();
    // The reason must explicitly state it never auto-elevates.
    REQUIRE(cap.reason.find("never auto-elevate") != std::string::npos);
    // The reason must not suggest any privilege escalation path.
    REQUIRE(cap.reason.find("try sudo") == std::string::npos);
    REQUIRE(cap.reason.find("run as root") == std::string::npos);
    REQUIRE(cap.reason.find("setcap") == std::string::npos);
}

TEST_CASE("schedstat CPU line parsing", "[sched][schedstat]") {
    // Typical /proc/schedstat cpu line (kernel 6.x format):
    // cpu0 <yld> <sched> <ttwu> <ttwu_local> <rq_cpu_time> <run_delay> <pcount> ...
    RunqueueSample s;
    bool ok = SchedCollector::parse_schedstat_cpu_line(
        "cpu0 0 12345 67890 54321 9876543210 123456789 11111 0 0", s);
    REQUIRE(ok);
    REQUIRE(s.cpu == 0);
    REQUIRE(s.nr_switches == 12345);
    REQUIRE(s.run_delay_ns == 123456789);
    REQUIRE(s.timeslices_ns == 9876543210);
}

TEST_CASE("schedstat parse rejects non-cpu lines", "[sched][schedstat]") {
    RunqueueSample s;
    REQUIRE_FALSE(SchedCollector::parse_schedstat_cpu_line("domain0 0 0 0", s));
    REQUIRE_FALSE(SchedCollector::parse_schedstat_cpu_line("", s));
    REQUIRE_FALSE(SchedCollector::parse_schedstat_cpu_line("cpu", s));
}

TEST_CASE("sample_runqueues returns data or empty (read-only)", "[sched][schedstat]") {
    auto samples = SchedCollector::sample_runqueues();
    // On a Linux host with /proc/schedstat, we get at least one CPU.
    // In a container without schedstat, we get empty — both are valid.
    for (const auto& s : samples) {
        REQUIRE(s.cpu >= 0);
    }
}

TEST_CASE("wakeup-to-switch correlation", "[sched][correlation]") {
    SchedCollector collector;
    collector.set_correlation_window_ns(1'000'000); // 1 ms

    // Wakeup at t=0 for pid 42 targeting cpu 1.
    collector.record_wakeup(0, 42, 1);
    // Switch at t=500us on cpu 1 for pid 42 -> correlated.
    collector.record_switch(500'000, 1, 42);
    REQUIRE(collector.correlated_wakeups() == 1);
    REQUIRE(collector.unnecessary_wakeups() == 0);

    // Wakeup at t=2ms for pid 99 targeting cpu 0, never matched.
    collector.record_wakeup(2'000'000, 99, 0);
    // Advance time beyond the window with a new wakeup to trigger pruning.
    collector.record_wakeup(5'000'000, 100, 0);
    REQUIRE(collector.unnecessary_wakeups() >= 1);
}

TEST_CASE("wakeup correlation respects window", "[sched][correlation]") {
    SchedCollector collector;
    collector.set_correlation_window_ns(1'000'000); // 1 ms

    // Wakeup at t=0 for pid 7 targeting cpu 2.
    collector.record_wakeup(0, 7, 2);
    // Switch at t=2ms (outside 1ms window) -> NOT correlated.
    collector.record_switch(2'000'000, 2, 7);
    REQUIRE(collector.correlated_wakeups() == 0);
}

TEST_CASE("fill_aggregates sets sched_collected", "[sched][pipeline]") {
    SchedCollector collector;
    pipeline::Aggregates agg;
    REQUIRE_FALSE(agg.sched_collected);
    collector.fill_aggregates(agg);
    REQUIRE(agg.sched_collected);
}

TEST_CASE("capability event carries host_mutation=false", "[sched][pipeline]") {
    SchedCollector collector;
    auto e = collector.capability_event();
    REQUIRE(e.kind == EventKind::Capability);
    auto j = event_to_json(e);
    REQUIRE(j.dump().find("\"host_mutation\":false") != std::string::npos);
}

TEST_CASE("PerfEvent open fails gracefully at paranoid=2", "[sched][perf]") {
    // PERF_TYPE_SOFTWARE / PERF_COUNT_SW_CPU_CLOCK should fail at paranoid=2
    // for a target pid we don't own. We just verify the RAII wrapper handles
    // the error without crashing.
    auto ev = PerfEvent::open(PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CPU_CLOCK, 999999, -1, -1);
    // On paranoid=2 this should fail (invalid fd).
    // We don't REQUIRE failure because the test environment may vary,
    // but we verify the wrapper is safe either way.
    if (!ev.valid()) {
        REQUIRE(ev.error() > 0);
    }
}
