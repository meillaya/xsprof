pub const Error = error{
    BackendGateClosed,
    LabEnvironmentRequired,
    MissingSchedulerClassExt,
    MissingBpfSupport,
    MissingBtfSupport,
    PartialSwitchRequired,
    FallbackDrillRequired,
    VerifierFailurePlanRequired,
    DispatchQueuePlanRequired,
    KernelTupleRequired,
};

pub const BackendPreflight = struct {
    gate_open: bool = false,
    approved_lab_environment: bool = false,
    config_sched_class_ext: bool = false,
    bpf_available: bool = false,
    btf_available: bool = false,
    partial_switch: bool = false,
    fallback_drill_recorded: bool = false,
    verifier_failure_plan: bool = false,
    dispatch_queue_plan: bool = false,
    kernel_tuple: []const u8 = "unverified",
};

pub const BackendReadiness = struct {
    mode_label: []const u8,
    kernel_tuple: []const u8,
    switch_mode: []const u8,
    dispatch_queue_boundary: []const u8,
    fallback_boundary: []const u8,
};

pub fn validateBackendPreflight(preflight: BackendPreflight) Error!BackendReadiness {
    if (!preflight.gate_open) return Error.BackendGateClosed;
    if (!preflight.approved_lab_environment) return Error.LabEnvironmentRequired;
    if (!preflight.config_sched_class_ext) return Error.MissingSchedulerClassExt;
    if (!preflight.bpf_available) return Error.MissingBpfSupport;
    if (!preflight.btf_available) return Error.MissingBtfSupport;
    if (!preflight.partial_switch) return Error.PartialSwitchRequired;
    if (!preflight.fallback_drill_recorded) return Error.FallbackDrillRequired;
    if (!preflight.verifier_failure_plan) return Error.VerifierFailurePlanRequired;
    if (!preflight.dispatch_queue_plan) return Error.DispatchQueuePlanRequired;
    if (preflight.kernel_tuple.len == 0 or @import("std").mem.eql(u8, preflight.kernel_tuple, "unverified")) return Error.KernelTupleRequired;
    return .{
        .mode_label = "sched-ext-hazardous-backend-readiness",
        .kernel_tuple = preflight.kernel_tuple,
        .switch_mode = "partial-switch-only-until-promoted",
        .dispatch_queue_boundary = "DSQ mapping must be explicit before any BPF scheduler load",
        .fallback_boundary = "fallback/disable drill must pass in disposable VM/lab before load",
    };
}
