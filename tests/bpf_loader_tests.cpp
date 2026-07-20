// Tests for the BPF CO-RE loader — asserts host refusal (fail-closed).
#include <catch2/catch_test_macros.hpp>

#include "xsprof/bpf_loader.hpp"

using namespace xsprof::bpf;
using namespace xsprof;

TEST_CASE("BPF loader refuses on host without audit context", "[bpf]") {
    BpfLoader loader;
    AuditContext ctx; // default: no allow_mutate, no lab marker
    auto result = loader.load("sched_monitor", ctx);
    REQUIRE(result == LoadResult::Refused);
    REQUIRE(loader.last_reason().find("refused") != std::string::npos);
}

TEST_CASE("BPF loader refuses with partial audit context", "[bpf]") {
    BpfLoader loader;
    AuditContext ctx;
    ctx.allow_mutate = true;
    ctx.audit_id = "audit-123";
    // Missing rollback_id and vm_lab_marker.
    auto result = loader.load("mem_monitor", ctx);
    REQUIRE(result == LoadResult::Refused);
}

TEST_CASE("BPF loader refuses even with full audit on host build", "[bpf]") {
    BpfLoader loader;
    AuditContext ctx;
    ctx.allow_mutate = true;
    ctx.audit_id = "audit-123";
    ctx.rollback_id = "rollback-456";
    ctx.vm_lab_marker = true;
    // On the host build, libbpf is not linked, so even with full context
    // we get SKIP (no libbpf) or SKIP (no BTF), never Loaded.
    auto result = loader.load("sched_monitor", ctx);
    // Must NOT be Loaded: in the host build libbpf is absent (SkipNoLibbpf /
    // SkipNoBtf); in a libbpf build the bogus object path fails to open (Error).
    // A real load only happens with a valid object file inside the VM lab.
    REQUIRE(result != LoadResult::Loaded);
}

TEST_CASE("BPF load_result_name returns valid strings", "[bpf]") {
    REQUIRE(load_result_name(LoadResult::Loaded) == "loaded");
    REQUIRE(load_result_name(LoadResult::Refused) == "refused");
    REQUIRE(load_result_name(LoadResult::SkipNoBtf) == "skip_no_btf");
    REQUIRE(load_result_name(LoadResult::SkipNoLibbpf) == "skip_no_libbpf");
    REQUIRE(load_result_name(LoadResult::Error) == "error");
}

TEST_CASE("BPF btf_available is a valid boolean", "[bpf]") {
    // Just ensure it doesn't crash; result depends on host.
    [[maybe_unused]] bool has_btf = BpfLoader::btf_available();
}

TEST_CASE("BPF libbpf_linked reflects the build configuration", "[bpf]") {
#ifdef XSPROF_HAVE_LIBBPF
    REQUIRE(BpfLoader::libbpf_linked());
#else
    // In the default host build, libbpf is not linked.
    REQUIRE_FALSE(BpfLoader::libbpf_linked());
#endif
}
