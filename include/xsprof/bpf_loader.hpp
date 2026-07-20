// xsprof BPF CO-RE loader — VM-lab-only gate.
// On the host, load() refuses (fail-closed). In a VM lab with a valid
// audit context, it attempts to load the CO-RE objects via libbpf.
// Returns SKIP when BTF is absent (no /sys/kernel/btf/vmlinux).
#pragma once

#include <string>
#include <string_view>

#include "xsprof/safety.hpp"

namespace xsprof::bpf {

enum class LoadResult {
    Loaded,       // successfully loaded (VM-lab only)
    Refused,      // refused on host (fail-closed)
    SkipNoBtf,    // BTF not available — SKIP
    SkipNoLibbpf, // libbpf not linked — SKIP
    Error,        // load failed
};

std::string_view load_result_name(LoadResult r);

struct BpfObjectInfo {
    std::string name;        // e.g. "sched_monitor", "mem_monitor"
    std::string object_path; // path to .bpf.o
    bool loaded = false;
    int prog_fd = -1;
};

class BpfLoader {
  public:
    // Attempt to load a BPF CO-RE object.
    // Fail-closed: refuses unless the AuditContext has allow_mutate=true,
    // a valid audit_id, rollback_id, and vm_lab_marker=true.
    LoadResult load(std::string_view object_name, const AuditContext& ctx);

    // Check whether BTF is available on this system.
    static bool btf_available();

    // Check whether libbpf is linked into this build.
    static bool libbpf_linked();

    // Get the last error/reason string.
    const std::string& last_reason() const { return reason_; }

  private:
    std::string reason_;
};

} // namespace xsprof::bpf
