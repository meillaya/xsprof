// Pipeline aggregation and sink interface — the frozen contract between
// collectors (scheduler, memory) and downstream consumers (advisor, viz).
// Later collector lanes fill Aggregates fields without editing this header.
// See docs/rewrite/COLLECTORS.md and docs/rewrite/ARCHITECTURE.md.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "xsprof/event.hpp"
#include "xsprof/json.hpp"

namespace xsprof::pipeline {

// Frozen aggregate snapshot. Collectors fill their owned fields; the advisor
// and viz layers consume the whole struct. Fields default to zero / uncollected
// so a partially-filled struct never produces false findings (fail-closed).
struct Aggregates {
    // --- NUMA / placement (memory collector) ---
    double remote_fault_ratio = 0.0;   // remote / (local+remote) hint faults
    int dominant_node = -1;            // node holding most of a task's memory
    int task_cpu_node = -1;            // node the task currently runs on

    // --- scheduler (sched collector) ---
    long long migrations = 0;
    bool cross_llc_migration = false;
    int llc_domains = 1;
    long long wakeups = 0;
    long long unnecessary_wakeups = 0;  // wakeups not followed by a run in-window
    long long lock_contentions = 0;
    double avg_lock_wait_ms = 0.0;

    // --- cache / memory (memory collector, PMU) ---
    long long llc_misses = 0;
    long long tlb_misses = 0;
    long long page_faults = 0;
    double remote_hitm = 0.0;           // cross-cache-line HITM (false sharing)

    // --- allocator (memory collector) ---
    double buddy_fragmentation = 0.0;   // 0..1 from /proc/buddyinfo
    long long small_alloc_churn = 0;

    // --- priority inversion (sched collector) ---
    bool priority_inversion_observed = false;

    // --- capability context (never emit findings from uncollected signals) ---
    bool pmu_collected = false;
    bool sched_collected = false;

    // Serialize to a stable JSON representation (xsprof/aggregates/v1).
    json::Value to_json() const;
};

// Abstract sink: collectors push events and periodic aggregate snapshots into
// the pipeline; downstream stages (advisor, viz, journal) consume them.
// Implementations must be safe to call from the collector thread.
class PipelineSink {
public:
    virtual ~PipelineSink() = default;

    // Accept one raw event. Returns false if the event was dropped (e.g. ring
    // buffer full); the caller should record a sample-loss Marker.
    virtual bool on_event(const RawEvent& event) = 0;

    // Accept a periodic aggregate snapshot (e.g. every N events or M ms).
    virtual void on_aggregates(const Aggregates& agg) = 0;

    // Signal that the collector has finished (flush / finalize).
    virtual void on_complete() = 0;
};

// A no-op sink that counts events (useful for testing and dry-run mode).
class CountingSink final : public PipelineSink {
public:
    bool on_event(const RawEvent&) override { ++events_; return true; }
    void on_aggregates(const Aggregates&) override { ++snapshots_; }
    void on_complete() override { complete_ = true; }

    std::uint64_t events() const { return events_; }
    std::uint64_t snapshots() const { return snapshots_; }
    bool complete() const { return complete_; }

private:
    std::uint64_t events_ = 0;
    std::uint64_t snapshots_ = 0;
    bool complete_ = false;
};

} // namespace xsprof::pipeline
