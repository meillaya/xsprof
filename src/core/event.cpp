#include "xsprof/event.hpp"
#include "xsprof/privacy.hpp"

namespace xsprof {

std::string_view event_kind_name(EventKind k) {
    switch (k) {
        case EventKind::SchedSwitch: return "sched_switch";
        case EventKind::SchedWakeup: return "sched_wakeup";
        case EventKind::SchedMigrate: return "sched_migrate";
        case EventKind::RunqueueSample: return "runqueue_sample";
        case EventKind::PriorityInversion: return "priority_inversion";
        case EventKind::LockContention: return "lock_contention";
        case EventKind::PageFault: return "page_fault";
        case EventKind::TlbMiss: return "tlb_miss";
        case EventKind::CacheMiss: return "cache_miss";
        case EventKind::HugePage: return "huge_page";
        case EventKind::NumaBalance: return "numa_balance";
        case EventKind::AllocSample: return "alloc_sample";
        case EventKind::MallocHotspot: return "malloc_hotspot";
        case EventKind::Marker: return "marker";
        case EventKind::Capability: return "capability";
        case EventKind::Refusal: return "refusal";
        case EventKind::Incident: return "incident";
        case EventKind::RuntimeSample: return "runtime_sample";
    }
    return "unknown";
}

json::Value event_to_json(const RawEvent& e) {
    // Fail-closed privacy boundary: sanitize a copy so the serialized event
    // never carries argv, env, or secret material regardless of caller.
    static const PrivacyFilter pf;
    RawEvent sanitized = e;
    sanitize_event(sanitized, pf);

    json::Value v = json::Value::make_object();
    v.set("schema", json::Value("xsprof/event/v1"));
    v.set("event", json::Value(event_kind_name(sanitized.kind)));
    v.set("ts_ns", json::Value(static_cast<unsigned long long>(sanitized.ts_ns)));
    v.set("cpu", json::Value(sanitized.cpu));
    v.set("pid", json::Value(sanitized.pid));
    v.set("tid", json::Value(sanitized.tid));
    v.set("a", json::Value(static_cast<unsigned long long>(sanitized.a)));
    v.set("b", json::Value(static_cast<unsigned long long>(sanitized.b)));
    v.set("c", json::Value(static_cast<unsigned long long>(sanitized.c)));
    if (!sanitized.comm.empty()) v.set("comm", json::Value(sanitized.comm));
    if (!sanitized.detail.empty()) v.set("detail", json::Value(sanitized.detail));
    // Read-only observation invariant carried over from the Zig DaemonEvent.
    v.set("host_mutation", json::Value(false));
    return v;
}

bool event_from_json(const json::Value& v, RawEvent& out) {
    if (!v.is_object()) return false;
    const auto* schema = v.find("schema");
    if (!schema || schema->as_string() != "xsprof/event/v1") return false;
    const auto* ev = v.find("event");
    if (!ev) return false;

    const std::string& name = ev->as_string();
    // Map event name back to EventKind.
    static const std::pair<std::string_view, EventKind> table[] = {
        {"sched_switch", EventKind::SchedSwitch},
        {"sched_wakeup", EventKind::SchedWakeup},
        {"sched_migrate", EventKind::SchedMigrate},
        {"runqueue_sample", EventKind::RunqueueSample},
        {"priority_inversion", EventKind::PriorityInversion},
        {"lock_contention", EventKind::LockContention},
        {"page_fault", EventKind::PageFault},
        {"tlb_miss", EventKind::TlbMiss},
        {"cache_miss", EventKind::CacheMiss},
        {"huge_page", EventKind::HugePage},
        {"numa_balance", EventKind::NumaBalance},
        {"alloc_sample", EventKind::AllocSample},
        {"malloc_hotspot", EventKind::MallocHotspot},
        {"marker", EventKind::Marker},
        {"capability", EventKind::Capability},
        {"refusal", EventKind::Refusal},
        {"incident", EventKind::Incident},
        {"runtime_sample", EventKind::RuntimeSample},
    };
    bool found = false;
    for (const auto& [n, k] : table) {
        if (name == n) { out.kind = k; found = true; break; }
    }
    if (!found) return false;

    if (const auto* f = v.find("ts_ns")) out.ts_ns = static_cast<std::uint64_t>(f->as_int());
    if (const auto* f = v.find("cpu")) out.cpu = static_cast<std::int32_t>(f->as_int());
    if (const auto* f = v.find("pid")) out.pid = static_cast<std::int32_t>(f->as_int());
    if (const auto* f = v.find("tid")) out.tid = static_cast<std::int32_t>(f->as_int());
    if (const auto* f = v.find("a")) out.a = static_cast<std::uint64_t>(f->as_int());
    if (const auto* f = v.find("b")) out.b = static_cast<std::uint64_t>(f->as_int());
    if (const auto* f = v.find("c")) out.c = static_cast<std::uint64_t>(f->as_int());
    if (const auto* f = v.find("comm")) out.comm = f->as_string();
    if (const auto* f = v.find("detail")) out.detail = f->as_string();
    return true;
}

} // namespace xsprof
