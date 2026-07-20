#include "xsprof/proc.hpp"

#include <dirent.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <charconv>
#include <cstdio>
#include <fstream>
#include <sstream>

namespace xsprof {

std::string cap_state_name(CapState s) {
    switch (s) {
    case CapState::Ready:
        return "READY";
    case CapState::Degraded:
        return "DEGRADED";
    case CapState::Skip:
        return "SKIP";
    case CapState::Refuse:
        return "REFUSE";
    }
    return "UNKNOWN";
}

json::Value Capability::to_json() const {
    json::Value v = json::Value::make_object();
    v.set("name", json::Value(name));
    v.set("state", json::Value(cap_state_name(state)));
    v.set("reason", json::Value(reason));
    v.set("host_mutation", json::Value(false));
    return v;
}

namespace {

bool read_file(const std::string& path, std::string& out) {
    std::ifstream in(path);
    if (!in)
        return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

std::string trim(const std::string& s) {
    std::size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos)
        return "";
    std::size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

long long parse_ll(const std::string& s) {
    long long v = 0;
    std::from_chars(s.data(), s.data() + s.size(), v);
    return v;
}

bool file_exists(const std::string& path) {
    return access(path.c_str(), F_OK) == 0;
}

bool readable(const std::string& path) {
    return access(path.c_str(), R_OK) == 0;
}

// Parse one /proc/stat cpu line: "cpuN user nice system idle iowait irq softirq steal ..."
bool parse_cpu_line(const std::string& line, CpuStat& out) {
    std::istringstream ss(line);
    std::string label;
    ss >> label;
    if (label.rfind("cpu", 0) != 0)
        return false;
    ss >> out.user >> out.nice >> out.system >> out.idle >> out.iowait >> out.irq >> out.softirq >>
        out.steal;
    return true;
}

} // namespace

std::vector<Capability> ProcSource::probe_capabilities() {
    std::vector<Capability> caps;

    // perf_event_paranoid governs unprivileged PMU/tracepoint access.
    {
        std::string content;
        Capability c{"perf_event", CapState::Skip, "perf_event_paranoid unreadable"};
        if (read_file("/proc/sys/kernel/perf_event_paranoid", content)) {
            int paranoid = static_cast<int>(parse_ll(trim(content)));
            if (paranoid <= 1) {
                c.state = CapState::Ready;
                c.reason = "perf_event_paranoid=" + std::to_string(paranoid) +
                           " (PMU/tracepoint collection permitted)";
            } else {
                c.state = CapState::Skip;
                c.reason = "perf_event_paranoid=" + std::to_string(paranoid) +
                           " (need CAP_PERFMON or paranoid<=1; fail-closed SKIP)";
            }
        }
        caps.push_back(c);
    }

    // sched tracepoints readability.
    {
        Capability c{"sched_tracepoints", CapState::Skip, "tracefs sched events unreadable"};
        const std::string sched_events = "/sys/kernel/tracing/events/sched";
        if (readable(sched_events + "/sched_switch/format")) {
            c.state = CapState::Ready;
            c.reason = "sched:sched_switch format readable";
        } else if (file_exists("/sys/kernel/tracing")) {
            c.state = CapState::Skip;
            c.reason =
                "tracefs mounted but " + sched_events + " permission denied (fail-closed SKIP)";
        } else {
            c.state = CapState::Refuse;
            c.reason = "tracefs not mounted";
        }
        caps.push_back(c);
    }

    // BTF for CO-RE BPF.
    {
        Capability c{"btf", CapState::Skip, "no kernel BTF"};
        if (file_exists("/sys/kernel/btf/vmlinux")) {
            c.state = CapState::Ready;
            c.reason = "/sys/kernel/btf/vmlinux present (CO-RE BPF possible)";
        }
        caps.push_back(c);
    }

    // sched_ext presence (read-only sysfs).
    {
        Capability c{"sched_ext", CapState::Skip, "sched_ext not present"};
        if (file_exists("/sys/kernel/sched_ext")) {
            c.state = CapState::Ready;
            c.reason = "/sys/kernel/sched_ext present (read-only observation; load is VM-lab-only)";
        }
        caps.push_back(c);
    }

    // PMU devices.
    {
        Capability c{"pmu", CapState::Skip, "no PMU devices found"};
        DIR* d = opendir("/sys/bus/event_source/devices");
        if (d) {
            int count = 0;
            struct dirent* ent;
            std::string names;
            while ((ent = readdir(d)) != nullptr) {
                if (ent->d_name[0] == '.')
                    continue;
                if (count)
                    names += ",";
                names += ent->d_name;
                ++count;
            }
            closedir(d);
            if (count > 0) {
                c.state = CapState::Ready;
                c.reason = std::to_string(count) + " PMU devices: " + names;
            }
        }
        caps.push_back(c);
    }

    return caps;
}

SystemFacts ProcSource::collect_facts() {
    SystemFacts f;

    char host[256] = {0};
    if (gethostname(host, sizeof(host) - 1) == 0)
        f.hostname = host;

    struct utsname u{};
    if (uname(&u) == 0)
        f.kernel_release = u.release;

    f.online_cpus = static_cast<int>(sysconf(_SC_NPROCESSORS_ONLN));

    // /proc/stat: per-CPU + aggregate.
    {
        std::string content;
        if (read_file("/proc/stat", content)) {
            std::istringstream ss(content);
            std::string line;
            while (std::getline(ss, line)) {
                if (line.rfind("cpu", 0) != 0)
                    continue;
                CpuStat cs;
                if (!parse_cpu_line(line, cs))
                    continue;
                if (line.rfind("cpu ", 0) == 0) {
                    f.aggregate_cpu = cs;
                } else {
                    f.per_cpu.push_back(cs);
                }
            }
        }
    }

    // /proc/meminfo.
    {
        std::string content;
        if (read_file("/proc/meminfo", content)) {
            std::istringstream ss(content);
            std::string key, unit;
            long long val;
            while (ss >> key >> val >> unit) {
                if (key == "MemTotal:")
                    f.mem.mem_total_kb = val;
                else if (key == "MemAvailable:")
                    f.mem.mem_available_kb = val;
                else if (key == "HugePages_Total:")
                    f.mem.huge_pages_total = val;
                else if (key == "HugePages_Free:")
                    f.mem.huge_pages_free = val;
                else if (key == "Hugepagesize:")
                    f.mem.hugepage_size_kb = val;
            }
        }
    }

    // /proc/buddyinfo (fragmentation evidence).
    {
        std::string content;
        if (read_file("/proc/buddyinfo", content)) {
            std::istringstream ss(content);
            std::string line;
            while (std::getline(ss, line)) {
                if (!trim(line).empty())
                    f.buddyinfo.push_back(trim(line));
            }
        }
    }

    // NUMA nodes from /sys/devices/system/node.
    {
        DIR* d = opendir("/sys/devices/system/node");
        if (d) {
            struct dirent* ent;
            while ((ent = readdir(d)) != nullptr) {
                std::string name = ent->d_name;
                if (name.rfind("node", 0) != 0)
                    continue;
                NumaNode n;
                n.id = static_cast<int>(parse_ll(name.substr(4)));
                std::string cpus;
                if (read_file("/sys/devices/system/node/" + name + "/cpulist", cpus)) {
                    n.cpus = trim(cpus);
                }
                f.numa_nodes.push_back(n);
            }
            closedir(d);
        }
    }

    // sched_ext sysfs state (read-only).
    {
        if (file_exists("/sys/kernel/sched_ext")) {
            f.sched_ext.present = true;
            read_file("/sys/kernel/sched_ext/state", f.sched_ext.state);
            read_file("/sys/kernel/sched_ext/switch_all", f.sched_ext.switch_all);
            read_file("/sys/kernel/sched_ext/nr_rejected", f.sched_ext.nr_rejected);
            read_file("/sys/kernel/sched_ext/enable_seq", f.sched_ext.enable_seq);
            read_file("/sys/kernel/sched_ext/hotplug_seq", f.sched_ext.hotplug_seq);
            f.sched_ext.state = trim(f.sched_ext.state);
            f.sched_ext.switch_all = trim(f.sched_ext.switch_all);
            f.sched_ext.nr_rejected = trim(f.sched_ext.nr_rejected);
            f.sched_ext.enable_seq = trim(f.sched_ext.enable_seq);
            f.sched_ext.hotplug_seq = trim(f.sched_ext.hotplug_seq);
        }
    }

    // Paranoid / kptr / BTF / tracefs posture.
    {
        std::string content;
        if (read_file("/proc/sys/kernel/perf_event_paranoid", content))
            f.perf_event_paranoid = static_cast<int>(parse_ll(trim(content)));
        if (read_file("/proc/sys/kernel/kptr_restrict", content))
            f.kptr_restrict = static_cast<int>(parse_ll(trim(content)));
        f.btf_present = file_exists("/sys/kernel/btf/vmlinux");
        f.tracefs_present = file_exists("/sys/kernel/tracing");
    }

    // Process table: numeric-only fields from /proc/<pid>/stat.
    // comm is intentionally NOT collected here (privacy); see PrivacyFilter.
    {
        DIR* d = opendir("/proc");
        if (d) {
            struct dirent* ent;
            while ((ent = readdir(d)) != nullptr) {
                bool numeric = ent->d_name[0] != '\0';
                for (const char* p = ent->d_name; *p; ++p) {
                    if (*p < '0' || *p > '9') {
                        numeric = false;
                        break;
                    }
                }
                if (!numeric)
                    continue;
                std::string stat;
                if (!read_file(std::string("/proc/") + ent->d_name + "/stat", stat))
                    continue;
                // Format: pid (comm) state ppid ...; comm may contain spaces/parens,
                // so anchor on the last ')'.
                auto rp = stat.find_last_of(')');
                if (rp == std::string::npos || rp + 2 >= stat.size())
                    continue;
                ProcessInfo pi;
                pi.pid = static_cast<int>(parse_ll(ent->d_name));
                std::istringstream ss(stat.substr(rp + 2));
                char st;
                ss >> st;
                pi.state = st;
                ss >> pi.ppid;
                // fields: pgrp session tty_nr tpgid flags minflt cminflt majflt
                //         cmaxflt utime stime ...
                long long skip;
                ss >> skip >> skip >> skip >> skip >> skip; // pgrp..flags
                ss >> skip >> skip >> skip >> skip;         // minflt..cmaxflt
                ss >> pi.utime >> pi.stime;
                // cutime cstime priority nice num_threads...
                ss >> skip >> skip >> skip >> skip >> pi.threads;
                f.processes.push_back(pi);
            }
            closedir(d);
        }
    }

    return f;
}

json::Value ProcSource::facts_to_json(const SystemFacts& f) {
    json::Value v = json::Value::make_object();
    v.set("hostname", json::Value(f.hostname));
    v.set("kernel_release", json::Value(f.kernel_release));
    v.set("online_cpus", json::Value(f.online_cpus));
    v.set("perf_event_paranoid", json::Value(f.perf_event_paranoid));
    v.set("kptr_restrict", json::Value(f.kptr_restrict));
    v.set("btf_present", json::Value(f.btf_present));
    v.set("tracefs_present", json::Value(f.tracefs_present));

    json::Value cpu = json::Value::make_object();
    cpu.set("user", json::Value(f.aggregate_cpu.user));
    cpu.set("nice", json::Value(f.aggregate_cpu.nice));
    cpu.set("system", json::Value(f.aggregate_cpu.system));
    cpu.set("idle", json::Value(f.aggregate_cpu.idle));
    cpu.set("iowait", json::Value(f.aggregate_cpu.iowait));
    cpu.set("irq", json::Value(f.aggregate_cpu.irq));
    cpu.set("softirq", json::Value(f.aggregate_cpu.softirq));
    cpu.set("steal", json::Value(f.aggregate_cpu.steal));
    cpu.set("per_cpu_count", json::Value(static_cast<long long>(f.per_cpu.size())));
    v.set("cpu", cpu);

    json::Value mem = json::Value::make_object();
    mem.set("mem_total_kb", json::Value(f.mem.mem_total_kb));
    mem.set("mem_available_kb", json::Value(f.mem.mem_available_kb));
    mem.set("huge_pages_total", json::Value(f.mem.huge_pages_total));
    mem.set("huge_pages_free", json::Value(f.mem.huge_pages_free));
    mem.set("hugepage_size_kb", json::Value(f.mem.hugepage_size_kb));
    v.set("memory", mem);

    json::Value buddy = json::Value::make_array();
    for (const auto& b : f.buddyinfo)
        buddy.push_back(json::Value(b));
    v.set("buddyinfo", buddy);

    json::Value nodes = json::Value::make_array();
    for (const auto& n : f.numa_nodes) {
        json::Value nj = json::Value::make_object();
        nj.set("id", json::Value(n.id));
        nj.set("cpus", json::Value(n.cpus));
        nodes.push_back(nj);
    }
    v.set("numa_nodes", nodes);

    json::Value se = json::Value::make_object();
    se.set("present", json::Value(f.sched_ext.present));
    se.set("state", json::Value(f.sched_ext.state));
    se.set("switch_all", json::Value(f.sched_ext.switch_all));
    se.set("nr_rejected", json::Value(f.sched_ext.nr_rejected));
    se.set("enable_seq", json::Value(f.sched_ext.enable_seq));
    se.set("hotplug_seq", json::Value(f.sched_ext.hotplug_seq));
    v.set("sched_ext", se);

    v.set("process_count", json::Value(static_cast<long long>(f.processes.size())));
    // Read-only observation invariant.
    v.set("host_mutation", json::Value(false));
    return v;
}

} // namespace xsprof
