#include "xsprof/safety.hpp"

#include <array>
#include <string>
#include <vector>

namespace xsprof {

std::string_view mutation_name(Mutation m) {
    switch (m) {
    case Mutation::SchedAffinity:
        return "sched_setaffinity";
    case Mutation::SchedPriority:
        return "sched_setpriority";
    case Mutation::CgroupWrite:
        return "cgroup_write";
    case Mutation::SchedExtLoad:
        return "sched_ext_load";
    case Mutation::NumaBind:
        return "numa_bind";
    }
    return "unknown_mutation";
}

bool is_unsafe_verb(std::string_view verb) {
    constexpr std::array<std::string_view, 9> unsafe = {
        "load",        "attach",      "enable", "mutate", "apply", "sched-ext-attach",
        "setaffinity", "setpriority", "bind",
    };
    for (auto u : unsafe) {
        if (verb == u)
            return true;
    }
    return false;
}

GateDecision SafetyGate::decide(Mutation m, const AuditContext& ctx) const {
    const std::string name(mutation_name(m));
    if (!ctx.allow_mutate) {
        return {false, "refused: " + name +
                           " is disabled by default (fail-closed); read-only observation only"};
    }
    if (!ctx.vm_lab_marker) {
        return {false, "refused: " + name +
                           " requires a disposable VM lab marker; host mutation is not permitted"};
    }
    if (ctx.audit_id.empty() || ctx.rollback_id.empty()) {
        return {false, "refused: " + name + " requires --audit-id and --rollback-id"};
    }
    // Even when fully authorized, the framework only *plans* the mutation; the
    // actual write happens through an audited lab runner, never implicitly.
    return {true, "authorized (planned only): " + name + " audit=" + ctx.audit_id +
                      " rollback=" + ctx.rollback_id};
}

SafePathResult SafePath::under(std::string_view root, std::string_view candidate) {
    if (candidate.empty()) {
        return {false, "", "empty path"};
    }
    if (candidate.front() == '/') {
        return {false, "",
                "absolute path not allowed; paths must be relative and under the state dir"};
    }

    auto split = [](std::string_view p) {
        std::vector<std::string> parts;
        std::string cur;
        for (char c : p) {
            if (c == '/') {
                if (!cur.empty()) {
                    parts.push_back(cur);
                    cur.clear();
                }
            } else {
                cur += c;
            }
        }
        if (!cur.empty())
            parts.push_back(cur);
        return parts;
    };

    std::vector<std::string> stack;
    for (const auto& part : split(candidate)) {
        if (part == ".")
            continue;
        if (part == "..") {
            if (stack.empty()) {
                return {false, "", "path escapes the state dir via .."};
            }
            stack.pop_back();
            continue;
        }
        stack.push_back(part);
    }

    std::string resolved(root);
    if (!resolved.empty() && resolved.back() != '/')
        resolved += '/';
    for (std::size_t i = 0; i < stack.size(); ++i) {
        if (i)
            resolved += '/';
        resolved += stack[i];
    }
    return {true, resolved, ""};
}

} // namespace xsprof
