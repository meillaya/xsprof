// Memory collector — capability-gated collection of software page faults,
// HW_CACHE dTLB and LLC misses, AMD IBS ibs_op path, hugepages, buddyinfo,
// and numa_maps pollers. Optional libxsprof_alloc LD_PRELOAD shim.
// Probe returns SKIP when unprivileged (perf_event_paranoid >= 2, fail-closed).
// Story G003 (Phase 3).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "xsprof/event.hpp"
#include "xsprof/pipeline.hpp"
#include "xsprof/proc.hpp"

namespace xsprof::memory {

// Parsed /proc/buddyinfo snapshot for fragmentation estimation.
struct BuddyInfo {
    int node = -1;
    int zone = -1;
    std::string zone_name;
    // Free pages per order (order 0..10 typically).
    std::vector<std::uint64_t> free_per_order;
};

// Parsed hugepage state from /sys/kernel/mm/hugepages/.
struct HugePageState {
    std::uint64_t total = 0;
    std::uint64_t free = 0;
    std::uint64_t size_kb = 0;
    std::string label;  // e.g. "hugepages-2048kB"
};

// Parsed NUMA map entry for a single VMA.
struct NumaMapEntry {
    std::uint64_t vaddr = 0;
    std::string flags;
    int node = -1;
    std::uint64_t pages = 0;
};

// AMD IBS (Instruction-Based Sampling) capability detection.
struct IbsCapability {
    bool ibs_op_present = false;   // /sys/bus/event_source/devices/ibs_op
    bool ibs_fetch_present = false;
    std::string reason;
};

// The memory collector. Implements the ICollector pattern from
// docs/rewrite/COLLECTORS.md: probe() is read-only and never mutates.
class MemoryCollector {
public:
    // Probe capabilities. Returns SKIP when perf_event_paranoid >= 2 and
    // the process lacks CAP_PERFMON (fail-closed). Never auto-elevates.
    Capability probe() const;

    // Probe AMD IBS availability (read-only sysfs check).
    static IbsCapability probe_ibs();

    // Read-only pollers (work without privilege).

    // Parse /proc/buddyinfo and estimate fragmentation ratio (0..1).
    static std::vector<BuddyInfo> poll_buddyinfo();
    static double estimate_fragmentation(const std::vector<BuddyInfo>& info);

    // Parse hugepage state from /sys/kernel/mm/hugepages/.
    static std::vector<HugePageState> poll_hugepages();

    // Parse /proc/<pid>/numa_maps for a given pid.
    // Returns empty vector if unreadable (privacy / permission).
    static std::vector<NumaMapEntry> poll_numa_maps(int pid);

    // Parse one /proc/buddyinfo line. Returns false on parse failure.
    static bool parse_buddyinfo_line(const std::string& line, BuddyInfo& out);

    // Parse one /proc/<pid>/numa_maps line. Returns false on parse failure.
    static bool parse_numa_maps_line(const std::string& line, NumaMapEntry& out);

    // Fill the memory-owned fields of the pipeline Aggregates struct.
    void fill_aggregates(pipeline::Aggregates& agg) const;

    // Emit a capability event for the pipeline.
    RawEvent capability_event() const;

    // Accumulators (fed by perf events when privileged).
    void add_page_faults(std::uint64_t n) { page_faults_ += n; }
    void add_tlb_misses(std::uint64_t n) { tlb_misses_ += n; }
    void add_llc_misses(std::uint64_t n) { llc_misses_ += n; }
    void set_remote_hitm(double v) { remote_hitm_ = v; }
    void set_buddy_fragmentation(double v) { buddy_fragmentation_ = v; }
    void add_small_alloc_churn(std::uint64_t n) { small_alloc_churn_ += n; }
    void set_pmu_collected(bool v) { pmu_collected_ = v; }

private:
    std::uint64_t page_faults_ = 0;
    std::uint64_t tlb_misses_ = 0;
    std::uint64_t llc_misses_ = 0;
    double remote_hitm_ = 0.0;
    double buddy_fragmentation_ = 0.0;
    std::uint64_t small_alloc_churn_ = 0;
    bool pmu_collected_ = false;
};

} // namespace xsprof::memory
