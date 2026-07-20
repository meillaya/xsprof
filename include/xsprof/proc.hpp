// Read-only host fact collection + capability probing.
// Mirrors src/observability/* and src/preflight_main.zig from the archived
// Zig project: pure observation, no mutation, no BPF load. Collectors that
// need privilege probe() and report SKIP/REFUSE instead of failing silently.
#pragma once

#include <string>
#include <vector>

#include "xsprof/json.hpp"

namespace xsprof {

enum class CapState { Ready, Degraded, Skip, Refuse };

std::string cap_state_name(CapState s);

struct Capability {
    std::string name;
    CapState state = CapState::Skip;
    std::string reason;
    json::Value to_json() const;
};

struct CpuStat {
    long long user = 0, nice = 0, system = 0, idle = 0, iowait = 0, irq = 0, softirq = 0, steal = 0;
    long long total() const { return user + nice + system + idle + iowait + irq + softirq + steal; }
};

struct MemInfo {
    long long mem_total_kb = 0;
    long long mem_available_kb = 0;
    long long huge_pages_total = 0;
    long long huge_pages_free = 0;
    long long hugepage_size_kb = 0;
};

struct NumaNode {
    int id = -1;
    std::string cpus;
};

struct SchedExtState {
    bool present = false;
    std::string state;
    std::string switch_all;
    std::string nr_rejected;
    std::string enable_seq;
    std::string hotplug_seq;
};

struct ProcessInfo {
    int pid = -1;
    int ppid = -1;
    char state = '?';
    int threads = 0;
    long long utime = 0;
    long long stime = 0;
};

// A read-only snapshot of host facts. No field carries argv/env/secrets.
struct SystemFacts {
    std::string hostname;
    std::string kernel_release;
    int online_cpus = 0;
    std::vector<CpuStat> per_cpu; // per-CPU jiffies since boot
    CpuStat aggregate_cpu;
    MemInfo mem;
    std::vector<std::string> buddyinfo; // raw lines (fragmentation evidence)
    std::vector<NumaNode> numa_nodes;
    SchedExtState sched_ext;
    int perf_event_paranoid = 99;
    int kptr_restrict = 99;
    bool btf_present = false;
    bool tracefs_present = false;
    std::vector<ProcessInfo> processes; // numeric-only, privacy-safe
};

class ProcSource {
  public:
    // Probe collector capabilities against the live kernel (read-only).
    static std::vector<Capability> probe_capabilities();
    // Collect a read-only snapshot of host facts.
    static SystemFacts collect_facts();
    static json::Value facts_to_json(const SystemFacts& f);
};

} // namespace xsprof
