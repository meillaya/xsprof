// Live capture implementation — perf_event_open ring-buffer capture loop.
// See include/xsprof/live_capture.hpp. Capability-gated and fail-closed: when
// unprivileged, probe() returns SKIP and run() emits no events.
//
// Security hardening (independent review F-01/F-02): all reads from a perf raw
// sample are bounds-checked against the sample's raw_size, and the ring-buffer
// record header is read with wrap-safe modular indexing plus an upper size bound
// so a truncated/malformed sample cannot cause an out-of-bounds read.
#include "xsprof/live_capture.hpp"

#include <linux/perf_event.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <fstream>
#include <map>
#include <vector>

namespace xsprof::capture {

namespace {

long perf_open(struct perf_event_attr* attr, pid_t pid, int cpu, int group_fd) {
    return syscall(SYS_perf_event_open, attr, pid, cpu, group_fd, 0);
}

// Parse a tracepoint format file into field-name -> {offset, size}. Offsets are
// relative to the start of the raw sample payload (which begins with the common
// struct trace_entry, 8 bytes, then the tracepoint-specific fields).
std::map<std::string, std::pair<int, int>> parse_format(const std::string& subsys,
                                                        const std::string& name) {
    std::map<std::string, std::pair<int, int>> fields;
    std::string path = "/sys/kernel/tracing/events/" + subsys + "/" + name + "/format";
    std::ifstream in(path);
    if (!in) return fields;
    std::string line;
    while (std::getline(in, line)) {
        auto fpos = line.find("field:");
        auto opos = line.find("offset:");
        auto spos = line.find("size:");
        if (fpos == std::string::npos || opos == std::string::npos || spos == std::string::npos)
            continue;
        std::string decl = line.substr(fpos + 6, opos - (fpos + 6));
        auto brk = decl.find('[');
        std::string before = (brk == std::string::npos) ? decl : decl.substr(0, brk);
        while (!before.empty() && (before.back() == ' ' || before.back() == '\t'))
            before.pop_back();
        auto sp = before.find_last_of(" \t*");
        std::string fname = (sp == std::string::npos) ? before : before.substr(sp + 1);
        int offset = std::atoi(line.c_str() + opos + 7);
        int size = std::atoi(line.c_str() + spos + 5);
        if (!fname.empty()) fields[fname] = {offset, size};
    }
    return fields;
}

std::uint32_t read_u32(const char* base, int offset) {
    std::uint32_t v = 0;
    std::memcpy(&v, base + offset, sizeof(v));
    return v;
}

// Bounds-checked 32-bit tracepoint field read (F-01). Returns 0 if the field is
// absent or would extend past the raw sample payload.
std::uint32_t read_field(const std::map<std::string, std::pair<int, int>>& fmt, const char* raw,
                         std::uint32_t raw_size, const std::string& field) {
    auto it = fmt.find(field);
    if (it == fmt.end() || it->second.first < 0)
        return 0;
    if (static_cast<std::uint32_t>(it->second.first) + 4 > raw_size)
        return 0;
    return read_u32(raw, it->second.first);
}

// Bounds-checked 16-byte comm read (F-01). Returns false if absent/out-of-bounds.
bool read_comm(const std::map<std::string, std::pair<int, int>>& fmt, const char* raw,
               std::uint32_t raw_size, const std::string& field, char (&out)[16]) {
    auto it = fmt.find(field);
    if (it == fmt.end() || it->second.first < 0)
        return false;
    if (static_cast<std::uint32_t>(it->second.first) + 16 > raw_size)
        return false;
    std::memset(out, 0, 16);
    std::memcpy(out, raw + it->second.first, 16);
    out[15] = '\0';
    return true;
}

} // namespace

long resolve_tracepoint_id(const std::string& subsys, const std::string& name) {
    std::string path = "/sys/kernel/tracing/events/" + subsys + "/" + name + "/id";
    std::ifstream in(path);
    if (!in) return -1;
    long id = -1;
    in >> id;
    return in ? id : -1;
}

Capability LiveCapture::probe() const {
    Capability cap{"live_capture", CapState::Skip, "not probed"};
    long tp = resolve_tracepoint_id("sched", "sched_switch");
    if (tp < 0) {
        cap.reason = "sched tracepoints unreadable (perf_event_paranoid too high or tracefs not "
                     "accessible); live capture needs privilege (fail-closed SKIP)";
        return cap;
    }
    struct perf_event_attr attr;
    std::memset(&attr, 0, sizeof(attr));
    attr.size = sizeof(attr);
    attr.type = PERF_TYPE_TRACEPOINT;
    attr.config = static_cast<std::uint64_t>(tp);
    attr.sample_period = 1;
    attr.sample_type = PERF_SAMPLE_RAW;
    attr.disabled = 1;
    long fd = perf_open(&attr, -1, 0, -1); // system-wide per-CPU open requires privilege
    if (fd < 0) {
        cap.reason = std::string("perf_event_open refused (errno ") + std::to_string(errno) + ": " +
                     std::strerror(errno) +
                     "); live capture needs CAP_PERFMON or perf_event_paranoid<=1 (fail-closed SKIP)";
        return cap;
    }
    ::close(fd);
    cap.state = CapState::Ready;
    cap.reason = "perf_event_open permitted; live capture available";
    return cap;
}

int LiveCapture::open_tracepoint(long tp_id, int cpu, int mmap_pages) {
    struct perf_event_attr attr;
    std::memset(&attr, 0, sizeof(attr));
    attr.size = sizeof(attr);
    attr.type = PERF_TYPE_TRACEPOINT;
    attr.config = static_cast<std::uint64_t>(tp_id);
    attr.sample_period = 1;
    attr.sample_type = PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_CPU | PERF_SAMPLE_RAW;
    attr.disabled = 1; // enabled after mmap is set up (F-04: avoid pre-mmap sample loss)
    long fd = perf_open(&attr, -1, cpu, -1);
    return fd < 0 ? -errno : static_cast<int>(fd);
}

int LiveCapture::open_software(std::uint64_t config, int cpu, int mmap_pages) {
    struct perf_event_attr attr;
    std::memset(&attr, 0, sizeof(attr));
    attr.size = sizeof(attr);
    attr.type = PERF_TYPE_SOFTWARE;
    attr.config = config;
    attr.sample_period = 1;
    attr.sample_type = PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_CPU;
    attr.disabled = 1; // enabled after mmap is set up (F-04)
    long fd = perf_open(&attr, -1, cpu, -1);
    return fd < 0 ? -errno : static_cast<int>(fd);
}

CaptureSummary LiveCapture::run(const CaptureConfig& cfg, std::vector<RawEvent>& out) {
    CaptureSummary summary;
    summary.capability = probe();
    if (summary.capability.state != CapState::Ready) return summary; // fail-closed

    const int ncpu = static_cast<int>(sysconf(_SC_NPROCESSORS_ONLN));
    const long page_size = sysconf(_SC_PAGESIZE);
    const size_t map_size = static_cast<size_t>(1 + cfg.mmap_pages) * page_size;
    const size_t data_size = static_cast<size_t>(cfg.mmap_pages) * page_size;

    long sw_id = cfg.sched_switch ? resolve_tracepoint_id("sched", "sched_switch") : -1;
    long wk_id = cfg.sched_wakeup ? resolve_tracepoint_id("sched", "sched_wakeup") : -1;
    long mg_id = cfg.sched_migrate ? resolve_tracepoint_id("sched", "sched_migrate_task") : -1;
    auto sw_fmt = parse_format("sched", "sched_switch");
    auto wk_fmt = parse_format("sched", "sched_wakeup");
    auto mg_fmt = parse_format("sched", "sched_migrate_task");

    struct Slot {
        enum Kind { SW, WK, MG, PF };
        int fd = -1;
        void* base = nullptr;
        Kind kind = SW;
    };
    std::vector<Slot> slots;

    auto open_tp = [&](long id, Slot::Kind kind) {
        if (id < 0) return;
        for (int cpu = 0; cpu < ncpu; ++cpu) {
            int fd = open_tracepoint(id, cpu, cfg.mmap_pages);
            if (fd < 0) continue;
            void* base = mmap(nullptr, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (base == MAP_FAILED) {
                ::close(fd);
                continue;
            }
            slots.push_back(Slot{fd, base, kind});
        }
    };

    if (cfg.sched_switch) open_tp(sw_id, Slot::SW);
    if (cfg.sched_wakeup) open_tp(wk_id, Slot::WK);
    if (cfg.sched_migrate) open_tp(mg_id, Slot::MG);
    if (cfg.page_faults) {
        for (int cpu = 0; cpu < ncpu; ++cpu) {
            int fd = open_software(PERF_COUNT_SW_PAGE_FAULTS, cpu, cfg.mmap_pages);
            if (fd < 0) continue;
            void* base = mmap(nullptr, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (base == MAP_FAILED) {
                ::close(fd);
                continue;
            }
            slots.push_back(Slot{fd, base, Slot::PF});
        }
    }

    if (slots.empty()) {
        summary.capability.state = CapState::Skip;
        summary.capability.reason = "no perf events could be opened (fail-closed SKIP)";
        return summary;
    }

    // Enable events only after all ring buffers are mapped (F-04).
    for (auto& s : slots)
        ioctl(s.fd, PERF_EVENT_IOC_ENABLE, 0);

    std::vector<struct pollfd> pfds(slots.size());
    for (size_t i = 0; i < slots.size(); ++i) {
        pfds[i].fd = slots[i].fd;
        pfds[i].events = POLLIN;
    }

    auto drain = [&](Slot& s) {
        auto* mc = static_cast<struct perf_event_mmap_page*>(s.base);
        char* data = static_cast<char*>(s.base) + page_size;
        std::uint64_t head = mc->data_head;
        std::uint64_t tail = mc->data_tail;
        while (tail + sizeof(struct perf_event_header) <= head) {
            size_t pos = tail % data_size;
            // Read the header with wrap-safe modular indexing (F-02).
            struct perf_event_header hdr;
            char* hbytes = reinterpret_cast<char*>(&hdr);
            for (std::size_t b = 0; b < sizeof(hdr); ++b)
                hbytes[b] = data[(pos + b) % data_size];
            // Reject corrupt or oversized records (F-02).
            if (hdr.size < sizeof(hdr) || hdr.size > data_size)
                break;
            std::vector<char> rec(hdr.size);
            for (std::uint32_t b = 0; b < hdr.size; ++b)
                rec[b] = data[(pos + b) % data_size];
            const char* p = rec.data();
            if (hdr.type == PERF_RECORD_LOST) {
                if (hdr.size >= sizeof(hdr) + 16) {
                    std::uint64_t lost = 0;
                    std::memcpy(&lost, p + sizeof(hdr) + 8, 8);
                    summary.lost_samples += lost;
                }
            } else if (hdr.type == PERF_RECORD_SAMPLE) {
                const char* cur = p + sizeof(hdr);
                const char* rec_end = p + hdr.size;
                // sample_type order: TID, TIME, CPU, RAW (need 24 bytes minimum).
                if (cur + 24 > rec_end) {
                    tail += hdr.size;
                    continue;
                }
                std::uint32_t pid = 0, tid = 0, cpu = 0, res = 0;
                std::uint64_t time = 0;
                std::memcpy(&pid, cur, 4); cur += 4;
                std::memcpy(&tid, cur, 4); cur += 4;
                std::memcpy(&time, cur, 8); cur += 8;
                std::memcpy(&cpu, cur, 4); cur += 4;
                std::memcpy(&res, cur, 4); cur += 4;
                (void)res;
                RawEvent e;
                e.ts_ns = time;
                e.cpu = static_cast<int>(cpu);
                e.pid = static_cast<int>(pid);
                e.tid = static_cast<int>(tid);
                if (s.kind == Slot::SW) {
                    std::uint32_t raw_size = 0;
                    std::memcpy(&raw_size, cur, 4);
                    const char* raw = cur + 4;
                    e.kind = EventKind::SchedSwitch;
                    e.a = read_field(sw_fmt, raw, raw_size, "next_pid");
                    e.b = read_field(sw_fmt, raw, raw_size, "prev_pid");
                    char comm[16];
                    if (read_comm(sw_fmt, raw, raw_size, "next_comm", comm))
                        e.comm = comm;
                    summary.sched_switches++;
                } else if (s.kind == Slot::WK) {
                    std::uint32_t raw_size = 0;
                    std::memcpy(&raw_size, cur, 4);
                    const char* raw = cur + 4;
                    e.kind = EventKind::SchedWakeup;
                    e.a = read_field(wk_fmt, raw, raw_size, "pid");
                    e.b = read_field(wk_fmt, raw, raw_size, "target_cpu");
                    summary.sched_wakeups++;
                } else if (s.kind == Slot::MG) {
                    std::uint32_t raw_size = 0;
                    std::memcpy(&raw_size, cur, 4);
                    const char* raw = cur + 4;
                    e.kind = EventKind::SchedMigrate;
                    std::uint32_t mpid = read_field(mg_fmt, raw, raw_size, "pid");
                    if (mpid) e.pid = static_cast<int>(mpid);
                    e.a = read_field(mg_fmt, raw, raw_size, "orig_cpu");
                    e.b = read_field(mg_fmt, raw, raw_size, "dest_cpu");
                    summary.sched_migrations++;
                } else { // PF
                    e.kind = EventKind::PageFault;
                    e.a = 1;
                    summary.page_faults++;
                }
                summary.events_captured++;
                out.push_back(std::move(e));
            }
            tail += hdr.size;
        }
        mc->data_tail = tail;
    };

    int remaining_ms = cfg.duration_ms;
    while (remaining_ms > 0) {
        int step = remaining_ms > 200 ? 200 : remaining_ms;
        int r = ::poll(pfds.data(), pfds.size(), step);
        remaining_ms -= step;
        if (r < 0 && errno != EINTR) break;
        for (size_t i = 0; i < slots.size(); ++i)
            if (pfds[i].revents & POLLIN) drain(slots[i]);
    }
    for (auto& s : slots) drain(s);

    for (auto& s : slots) {
        if (s.base) munmap(s.base, map_size);
        if (s.fd >= 0) ::close(s.fd);
    }

    summary.capability.state = CapState::Ready;
    summary.capability.reason = "captured " + std::to_string(summary.events_captured) + " events";
    return summary;
}

} // namespace xsprof::capture
