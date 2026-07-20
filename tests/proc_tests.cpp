#include <catch2/catch_test_macros.hpp>
#include <string>

#include "xsprof/proc.hpp"

using namespace xsprof;

TEST_CASE("capability probes return records and never mutate", "[proc]") {
    auto caps = ProcSource::probe_capabilities();
    REQUIRE_FALSE(caps.empty());
    bool have_perf = false;
    bool have_btf = false;
    for (const auto& c : caps) {
        if (c.name == "perf_event")
            have_perf = true;
        if (c.name == "btf")
            have_btf = true;
        // Every capability record carries the read-only invariant.
        REQUIRE(c.to_json().dump().find("\"host_mutation\":false") != std::string::npos);
    }
    REQUIRE(have_perf);
    REQUIRE(have_btf);
}

TEST_CASE("read-only facts collection", "[proc]") {
    auto facts = ProcSource::collect_facts();
    REQUIRE(facts.online_cpus > 0);
    REQUIRE(facts.mem.mem_total_kb > 0);
    REQUIRE_FALSE(facts.kernel_release.empty());
    auto fj = ProcSource::facts_to_json(facts);
    REQUIRE(fj.dump().find("\"host_mutation\":false") != std::string::npos);
}
