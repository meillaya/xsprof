// Live capture — the perf_event_open ring-buffer capture loop that produces a
// real-time stream of scheduler and memory events. This is the core profiling
// action: open sched tracepoints + software/PMU memory events, mmap their ring
// buffers, poll, parse PERF_RECORD samples, correlate, and emit RawEvents.
//
// Capability-gated and fail-closed: open() returns a SKIP/REFUSE capability when
// the process lacks permission (perf_event_paranoid >= 2 without CAP_PERFMON);
// it never auto-elevates. Live capture is intended to run privileged (e.g. inside
// the disposable VM lab with perf_event_paranoid lowered).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "xsprof/event.hpp"
#include "xsprof/proc.hpp"

namespace xsprof::capture {

// Resolve a tracepoint's numeric id from tracefs
// (e.g. name="sched_switch" reads /sys/kernel/tracing/events/sched/sched_switch/id).
// Returns -1 if unreadable (e.g. unprivileged or tracefs not mounted).
long resolve_tracepoint_id(const std::string& subsys, const std::string& name);

struct CaptureConfig {
    int duration_ms = 1000;          // how long to capture
    bool sched_switch = true;        // sched:sched_switch tracepoint
    bool sched_wakeup = true;        // sched:sched_wakeup tracepoint
    bool sched_migrate = true;       // sched:sched_migrate_task tracepoint
    bool page_faults = true;         // PERF_TYPE_SOFTWARE page faults
    bool cache_misses = false;       // PERF_TYPE_HW_CACHE LLC load misses (PMU)
    int mmap_pages = 8;              // data pages per ring buffer (power of 2)
};

struct CaptureSummary {
    Capability capability;           // READY/SKIP/REFUSE for the capture as a whole
    std::uint64_t events_captured = 0;
    std::uint64_t sched_switches = 0;
    std::uint64_t sched_wakeups = 0;
    std::uint64_t sched_migrations = 0;
    std::uint64_t page_faults = 0;
    std::uint64_t cache_misses = 0;
    std::uint64_t lost_samples = 0;  // PERF_RECORD_LOST counts
};

class LiveCapture {
  public:
    // Probe whether live capture is possible (read-only; never elevates).
    Capability probe() const;

    // Run a capture for cfg.duration_ms, appending each captured event to `out`.
    // Returns a summary. If unprivileged, returns immediately with capability
    // SKIP/REFUSE and zero events (fail-closed).
    CaptureSummary run(const CaptureConfig& cfg, std::vector<RawEvent>& out);

  private:
    int open_tracepoint(long tp_id, int cpu, int mmap_pages);
    int open_software(std::uint64_t config, int cpu, int mmap_pages);
};

} // namespace xsprof::capture
