// BPF CO-RE loader implementation — VM-lab-only gate.
// Fail-closed: on the host (no VM-lab marker), load() always refuses.
// When BTF is absent, returns SKIP. When libbpf is not linked, returns SKIP.
// Actual BPF loading is only attempted with a full audit context in a VM lab.

#include "xsprof/bpf_loader.hpp"

#include <filesystem>

namespace xsprof::bpf {

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
    // In this build, libbpf is not linked. A real VM-lab build would
    // define XSPROF_HAVE_LIBBPF and link -lbpf.
#ifdef XSPROF_HAVE_LIBBPF
    return true;
#else
    return false;
#endif
}

LoadResult BpfLoader::load(std::string_view object_name, const AuditContext& ctx) {
    // Fail-closed: refuse unless full VM-lab audit context is present.
    SafetyGate gate;
    auto decision = gate.decide(Mutation::SchedExtLoad, ctx);
    if (!decision.allowed) {
        reason_ = "refused: " + decision.reason + " (object=" + std::string(object_name) + ")";
        return LoadResult::Refused;
    }

    // VM-lab marker present and audit context valid — attempt load.
    if (!btf_available()) {
        reason_ = "SKIP: /sys/kernel/btf/vmlinux not present";
        return LoadResult::SkipNoBtf;
    }

    if (!libbpf_linked()) {
        reason_ = "SKIP: libbpf not linked in this build";
        return LoadResult::SkipNoLibbpf;
    }

    // In a real VM-lab build with libbpf, we would:
    // 1. Open the skeleton (sched_monitor.skel.h / mem_monitor.skel.h)
    // 2. Load the BPF object
    // 3. Attach to tracepoints
    // 4. Return the prog fd
    // For now, the host build never reaches here because libbpf is not linked.
    reason_ = "error: libbpf load path not implemented in host build";
    return LoadResult::Error;
}

} // namespace xsprof::bpf
