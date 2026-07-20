#include <catch2/catch_test_macros.hpp>
#include <fstream>
#include <sstream>
#include <string>

#include "xsprof/event.hpp"
#include "xsprof/json.hpp"
#include "xsprof/pipeline.hpp"

using namespace xsprof;

namespace {
std::string read_fixture(const std::string& name) {
    // Fixtures live next to the test source; CMake sets the working dir to
    // the build tree, so we resolve relative to the source dir via a compile
    // definition (XSPROF_TEST_FIXTURE_DIR).
#ifdef XSPROF_TEST_FIXTURE_DIR
    std::string path = std::string(XSPROF_TEST_FIXTURE_DIR) + "/" + name;
#else
    std::string path = "tests/fixtures/" + name;
#endif
    std::ifstream f(path);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}
} // namespace

TEST_CASE("event-v1 serialization is byte-stable against golden fixture", "[schema][golden]") {
    RawEvent e;
    e.kind = EventKind::SchedSwitch;
    e.ts_ns = 1000000;
    e.cpu = 3;
    e.pid = 100;
    e.tid = 101;
    e.comm = "worker";
    const std::string actual = event_to_json(e).dump();
    const std::string golden = read_fixture("event_v1_golden.json");
    REQUIRE_FALSE(golden.empty());
    // Trim trailing newline from fixture file.
    const std::string trimmed = golden.back() == '\n' ? golden.substr(0, golden.size() - 1) : golden;
    REQUIRE(actual == trimmed);
}

TEST_CASE("event-v1 page_fault serialization is byte-stable", "[schema][golden]") {
    RawEvent e;
    e.kind = EventKind::PageFault;
    e.ts_ns = 2000000;
    e.cpu = 1;
    e.pid = 200;
    e.tid = 201;
    e.a = 3;
    const std::string actual = event_to_json(e).dump();
    const std::string golden = read_fixture("event_v1_page_fault_golden.json");
    REQUIRE_FALSE(golden.empty());
    const std::string trimmed = golden.back() == '\n' ? golden.substr(0, golden.size() - 1) : golden;
    REQUIRE(actual == trimmed);
}

TEST_CASE("aggregates-v1 serialization is byte-stable against golden fixture", "[schema][golden]") {
    pipeline::Aggregates agg; // all defaults
    const std::string actual = agg.to_json().dump();
    const std::string golden = read_fixture("aggregates_v1_golden.json");
    REQUIRE_FALSE(golden.empty());
    const std::string trimmed = golden.back() == '\n' ? golden.substr(0, golden.size() - 1) : golden;
    REQUIRE(actual == trimmed);
}

TEST_CASE("journal-v1 golden fixture is valid JSON with host_mutation=false", "[schema][golden]") {
    const std::string golden = read_fixture("journal_v1_golden.json");
    REQUIRE_FALSE(golden.empty());
    // Every entry must carry host_mutation=false.
    REQUIRE(golden.find("\"host_mutation\":false") != std::string::npos);
    REQUIRE(golden.find("\"schema\":\"xsprof/journal/v1\"") != std::string::npos);
    // Must not contain host_mutation:true anywhere.
    REQUIRE(golden.find("\"host_mutation\":true") == std::string::npos);
}

TEST_CASE("all event kinds round-trip through event_kind_name", "[schema]") {
    // Verify every EventKind has a non-empty, unique name.
    const EventKind all[] = {
        EventKind::SchedSwitch, EventKind::SchedWakeup, EventKind::SchedMigrate,
        EventKind::RunqueueSample, EventKind::PriorityInversion, EventKind::LockContention,
        EventKind::PageFault, EventKind::TlbMiss, EventKind::CacheMiss,
        EventKind::HugePage, EventKind::NumaBalance, EventKind::AllocSample,
        EventKind::MallocHotspot,
        EventKind::Marker, EventKind::Capability, EventKind::Refusal,
        EventKind::Incident, EventKind::RuntimeSample,
    };
    for (auto k : all) {
        auto name = event_kind_name(k);
        REQUIRE_FALSE(name.empty());
        REQUIRE(name != "unknown");
    }
}
