// xsprof event model — the single typed spine that correlates scheduler and
// memory events. Mirrors the Zig protocol's EventKind vocabulary while adding
// the scheduler/memory signal kinds from the profiler vision.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

#include "xsprof/json.hpp"

namespace xsprof {

enum class EventKind : std::uint16_t {
    // scheduler
    SchedSwitch,
    SchedWakeup,
    SchedMigrate,
    RunqueueSample,
    PriorityInversion,
    LockContention,
    // memory
    PageFault,
    TlbMiss,
    CacheMiss,
    HugePage,
    NumaBalance,
    AllocSample,
    MallocHotspot,
    // control / lifecycle
    Marker,
    Capability,
    Refusal,
    Incident,
    RuntimeSample,
};

std::string_view event_kind_name(EventKind k);

// A raw event. Kind-specific data is packed into a/b/c to keep the hot path
// allocation-free; richer context lives in `detail`.
struct RawEvent {
    EventKind kind = EventKind::Marker;
    std::uint64_t ts_ns = 0;   // perf-clock nanoseconds
    std::int32_t cpu = -1;
    std::int32_t pid = -1;
    std::int32_t tid = -1;
    std::uint64_t a = 0;
    std::uint64_t b = 0;
    std::uint64_t c = 0;
    std::string comm;          // bounded (16 bytes), privacy-filtered
    std::string detail;        // optional, privacy-filtered
};

json::Value event_to_json(const RawEvent& e);

} // namespace xsprof
