// BPF CO-RE loader implementation — VM-lab-only gate.
// Fail-closed: on the host (no VM-lab marker), load()/capture() always refuse.
// When BTF is absent, returns SKIP. When libbpf is not linked, returns SKIP.
// With XSPROF_HAVE_LIBBPF (a VM-lab build that links -lbpf), capture() opens the
// CO-RE object, attaches its tracepoint programs, and streams ring-buffer events.

#include "xsprof/bpf_loader.hpp"

#include <cstring>
#include <filesystem>

#ifdef XSPROF_HAVE_LIBBPF
#include <bpf/libbpf.h>
#include <cerrno>
#include <vector>
#endif

namespace xsprof::bpf {

#ifdef XSPROF_HAVE_LIBBPF
namespace {

// Must match struct sched_event in bpf/sched_monitor.bpf.c.
struct sched_event {
    std::uint64_t ts_ns;
    std::uint32_t cpu;
    std::int32_t prev_pid;
    std::int32_t next_pid;
    std::int32_t prev_prio;
    std::int32_t next_prio;
    char prev_comm[16];
    char next_comm[16];
    std::uint8_t type; // 0 = switch, 1 = wakeup
};

// Must match struct mem_event in bpf/mem_monitor.bpf.c.
struct mem_event {
    std::uint64_t ts_ns;
    std::uint32_t cpu;
    std::int32_t pid;
    std::int32_t tid;
    std::uint64_t addr;
    std::uint64_t size;
    std::uint8_t type; // 0 = page_fault, 1 = alloc, 2 = free
    char comm[16];
};

struct CaptureCtx {
    std::vector<RawEvent>* out;
    bool is_mem;
};

int handle_event(void* ctx, void* data, std::size_t size) {
    auto* c = static_cast<CaptureCtx*>(ctx);
    if (c->is_mem) {
        if (size < sizeof(mem_event)) return 0;
        auto* e = static_cast<mem_event*>(data);
        RawEvent re;
        re.ts_ns = e->ts_ns;
        re.cpu = static_cast<int>(e->cpu);
        re.pid = e->pid;
        re.tid = e->tid;
        re.kind = (e->type == 0) ? EventKind::PageFault : EventKind::AllocSample;
        re.a = e->size;
        re.comm.assign(e->comm, ::strnlen(e->comm, 16));
        c->out->push_back(std::move(re));
    } else {
        if (size < sizeof(sched_event)) return 0;
        auto* e = static_cast<sched_event*>(data);
        RawEvent re;
        re.ts_ns = e->ts_ns;
        re.cpu = static_cast<int>(e->cpu);
        re.kind = (e->type == 0) ? EventKind::SchedSwitch : EventKind::SchedWakeup;
        re.pid = e->next_pid;
        re.a = static_cast<std::uint64_t>(e->next_pid);
        re.b = static_cast<std::uint64_t>(e->prev_pid);
        re.comm.assign(e->next_comm, ::strnlen(e->next_comm, 16));
        c->out->push_back(std::move(re));
    }
    return 0;
}

} // namespace
#endif // XSPROF_HAVE_LIBBPF

std::string_view load_result_name(LoadResult r) {
    switch (r) {
    case LoadResult::Loaded:
        return "loaded";
    case LoadResult::Refused:
        return "refused";
    case LoadResult::SkipNoBtf:
        return "skip_no_btf";
    case LoadResult::SkipNoLibbpf:
        return "skip_no_libbpf";
    case LoadResult::Error:
        return "error";
    }
    return "unknown";
}

bool BpfLoader::btf_available() {
    return std::filesystem::exists("/sys/kernel/btf/vmlinux");
}

bool BpfLoader::libbpf_linked() {
#ifdef XSPROF_HAVE_LIBBPF
    return true;
#else
    return false;
#endif
}

LoadResult BpfLoader::load(std::string_view object_name, const AuditContext& ctx) {
    SafetyGate gate;
    auto decision = gate.decide(Mutation::SchedExtLoad, ctx);
    if (!decision.allowed) {
        reason_ = "refused: " + decision.reason + " (object=" + std::string(object_name) + ")";
        return LoadResult::Refused;
    }
    if (!btf_available()) {
        reason_ = "SKIP: /sys/kernel/btf/vmlinux not present";
        return LoadResult::SkipNoBtf;
    }
    if (!libbpf_linked()) {
        reason_ = "SKIP: libbpf not linked in this build";
        return LoadResult::SkipNoLibbpf;
    }
#ifdef XSPROF_HAVE_LIBBPF
    struct bpf_object* obj = bpf_object__open_file(std::string(object_name).c_str(), nullptr);
    if (!obj) {
        reason_ = std::string("error: bpf_object__open_file failed: ") + std::strerror(errno);
        return LoadResult::Error;
    }
    if (bpf_object__load(obj) != 0) {
        reason_ = std::string("error: bpf_object__load failed: ") + std::strerror(errno);
        bpf_object__close(obj);
        return LoadResult::Error;
    }
    bpf_object__close(obj);
    reason_ = "loaded (and unloaded) " + std::string(object_name);
    return LoadResult::Loaded;
#else
    reason_ = "error: libbpf load path not compiled";
    return LoadResult::Error;
#endif
}

LoadResult BpfLoader::capture(std::string_view object_path, const AuditContext& ctx,
                              int duration_ms, std::vector<RawEvent>& out) {
    SafetyGate gate;
    auto decision = gate.decide(Mutation::SchedExtLoad, ctx);
    if (!decision.allowed) {
        reason_ = "refused: " + decision.reason + " (object=" + std::string(object_path) + ")";
        return LoadResult::Refused;
    }
    if (!btf_available()) {
        reason_ = "SKIP: /sys/kernel/btf/vmlinux not present";
        return LoadResult::SkipNoBtf;
    }
    if (!libbpf_linked()) {
        reason_ = "SKIP: libbpf not linked in this build";
        return LoadResult::SkipNoLibbpf;
    }
#ifdef XSPROF_HAVE_LIBBPF
    struct bpf_object* obj = bpf_object__open_file(std::string(object_path).c_str(), nullptr);
    if (!obj) {
        reason_ = std::string("error: open failed: ") + std::strerror(errno);
        return LoadResult::Error;
    }
    if (bpf_object__load(obj) != 0) {
        reason_ = std::string("error: load failed (verifier?): ") + std::strerror(errno);
        bpf_object__close(obj);
        return LoadResult::Error;
    }

    std::vector<struct bpf_link*> links;
    struct bpf_program* prog;
    bpf_object__for_each_program(prog, obj) {
        struct bpf_link* link = bpf_program__attach(prog);
        if (link)
            links.push_back(link);
    }

    bool is_mem = false;
    struct bpf_map* map = bpf_object__find_map_by_name(obj, "sched_events");
    if (!map) {
        map = bpf_object__find_map_by_name(obj, "mem_events");
        is_mem = true;
    }
    if (!map) {
        reason_ = "error: no ring-buffer map (sched_events/mem_events) found";
        for (auto* l : links) bpf_link__destroy(l);
        bpf_object__close(obj);
        return LoadResult::Error;
    }

    CaptureCtx cctx{&out, is_mem};
    struct ring_buffer* rb = ring_buffer__new(bpf_map__fd(map), handle_event, &cctx, nullptr);
    if (!rb) {
        reason_ = std::string("error: ring_buffer__new failed: ") + std::strerror(errno);
        for (auto* l : links) bpf_link__destroy(l);
        bpf_object__close(obj);
        return LoadResult::Error;
    }

    int remaining = duration_ms;
    while (remaining > 0) {
        int step = remaining > 100 ? 100 : remaining;
        int n = ring_buffer__poll(rb, step);
        if (n < 0 && n != -EINTR)
            break;
        remaining -= step;
    }

    ring_buffer__free(rb);
    for (auto* l : links) bpf_link__destroy(l);
    bpf_object__close(obj);

    reason_ = "captured " + std::to_string(out.size()) + " events via BPF CO-RE";
    return LoadResult::Loaded;
#else
    (void)duration_ms;
    (void)out;
    reason_ = "SKIP: libbpf not linked in this build";
    return LoadResult::SkipNoLibbpf;
#endif
}

} // namespace xsprof::bpf
