#include "xsprof/event.hpp"

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
    json::Value v = json::Value::make_object();
    v.set("schema", json::Value("xsprof/event/v1"));
    v.set("event", json::Value(event_kind_name(e.kind)));
    v.set("ts_ns", json::Value(static_cast<unsigned long long>(e.ts_ns)));
    v.set("cpu", json::Value(e.cpu));
    v.set("pid", json::Value(e.pid));
    v.set("tid", json::Value(e.tid));
    v.set("a", json::Value(static_cast<unsigned long long>(e.a)));
    v.set("b", json::Value(static_cast<unsigned long long>(e.b)));
    v.set("c", json::Value(static_cast<unsigned long long>(e.c)));
    if (!e.comm.empty()) v.set("comm", json::Value(e.comm));
    if (!e.detail.empty()) v.set("detail", json::Value(e.detail));
    // Read-only observation invariant carried over from the Zig DaemonEvent.
    v.set("host_mutation", json::Value(false));
    return v;
}

} // namespace xsprof
