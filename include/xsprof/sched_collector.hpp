// Scheduler collector — capability-gated collection of sched_switch,
// sched_wakeup, sched_migrate_task via perf_event_open, run-queue sampling
// from procfs schedstat, and wakeup-to-switch correlation.
// Probe returns SKIP at perf_event_paranoid >= 2 when unprivileged (fail-closed).
// Story G002 (Phase 2).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "xsprof/event.hpp"
#include "xsprof/pipeline.hpp"
#include "xsprof/proc.hpp"

namespace xsprof::sched {

// RAII wrapper for a perf_event_open file descriptor.
class PerfEvent {
public:
    PerfEvent() = default;
    ~PerfEvent();
    PerfEvent(PerfEvent&& o) noexcept;
    PerfEvent& operator=(PerfEvent&& o) noexcept;
    PerfEvent(const PerfEvent&) = delete;
    PerfEvent& operator=(const PerfEvent&) = delete;

    // Open a perf event. Returns fd >= 0 on success, -errno on failure.
    // `type` and `config` map to perf_event_attr fields.
    static PerfEvent open(std::uint32_t type, std::uint64_t config,
                          pid_t pid, int cpu, int group_fd);
    bool valid() const { return fd_ >= 0; }
    int fd() const { return fd_; }
    int error() const { return err_; }

private:
    int fd_ = -1;
    int err_ = 0;
};

// Parsed /proc/schedstat per-CPU run-queue snapshot.
struct RunqueueSample {
    int cpu = -1;
    std::uint64_t nr_running = 0;
    std::uint64_t nr_uninterruptible = 0;
    std::uint64_t nr_switches = 0;
    std::uint64_t run_delay_ns = 0;   // cumulative run-delay (schedstat field 7)
    std::uint64_t timeslices_ns = 0;  // cumulative timeslice (schedstat field 8)
};

// Wakeup-to-switch correlation state.
struct WakeupRecord {
    std::uint64_t ts_ns = 0;
    int pid = -1;
    int target_cpu = -1;
    bool matched = false;  // true once a sched_switch follows within the window
};

// The scheduler collector. Implements the ICollector pattern from
// docs/rewrite/COLLECTORS.md: probe() is read-only and never mutates.
class SchedCollector {
public:
    // Probe capabilities. Returns SKIP when perf_event_paranoid >= 2 and
    // the process lacks CAP_PERFMON (fail-closed). Never auto-elevates.
    Capability probe() const;

    // Read-only run-queue sampling from /proc/schedstat.
    // Works without privilege; returns empty vector if schedstat is unreadable.
    static std::vector<RunqueueSample> sample_runqueues();

    // Parse one /proc/schedstat line (CPU row). Returns false on parse failure.
    static bool parse_schedstat_cpu_line(const std::string& line, RunqueueSample& out);

    // Wakeup-to-switch correlation: record a wakeup, then check whether a
    // subsequent sched_switch on the target CPU matched it within window_ns.
    void record_wakeup(std::uint64_t ts_ns, int pid, int target_cpu);
    void record_switch(std::uint64_t ts_ns, int cpu, int next_pid);
    // Number of wakeups that were NOT followed by a switch within the window.
    std::uint64_t unnecessary_wakeups() const { return unnecessary_wakeups_; }
    // Number of wakeups that were correlated with a switch.
    std::uint64_t correlated_wakeups() const { return correlated_wakeups_; }

    // Fill the scheduler-owned fields of the pipeline Aggregates struct.
    void fill_aggregates(pipeline::Aggregates& agg) const;

    // Emit a capability event for the pipeline.
    RawEvent capability_event() const;

    // Configuration.
    void set_correlation_window_ns(std::uint64_t ns) { correlation_window_ns_ = ns; }
    std::uint64_t correlation_window_ns() const { return correlation_window_ns_; }

private:
    std::uint64_t correlation_window_ns_ = 1'000'000;  // 1 ms default
    std::vector<WakeupRecord> pending_wakeups_;
    std::uint64_t unnecessary_wakeups_ = 0;
    std::uint64_t correlated_wakeups_ = 0;
    std::uint64_t migrations_ = 0;
    std::uint64_t wakeups_ = 0;
    bool cross_llc_migration_ = false;
};

} // namespace xsprof::sched
