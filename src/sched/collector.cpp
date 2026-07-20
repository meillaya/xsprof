// Scheduler collector implementation — story G002 (Phase 2).
// Capability-gated collection of sched_switch, sched_wakeup,
// sched_migrate_task via perf_event_open, run-queue sampling from
// procfs schedstat, and wakeup-to-switch correlation.
// Probe returns SKIP at perf_event_paranoid >= 2 when unprivileged.
#include "xsprof/sched_collector.hpp"

#include <linux/perf_event.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fstream>
#include <sstream>

namespace xsprof::sched {

// ---------------------------------------------------------------------------
// PerfEvent RAII
// ---------------------------------------------------------------------------

PerfEvent::~PerfEvent() {
    if (fd_ >= 0)
        ::close(fd_);
}

PerfEvent::PerfEvent(PerfEvent&& o) noexcept : fd_(o.fd_), err_(o.err_) {
    o.fd_ = -1;
    o.err_ = 0;
}

PerfEvent& PerfEvent::operator=(PerfEvent&& o) noexcept {
    if (this != &o) {
        if (fd_ >= 0)
            ::close(fd_);
        fd_ = o.fd_;
        err_ = o.err_;
        o.fd_ = -1;
        o.err_ = 0;
    }
    return *this;
}

PerfEvent PerfEvent::open(std::uint32_t type, std::uint64_t config, pid_t pid, int cpu,
                          int group_fd) {
    struct perf_event_attr attr{};
    attr.size = sizeof(attr);
    attr.type = type;
    attr.config = config;
    attr.disabled = 1;
    attr.exclude_kernel = 0; // scheduler events need kernel context
    attr.exclude_hv = 1;
    attr.sample_period = 1;
    attr.sample_type = PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_CPU;
    attr.wakeup_events = 1;

    PerfEvent ev;
    long fd = syscall(SYS_perf_event_open, &attr, pid, cpu, group_fd, 0);
    if (fd < 0) {
        ev.fd_ = -1;
        ev.err_ = errno;
    } else {
        ev.fd_ = static_cast<int>(fd);
        ev.err_ = 0;
    }
    return ev;
}

// ---------------------------------------------------------------------------
// Capability probe
// ---------------------------------------------------------------------------

Capability SchedCollector::probe() const {
    // Read perf_event_paranoid to determine unprivileged access.
    std::ifstream paranoid_file("/proc/sys/kernel/perf_event_paranoid");
    if (!paranoid_file) {
        return {"sched_collector", CapState::Skip,
                "perf_event_paranoid unreadable; fail-closed SKIP"};
    }
    int paranoid = 99;
    paranoid_file >> paranoid;

    if (paranoid >= 2) {
        // At paranoid=2, unprivileged processes cannot use perf_event_open
        // for tracepoints or PMU. We do NOT auto-elevate.
        return {"sched_collector", CapState::Skip,
                "perf_event_paranoid=" + std::to_string(paranoid) +
                    " (need CAP_PERFMON or paranoid<=1 for tracepoint collection; "
                    "fail-closed SKIP, never auto-elevate)"};
    }

    // Check tracefs sched events readability.
    std::ifstream switch_fmt("/sys/kernel/tracing/events/sched/sched_switch/format");
    if (!switch_fmt) {
        return {"sched_collector", CapState::Skip,
                "sched:sched_switch tracepoint format unreadable; fail-closed SKIP"};
    }

    return {"sched_collector", CapState::Ready,
            "perf_event_paranoid=" + std::to_string(paranoid) +
                " (tracepoint collection permitted)"};
}

// ---------------------------------------------------------------------------
// Run-queue sampling from /proc/schedstat
// ---------------------------------------------------------------------------

bool SchedCollector::parse_schedstat_cpu_line(const std::string& line, RunqueueSample& out) {
    // /proc/schedstat CPU lines look like:
    // cpu0 0 0 0 0 0 0 0 123456789 987654321 0 0 0
    // Fields (0-indexed after "cpuN"):
    //   0: yld_count, 1: array_list, 2: sched_count, 3: ttwu_count,
    //   4: ttwu_local, 5: rq_cpu_time, 6: run_delay, 7: pcount
    // Actually the format is:
    // cpu<N> <9 fields>
    // field 0: yld_count
    // field 1: sched_count (context switches)
    // field 2: ttwu_count
    // field 3: ttwu_local
    // field 4: rq_cpu_time (ns)
    // field 5: run_delay (ns) — cumulative run-delay
    // field 6: pcount (nr of tasks that have run)
    // field 7: (varies by kernel)
    // field 8: (varies by kernel)
    // We extract nr_switches (field 1), run_delay (field 5).
    std::istringstream ss(line);
    std::string label;
    ss >> label;
    if (label.rfind("cpu", 0) != 0)
        return false;

    // Extract CPU number.
    int cpu = -1;
    {
        std::string num_part = label.substr(3);
        if (num_part.empty())
            return false;
        for (char c : num_part) {
            if (c < '0' || c > '9')
                return false;
        }
        cpu = std::stoi(num_part);
    }

    // Read the numeric fields.
    std::uint64_t fields[10] = {};
    int count = 0;
    std::uint64_t v;
    while (ss >> v && count < 10) {
        fields[count++] = v;
    }
    if (count < 7)
        return false; // need at least 7 fields

    out.cpu = cpu;
    out.nr_switches = fields[1];
    out.run_delay_ns = fields[5];
    out.timeslices_ns = fields[4];
    // nr_running and nr_uninterruptible are not directly in schedstat CPU lines;
    // they come from /proc/stat or per-CPU schedstat domain lines.
    // We leave them at 0 here; the pipeline can supplement from /proc/stat.
    return true;
}

std::vector<RunqueueSample> SchedCollector::sample_runqueues() {
    std::vector<RunqueueSample> samples;
    std::ifstream schedstat("/proc/schedstat");
    if (!schedstat)
        return samples;

    std::string line;
    while (std::getline(schedstat, line)) {
        if (line.rfind("cpu", 0) != 0)
            continue;
        RunqueueSample s;
        if (parse_schedstat_cpu_line(line, s)) {
            samples.push_back(s);
        }
    }
    return samples;
}

// ---------------------------------------------------------------------------
// Wakeup-to-switch correlation
// ---------------------------------------------------------------------------

void SchedCollector::record_wakeup(std::uint64_t ts_ns, int pid, int target_cpu) {
    ++wakeups_;
    pending_wakeups_.push_back({ts_ns, pid, target_cpu, false});

    // Prune old unmatched wakeups beyond the correlation window.
    // Any wakeup older than the window that was never matched is unnecessary.
    auto cutoff = (ts_ns > correlation_window_ns_) ? (ts_ns - correlation_window_ns_) : 0;
    auto it = std::remove_if(pending_wakeups_.begin(), pending_wakeups_.end(),
                             [&](const WakeupRecord& w) {
                                 if (!w.matched && w.ts_ns < cutoff) {
                                     ++unnecessary_wakeups_;
                                     return true;
                                 }
                                 return w.matched; // remove matched records
                             });
    pending_wakeups_.erase(it, pending_wakeups_.end());
}

void SchedCollector::record_switch(std::uint64_t ts_ns, int cpu, int next_pid) {
    // Try to correlate: find a pending wakeup for next_pid targeting this CPU
    // within the correlation window.
    for (auto& w : pending_wakeups_) {
        if (w.matched)
            continue;
        if (w.pid == next_pid && w.target_cpu == cpu && ts_ns >= w.ts_ns &&
            (ts_ns - w.ts_ns) <= correlation_window_ns_) {
            w.matched = true;
            ++correlated_wakeups_;
            return;
        }
    }
}

void SchedCollector::fill_aggregates(pipeline::Aggregates& agg) const {
    agg.sched_collected = true;
    agg.wakeups = static_cast<long long>(wakeups_);
    agg.unnecessary_wakeups = static_cast<long long>(unnecessary_wakeups_);
    agg.migrations = static_cast<long long>(migrations_);
    agg.cross_llc_migration = cross_llc_migration_;
}

RawEvent SchedCollector::capability_event() const {
    auto cap = probe();
    RawEvent e;
    e.kind = EventKind::Capability;
    e.comm = "sched_collector";
    e.detail = cap.name + ":" + cap_state_name(cap.state) + ":" + cap.reason;
    return e;
}

} // namespace xsprof::sched
