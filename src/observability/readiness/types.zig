const sched_ext = @import("../../sched_ext/root.zig");

pub const FactStatus = sched_ext.FactStatus;

pub const KernelReadiness = struct {
    status: FactStatus,
    minimum_release: []const u8,
};

pub const KernelConfigFacts = struct {
    status: FactStatus,
    source: []const u8,
    sched_class_ext: FactStatus,
    bpf: FactStatus,
    bpf_syscall: FactStatus,
    bpf_jit: FactStatus,
    bpf_jit_always_on: FactStatus,
    bpf_jit_default_on: FactStatus,
    debug_info_btf: FactStatus,
};

pub const BpfJitSysctlFacts = struct {
    enable: sched_ext.TextFact,
    harden: sched_ext.TextFact,
    kallsyms: sched_ext.TextFact,
};

pub const ToolchainFacts = struct {
    bpftool: sched_ext.TextFact,
    clang: sched_ext.TextFact,
    llvm: sched_ext.TextFact,
    libbpf_pkg_config: sched_ext.TextFact,
};

pub const PrivilegeFacts = struct {
    status: FactStatus,
    cap_bpf: bool,
    cap_sys_admin: bool,
    cap_perfmon: bool,
};

pub const ReadinessFacts = struct {
    kernel: KernelReadiness,
    kernel_config: KernelConfigFacts,
    bpf_jit_sysctls: BpfJitSysctlFacts,
    toolchain: ToolchainFacts,
    privileges: PrivilegeFacts,
};
