// Fail-closed safety gate + path safety. Preserves the archived Zig project's
// invariants: read-only by default, host_mutation=false on every observation,
// unsafe verbs refused, mutation only via explicit audited VM-lab opt-in.
#pragma once

#include <string>
#include <string_view>

namespace xsprof {

enum class Mutation {
    SchedAffinity,
    SchedPriority,
    CgroupWrite,
    SchedExtLoad,
    NumaBind,
};

std::string_view mutation_name(Mutation m);

// True for CLI verbs that must refuse on the host (load/attach/enable/mutate/apply ...).
bool is_unsafe_verb(std::string_view verb);

struct AuditContext {
    bool allow_mutate = false;  // explicit --allow-mutate
    std::string audit_id;       // required
    std::string rollback_id;    // required
    bool vm_lab_marker = false; // required: disposable VM lab marker present
};

struct GateDecision {
    bool allowed = false;
    std::string reason;
};

class SafetyGate {
  public:
    // Refuse-by-default. A mutation is allowed only with an explicit opt-in
    // plus audit id, rollback id, and a VM-lab marker.
    GateDecision decide(Mutation m, const AuditContext& ctx) const;
};

// Path confinement: candidate must be relative and resolve under root.
struct SafePathResult {
    bool ok = false;
    std::string resolved;
    std::string reason;
};

class SafePath {
  public:
    static SafePathResult under(std::string_view root, std::string_view candidate);
};

} // namespace xsprof
