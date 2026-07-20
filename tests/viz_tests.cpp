#include <catch2/catch_test_macros.hpp>
#include <string>
#include <vector>

#include "xsprof/chrome_trace.hpp"

using namespace xsprof;

TEST_CASE("chrome trace export produces complete + instant events", "[viz]") {
    std::vector<RawEvent> events;
    RawEvent sw;
    sw.kind = EventKind::SchedSwitch;
    sw.ts_ns = 5000000;
    sw.cpu = 2;
    sw.pid = 7;
    sw.tid = 7;
    sw.comm = "kworker";
    sw.a = 2000000;
    events.push_back(sw);
    RawEvent pf;
    pf.kind = EventKind::PageFault;
    pf.ts_ns = 6000000;
    pf.pid = 7;
    pf.tid = 7;
    pf.a = 3;
    events.push_back(pf);

    const std::string s = viz::export_events(events).dump();
    REQUIRE(s.find("\"traceEvents\"") != std::string::npos);
    REQUIRE(s.find("\"ph\":\"X\"") != std::string::npos);
    REQUIRE(s.find("\"ph\":\"i\"") != std::string::npos);
    REQUIRE(s.find("kworker") != std::string::npos);
}

TEST_CASE("sample loss is rendered as an explicit unsafe marker", "[viz]") {
    viz::ChromeTraceBuilder b;
    b.add_sample_loss(1000, 1, 1, "ring buffer full");
    const std::string s = b.build().dump();
    REQUIRE(s.find("SAMPLE_LOSS") != std::string::npos);
    REQUIRE(s.find("\"unsafe\":true") != std::string::npos);
}
