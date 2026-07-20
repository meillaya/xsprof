// Catch2 tests for the memory collector (story G003, Phase 3).
// The host runs perf_event_paranoid=2, so the probe must return SKIP.
#include <catch2/catch_test_macros.hpp>
#include <string>

#include "xsprof/memory_collector.hpp"

using namespace xsprof;
using namespace xsprof::memory;

TEST_CASE("memory collector probe returns SKIP when unprivileged", "[memory][capability]") {
    MemoryCollector collector;
    auto cap = collector.probe();
    REQUIRE(cap.name == "memory_collector");
    // On this host perf_event_paranoid=2, so we expect SKIP or REFUSE.
    REQUIRE((cap.state == CapState::Skip || cap.state == CapState::Refuse));
    REQUIRE(cap.reason.find("fail-closed") != std::string::npos);
    // The capability JSON carries host_mutation=false.
    REQUIRE(cap.to_json().dump().find("\"host_mutation\":false") != std::string::npos);
}

TEST_CASE("memory collector probe never auto-elevates", "[memory][capability]") {
    MemoryCollector collector;
    auto cap = collector.probe();
    // The reason must explicitly state it never auto-elevates.
    REQUIRE(cap.reason.find("never auto-elevate") != std::string::npos);
    // The reason must not suggest any privilege escalation path.
    REQUIRE(cap.reason.find("try sudo") == std::string::npos);
    REQUIRE(cap.reason.find("run as root") == std::string::npos);
    REQUIRE(cap.reason.find("setcap") == std::string::npos);
}

TEST_CASE("buddyinfo line parsing", "[memory][buddyinfo]") {
    BuddyInfo bi;
    bool ok =
        MemoryCollector::parse_buddyinfo_line("Node 0, zone      DMA      1      1      1      0   "
                                              "   2      1      1      0      1      1      3",
                                              bi);
    REQUIRE(ok);
    REQUIRE(bi.node == 0);
    REQUIRE(bi.zone_name == "DMA");
    REQUIRE(bi.free_per_order.size() == 11);
    REQUIRE(bi.free_per_order[0] == 1);
    REQUIRE(bi.free_per_order[3] == 0);
    REQUIRE(bi.free_per_order[10] == 3);
}

TEST_CASE("buddyinfo parse rejects invalid lines", "[memory][buddyinfo]") {
    BuddyInfo bi;
    REQUIRE_FALSE(MemoryCollector::parse_buddyinfo_line("", bi));
    REQUIRE_FALSE(MemoryCollector::parse_buddyinfo_line("not a buddyinfo line", bi));
    REQUIRE_FALSE(MemoryCollector::parse_buddyinfo_line("Node 0, zone", bi));
}

TEST_CASE("poll_buddyinfo returns data or empty (read-only)", "[memory][buddyinfo]") {
    auto info = MemoryCollector::poll_buddyinfo();
    // On a Linux host, /proc/buddyinfo is usually readable.
    for (const auto& bi : info) {
        REQUIRE(bi.node >= 0);
        REQUIRE_FALSE(bi.zone_name.empty());
        REQUIRE_FALSE(bi.free_per_order.empty());
    }
}

TEST_CASE("fragmentation estimation", "[memory][buddyinfo]") {
    // All pages in order 0 -> fully fragmented.
    std::vector<BuddyInfo> fragmented;
    BuddyInfo bi;
    bi.node = 0;
    bi.zone_name = "Normal";
    bi.free_per_order = {100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    fragmented.push_back(bi);
    double frag = MemoryCollector::estimate_fragmentation(fragmented);
    REQUIRE(frag > 0.9);

    // All pages in high order -> not fragmented.
    std::vector<BuddyInfo> healthy;
    BuddyInfo bi2;
    bi2.node = 0;
    bi2.zone_name = "Normal";
    bi2.free_per_order = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10};
    healthy.push_back(bi2);
    double frag2 = MemoryCollector::estimate_fragmentation(healthy);
    REQUIRE(frag2 < 0.1);

    // Empty -> 0.
    REQUIRE(MemoryCollector::estimate_fragmentation({}) == 0.0);
}

TEST_CASE("poll_hugepages returns data or empty (read-only)", "[memory][hugepages]") {
    auto hps = MemoryCollector::poll_hugepages();
    // On a Linux host with hugepages configured, we get at least one entry.
    for (const auto& hp : hps) {
        REQUIRE_FALSE(hp.label.empty());
        REQUIRE(hp.size_kb > 0);
    }
}

TEST_CASE("numa_maps line parsing", "[memory][numa_maps]") {
    NumaMapEntry entry;
    bool ok = MemoryCollector::parse_numa_maps_line(
        "00400000 default file=/usr/bin/foo mapped=10 N0=10", entry);
    REQUIRE(ok);
    REQUIRE(entry.vaddr == 0x00400000);
    REQUIRE(entry.flags == "default");
    REQUIRE(entry.node == 0);
    REQUIRE(entry.pages == 10);
}

TEST_CASE("numa_maps parse handles multi-node", "[memory][numa_maps]") {
    NumaMapEntry entry;
    bool ok =
        MemoryCollector::parse_numa_maps_line("7f0000000000 default anon=100 N0=30 N1=70", entry);
    REQUIRE(ok);
    REQUIRE(entry.node == 1); // dominant node
    REQUIRE(entry.pages == 70);
}

TEST_CASE("numa_maps parse rejects invalid lines", "[memory][numa_maps]") {
    NumaMapEntry entry;
    REQUIRE_FALSE(MemoryCollector::parse_numa_maps_line("", entry));
    REQUIRE_FALSE(MemoryCollector::parse_numa_maps_line("not-hex default", entry));
}

TEST_CASE("poll_numa_maps for pid 1 (read-only, may be empty)", "[memory][numa_maps]") {
    // pid 1 numa_maps may be unreadable without privilege — that's fine.
    auto entries = MemoryCollector::poll_numa_maps(1);
    // We just verify it doesn't crash and returns valid entries if any.
    for (const auto& e : entries) {
        REQUIRE(e.vaddr > 0);
    }
}

TEST_CASE("probe_ibs is read-only and safe", "[memory][ibs]") {
    auto ibs = MemoryCollector::probe_ibs();
    // On an AMD host with IBS, ibs_op_present is true.
    // On Intel or VMs, it's false. Both are valid.
    REQUIRE_FALSE(ibs.reason.empty());
}

TEST_CASE("fill_aggregates sets pmu_collected", "[memory][pipeline]") {
    MemoryCollector collector;
    pipeline::Aggregates agg;
    REQUIRE_FALSE(agg.pmu_collected);
    collector.set_pmu_collected(true);
    collector.add_page_faults(42);
    collector.add_tlb_misses(10);
    collector.add_llc_misses(5);
    collector.set_buddy_fragmentation(0.3);
    collector.fill_aggregates(agg);
    REQUIRE(agg.pmu_collected);
    REQUIRE(agg.page_faults == 42);
    REQUIRE(agg.tlb_misses == 10);
    REQUIRE(agg.llc_misses == 5);
    REQUIRE(agg.buddy_fragmentation == 0.3);
}

TEST_CASE("capability event carries host_mutation=false", "[memory][pipeline]") {
    MemoryCollector collector;
    auto e = collector.capability_event();
    REQUIRE(e.kind == EventKind::Capability);
    auto j = event_to_json(e);
    REQUIRE(j.dump().find("\"host_mutation\":false") != std::string::npos);
}
