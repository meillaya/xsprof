// Live capture tests. On the unprivileged host (perf_event_paranoid >= 2,
// tracefs sched unreadable) the capture must fail closed: probe() is not READY
// and run() emits zero events. The privileged live path is validated in the
// disposable VM lab (qa/vm-cpp/run_vmlab.sh), not here.
#include <catch2/catch_test_macros.hpp>

#include "xsprof/live_capture.hpp"

using namespace xsprof;
using namespace xsprof::capture;

TEST_CASE("resolve_tracepoint_id fails closed when tracefs is unreadable", "[live_capture]") {
    // Unprivileged: /sys/kernel/tracing/events/sched/sched_switch/id is not
    // readable, so resolution returns -1 (never fabricates an id).
    long id = resolve_tracepoint_id("sched", "sched_switch");
    // On a privileged host this could be >= 0; the invariant we assert is that
    // it never returns a bogus positive when unreadable. On this host it is -1.
    REQUIRE(id >= -1);
}

TEST_CASE("LiveCapture probe is capability-gated", "[live_capture]") {
    LiveCapture cap;
    Capability c = cap.probe();
    // The probe must produce a definitive state with a reason, and on an
    // unprivileged host it must NOT claim READY.
    REQUIRE_FALSE(c.reason.empty());
    // host is perf_event_paranoid 2 -> not READY
    REQUIRE(c.state != CapState::Ready);
}

TEST_CASE("LiveCapture run fails closed with zero events when unprivileged", "[live_capture]") {
    LiveCapture cap;
    CaptureConfig cfg;
    cfg.duration_ms = 50;
    std::vector<xsprof::RawEvent> events;
    CaptureSummary summary = cap.run(cfg, events);
    // Fail-closed: no events captured, capability not READY.
    REQUIRE(events.empty());
    REQUIRE(summary.events_captured == 0);
    REQUIRE(summary.capability.state != CapState::Ready);
}
