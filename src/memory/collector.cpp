// Memory collector implementation — story G003 (Phase 3).
// Capability-gated collection of software page faults, HW_CACHE dTLB and
// LLC misses, AMD IBS ibs_op path, hugepages, buddyinfo, and numa_maps
// pollers. Probe returns SKIP when unprivileged (fail-closed).
#include "xsprof/memory_collector.hpp"

#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <sstream>

namespace xsprof::memory {

// ---------------------------------------------------------------------------
// Capability probe
// ---------------------------------------------------------------------------

Capability MemoryCollector::probe() const {
    // Read perf_event_paranoid to determine unprivileged PMU access.
    std::ifstream paranoid_file("/proc/sys/kernel/perf_event_paranoid");
    if (!paranoid_file) {
        return {"memory_collector", CapState::Skip,
                "perf_event_paranoid unreadable; fail-closed SKIP"};
    }
    int paranoid = 99;
    paranoid_file >> paranoid;

    if (paranoid >= 2) {
        // At paranoid=2, unprivileged processes cannot use perf_event_open
        // for HW_CACHE or software page-fault sampling. We do NOT auto-elevate.
        return {"memory_collector", CapState::Skip,
                "perf_event_paranoid=" + std::to_string(paranoid) +
                " (need CAP_PERFMON or paranoid<=1 for PMU/page-fault collection; "
                "fail-closed SKIP, never auto-elevate)"};
    }

    // Check for PMU devices.
    bool have_pmu = false;
    DIR* d = opendir("/sys/bus/event_source/devices");
    if (d) {
        struct dirent* ent;
        while ((ent = readdir(d)) != nullptr) {
            if (ent->d_name[0] == '.') continue;
            have_pmu = true;
            break;
        }
        closedir(d);
    }

    if (!have_pmu) {
        return {"memory_collector", CapState::Degraded,
                "perf_event_paranoid=" + std::to_string(paranoid) +
                " but no PMU devices found; software page faults only"};
    }

    // Check for AMD IBS.
    auto ibs = probe_ibs();
    std::string ibs_note = ibs.ibs_op_present ? " (AMD IBS ibs_op available)" : "";

    return {"memory_collector", CapState::Ready,
            "perf_event_paranoid=" + std::to_string(paranoid) +
            " (PMU collection permitted)" + ibs_note};
}

IbsCapability MemoryCollector::probe_ibs() {
    IbsCapability cap;
    // AMD IBS exposes /sys/bus/event_source/devices/ibs_op and ibs_fetch.
    cap.ibs_op_present = (access("/sys/bus/event_source/devices/ibs_op", F_OK) == 0);
    cap.ibs_fetch_present = (access("/sys/bus/event_source/devices/ibs_fetch", F_OK) == 0);
    if (cap.ibs_op_present) {
        cap.reason = "AMD IBS ibs_op present; precise memory-access profiling available";
    } else if (cap.ibs_fetch_present) {
        cap.reason = "AMD IBS ibs_fetch present (fetch-only, no op sampling)";
    } else {
        cap.reason = "AMD IBS not present; falling back to generic HW_CACHE events";
    }
    return cap;
}

// ---------------------------------------------------------------------------
// Buddyinfo poller
// ---------------------------------------------------------------------------

bool MemoryCollector::parse_buddyinfo_line(const std::string& line,
                                            BuddyInfo& out) {
    // Format: "Node N, zone   ZoneName   free1 free2 ... freeN"
    // Example: "Node 0, zone      DMA      1      1      1      0      2      1      1      0      1      1      3"
    std::istringstream ss(line);
    std::string tok;
    ss >> tok;  // "Node"
    if (tok != "Node") return false;
    int node = -1;
    ss >> node;
    ss >> tok;  // comma
    ss >> tok;  // "zone"
    if (tok != "zone") return false;
    std::string zone_name;
    ss >> zone_name;

    std::vector<std::uint64_t> free_per_order;
    std::uint64_t v;
    while (ss >> v) {
        free_per_order.push_back(v);
    }
    if (free_per_order.empty()) return false;

    out.node = node;
    out.zone_name = zone_name;
    out.free_per_order = std::move(free_per_order);
    return true;
}

std::vector<BuddyInfo> MemoryCollector::poll_buddyinfo() {
    std::vector<BuddyInfo> result;
    std::ifstream f("/proc/buddyinfo");
    if (!f) return result;
    std::string line;
    while (std::getline(f, line)) {
        BuddyInfo bi;
        if (parse_buddyinfo_line(line, bi)) {
            result.push_back(std::move(bi));
        }
    }
    return result;
}

double MemoryCollector::estimate_fragmentation(
    const std::vector<BuddyInfo>& info) {
    // Fragmentation heuristic: ratio of free pages in low orders (0-3) to
    // total free pages across all orders. High ratio = fragmented.
    // Returns 0..1 (0 = no fragmentation, 1 = fully fragmented).
    std::uint64_t low_order_pages = 0;
    std::uint64_t total_pages = 0;
    for (const auto& bi : info) {
        for (std::size_t order = 0; order < bi.free_per_order.size(); ++order) {
            std::uint64_t pages = bi.free_per_order[order] * (1ULL << order);
            total_pages += pages;
            if (order <= 3) {
                low_order_pages += pages;
            }
        }
    }
    if (total_pages == 0) return 0.0;
    return static_cast<double>(low_order_pages) / static_cast<double>(total_pages);
}

// ---------------------------------------------------------------------------
// Hugepages poller
// ---------------------------------------------------------------------------

std::vector<HugePageState> MemoryCollector::poll_hugepages() {
    std::vector<HugePageState> result;
    const std::string base = "/sys/kernel/mm/hugepages";
    DIR* d = opendir(base.c_str());
    if (!d) return result;

    struct dirent* ent;
    while ((ent = readdir(d)) != nullptr) {
        if (ent->d_name[0] == '.') continue;
        std::string dir_name = ent->d_name;
        if (dir_name.rfind("hugepages-", 0) != 0) continue;

        HugePageState hp;
        hp.label = dir_name;

        // Parse size from directory name: "hugepages-2048kB" -> 2048
        {
            std::string num_str;
            for (std::size_t i = 12; i < dir_name.size(); ++i) {
                if (dir_name[i] >= '0' && dir_name[i] <= '9')
                    num_str += dir_name[i];
                else
                    break;
            }
            if (!num_str.empty()) hp.size_kb = std::stoull(num_str);
        }

        // Read nr_hugepages and free_hugepages.
        {
            std::ifstream nr(base + "/" + dir_name + "/nr_hugepages");
            if (nr) nr >> hp.total;
        }
        {
            std::ifstream fr(base + "/" + dir_name + "/free_hugepages");
            if (fr) fr >> hp.free;
        }
        result.push_back(std::move(hp));
    }
    closedir(d);
    return result;
}

// ---------------------------------------------------------------------------
// Numa_maps poller
// ---------------------------------------------------------------------------

bool MemoryCollector::parse_numa_maps_line(const std::string& line,
                                            NumaMapEntry& out) {
    // Format: "<hex_addr> <flags> [key=value ...] [N<node>=<pages> ...]"
    // Example: "00400000 default file=/usr/bin/foo mapped=10 N0=10"
    std::istringstream ss(line);
    std::string addr_str;
    ss >> addr_str;
    if (addr_str.empty()) return false;

    // Parse hex address.
    std::uint64_t vaddr = 0;
    {
        // Simple hex parse.
        for (char c : addr_str) {
            int d = 0;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
            else return false;
            vaddr = vaddr * 16 + static_cast<std::uint64_t>(d);
        }
    }

    std::string flags;
    ss >> flags;

    // Scan for N<node>=<pages> tokens.
    int best_node = -1;
    std::uint64_t best_pages = 0;
    std::string tok;
    while (ss >> tok) {
        if (tok.size() > 2 && tok[0] == 'N' && tok[1] >= '0' && tok[1] <= '9') {
            auto eq = tok.find('=');
            if (eq != std::string::npos) {
                int node = std::stoi(tok.substr(1, eq - 1));
                std::uint64_t pages = std::stoull(tok.substr(eq + 1));
                if (pages > best_pages) {
                    best_pages = pages;
                    best_node = node;
                }
            }
        }
    }

    out.vaddr = vaddr;
    out.flags = flags;
    out.node = best_node;
    out.pages = best_pages;
    return true;
}

std::vector<NumaMapEntry> MemoryCollector::poll_numa_maps(int pid) {
    std::vector<NumaMapEntry> result;
    std::string path = "/proc/" + std::to_string(pid) + "/numa_maps";
    std::ifstream f(path);
    if (!f) return result;  // permission denied or process gone

    std::string line;
    while (std::getline(f, line)) {
        NumaMapEntry entry;
        if (parse_numa_maps_line(line, entry)) {
            result.push_back(std::move(entry));
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Aggregates
// ---------------------------------------------------------------------------

void MemoryCollector::fill_aggregates(pipeline::Aggregates& agg) const {
    agg.pmu_collected = pmu_collected_;
    agg.page_faults = static_cast<long long>(page_faults_);
    agg.tlb_misses = static_cast<long long>(tlb_misses_);
    agg.llc_misses = static_cast<long long>(llc_misses_);
    agg.remote_hitm = remote_hitm_;
    agg.buddy_fragmentation = buddy_fragmentation_;
    agg.small_alloc_churn = static_cast<long long>(small_alloc_churn_);
}

RawEvent MemoryCollector::capability_event() const {
    auto cap = probe();
    RawEvent e;
    e.kind = EventKind::Capability;
    e.comm = "memory_collector";
    e.detail = cap.name + ":" + cap_state_name(cap.state) + ":" + cap.reason;
    return e;
}

} // namespace xsprof::memory
