#include <catch2/catch_test_macros.hpp>
#include <string>

#include "xsprof/safety.hpp"

using namespace xsprof;

TEST_CASE("safety gate refuses by default", "[safety]") {
    SafetyGate gate;
    AuditContext none;
    auto d = gate.decide(Mutation::SchedAffinity, none);
    REQUIRE_FALSE(d.allowed);
    REQUIRE(d.reason.find("refused") != std::string::npos);
}

TEST_CASE("safety gate refuses without lab marker and ids", "[safety]") {
    SafetyGate gate;
    AuditContext partial;
    partial.allow_mutate = true;
    REQUIRE_FALSE(gate.decide(Mutation::NumaBind, partial).allowed);
    partial.vm_lab_marker = true;
    REQUIRE_FALSE(gate.decide(Mutation::NumaBind, partial).allowed); // missing ids
}

TEST_CASE("safety gate authorizes only full audited VM-lab opt-in (planned only)", "[safety]") {
    SafetyGate gate;
    AuditContext full;
    full.allow_mutate = true;
    full.vm_lab_marker = true;
    full.audit_id = "audit-1";
    full.rollback_id = "rollback-1";
    auto d = gate.decide(Mutation::SchedExtLoad, full);
    REQUIRE(d.allowed);
    REQUIRE(d.reason.find("planned only") != std::string::npos);
}

TEST_CASE("unsafe verbs are refused", "[safety]") {
    REQUIRE(is_unsafe_verb("load"));
    REQUIRE(is_unsafe_verb("attach"));
    REQUIRE(is_unsafe_verb("enable"));
    REQUIRE(is_unsafe_verb("mutate"));
    REQUIRE(is_unsafe_verb("apply"));
    REQUIRE_FALSE(is_unsafe_verb("preflight"));
    REQUIRE_FALSE(is_unsafe_verb("advise"));
}

TEST_CASE("safe path confines to the state dir", "[safety]") {
    auto ok = SafePath::under("/var/lib/xsprof", "runs/42/events.jsonl");
    REQUIRE(ok.ok);
    REQUIRE(ok.resolved == "/var/lib/xsprof/runs/42/events.jsonl");
    REQUIRE_FALSE(SafePath::under("/var/lib/xsprof", "/etc/passwd").ok);
    REQUIRE_FALSE(SafePath::under("/var/lib/xsprof", "../../etc/passwd").ok);
}
