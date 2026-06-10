const std = @import("std");
const sim = @import("../root.zig");

test "sched_ext hazardous backend fails closed until prerequisites and fallback evidence exist" {
    try std.testing.expectError(sim.sched_ext.Error.BackendGateClosed, sim.sched_ext.validateBackendPreflight(.{}));
    try std.testing.expectError(sim.sched_ext.Error.LabEnvironmentRequired, sim.sched_ext.validateBackendPreflight(.{ .gate_open = true }));
    try std.testing.expectError(sim.sched_ext.Error.MissingSchedulerClassExt, sim.sched_ext.validateBackendPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
    }));
    try std.testing.expectError(sim.sched_ext.Error.MissingBpfSupport, sim.sched_ext.validateBackendPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .config_sched_class_ext = true,
    }));
    try std.testing.expectError(sim.sched_ext.Error.MissingBtfSupport, sim.sched_ext.validateBackendPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .config_sched_class_ext = true,
        .bpf_available = true,
    }));
    try std.testing.expectError(sim.sched_ext.Error.PartialSwitchRequired, sim.sched_ext.validateBackendPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .config_sched_class_ext = true,
        .bpf_available = true,
        .btf_available = true,
    }));
    try std.testing.expectError(sim.sched_ext.Error.FallbackDrillRequired, sim.sched_ext.validateBackendPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .config_sched_class_ext = true,
        .bpf_available = true,
        .btf_available = true,
        .partial_switch = true,
    }));
    try std.testing.expectError(sim.sched_ext.Error.VerifierFailurePlanRequired, sim.sched_ext.validateBackendPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .config_sched_class_ext = true,
        .bpf_available = true,
        .btf_available = true,
        .partial_switch = true,
        .fallback_drill_recorded = true,
    }));
    try std.testing.expectError(sim.sched_ext.Error.DispatchQueuePlanRequired, sim.sched_ext.validateBackendPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .config_sched_class_ext = true,
        .bpf_available = true,
        .btf_available = true,
        .partial_switch = true,
        .fallback_drill_recorded = true,
        .verifier_failure_plan = true,
    }));
    try std.testing.expectError(sim.sched_ext.Error.KernelTupleRequired, sim.sched_ext.validateBackendPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .config_sched_class_ext = true,
        .bpf_available = true,
        .btf_available = true,
        .partial_switch = true,
        .fallback_drill_recorded = true,
        .verifier_failure_plan = true,
        .dispatch_queue_plan = true,
    }));
    try std.testing.expectError(sim.sched_ext.Error.KernelTupleRequired, sim.sched_ext.validateBackendPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .config_sched_class_ext = true,
        .bpf_available = true,
        .btf_available = true,
        .partial_switch = true,
        .fallback_drill_recorded = true,
        .verifier_failure_plan = true,
        .dispatch_queue_plan = true,
        .kernel_tuple = "",
    }));
}

test "sched_ext hazardous backend readiness is VM only and partial switch first" {
    const readiness = try sim.sched_ext.validateBackendPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .config_sched_class_ext = true,
        .bpf_available = true,
        .btf_available = true,
        .partial_switch = true,
        .fallback_drill_recorded = true,
        .verifier_failure_plan = true,
        .dispatch_queue_plan = true,
        .kernel_tuple = "linux-lab/sched_ext/btf",
    });
    try std.testing.expectEqualStrings("sched-ext-hazardous-backend-readiness", readiness.mode_label);
    try std.testing.expectEqualStrings("partial-switch-only-until-promoted", readiness.switch_mode);
    try std.testing.expect(std.mem.indexOf(u8, readiness.dispatch_queue_boundary, "DSQ mapping") != null);
    try std.testing.expect(std.mem.indexOf(u8, readiness.fallback_boundary, "disposable VM/lab") != null);
}
