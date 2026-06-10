const std = @import("std");
const sim = @import("../root.zig");

test "user-space controller dry-run plan fails closed until all safety gates pass" {
    const base = sim.controller.ControlIntent{
        .kind = .cgroup_cpu_weight,
        .target_id = "lab.slice/workload-a",
        .requested_value = "200",
    };

    try std.testing.expectError(sim.controller.Error.LabGateRequired, sim.controller.buildDryRunPlan(base));
    try std.testing.expectError(sim.controller.Error.TargetNotAllowed, sim.controller.buildDryRunPlan(.{
        .kind = base.kind,
        .target_id = base.target_id,
        .requested_value = base.requested_value,
        .lab_gate_ready = true,
    }));
    try std.testing.expectError(sim.controller.Error.RollbackSnapshotRequired, sim.controller.buildDryRunPlan(.{
        .kind = base.kind,
        .target_id = base.target_id,
        .requested_value = base.requested_value,
        .lab_gate_ready = true,
        .target_allowed = true,
    }));
    try std.testing.expectError(sim.controller.Error.TuiConfirmationRequired, sim.controller.buildDryRunPlan(.{
        .kind = base.kind,
        .target_id = base.target_id,
        .requested_value = base.requested_value,
        .lab_gate_ready = true,
        .target_allowed = true,
        .rollback_snapshot_id = "rollback-001",
    }));
    try std.testing.expectError(sim.controller.Error.PermissionDenied, sim.controller.buildDryRunPlan(.{
        .kind = base.kind,
        .target_id = base.target_id,
        .requested_value = base.requested_value,
        .lab_gate_ready = true,
        .target_allowed = true,
        .rollback_snapshot_id = "rollback-001",
        .tui_confirmed = true,
    }));
    try std.testing.expectError(sim.controller.Error.DryRunRequired, sim.controller.buildDryRunPlan(.{
        .kind = base.kind,
        .target_id = base.target_id,
        .requested_value = base.requested_value,
        .lab_gate_ready = true,
        .dry_run = false,
        .target_allowed = true,
        .rollback_snapshot_id = "rollback-001",
        .tui_confirmed = true,
        .permission_ok = true,
    }));
    try std.testing.expectError(sim.controller.Error.AuditIdRequired, sim.controller.buildDryRunPlan(.{
        .kind = base.kind,
        .target_id = base.target_id,
        .requested_value = base.requested_value,
        .lab_gate_ready = true,
        .dry_run = true,
        .target_allowed = true,
        .rollback_snapshot_id = "rollback-001",
        .tui_confirmed = true,
        .permission_ok = true,
    }));
    try std.testing.expectError(sim.controller.Error.MutationOutOfBounds, sim.controller.buildDryRunPlan(.{
        .kind = base.kind,
        .target_id = base.target_id,
        .requested_value = base.requested_value,
        .lab_gate_ready = true,
        .dry_run = true,
        .target_allowed = true,
        .rollback_snapshot_id = "rollback-001",
        .tui_confirmed = true,
        .permission_ok = true,
        .audit_id = "controller-audit-001",
        .bounded_scope = false,
    }));
}

test "user-space controller produces dry-run-only audited plans" {
    const plan = try sim.controller.buildDryRunPlan(.{
        .kind = .cpuset_cpus,
        .target_id = "lab.slice/workload-b",
        .requested_value = "0-1",
        .lab_gate_ready = true,
        .dry_run = true,
        .target_allowed = true,
        .rollback_snapshot_id = "rollback-002",
        .tui_confirmed = true,
        .permission_ok = true,
        .audit_id = "controller-audit-002",
        .bounded_scope = true,
    });

    try std.testing.expectEqual(sim.controller.ControlKind.cpuset_cpus, plan.kind);
    try std.testing.expectEqualStrings("dry-run-only", plan.execution_mode);
    try std.testing.expectEqualStrings("rollback-002", plan.rollback_snapshot_id);
    try std.testing.expectEqualStrings("controller-audit-002", plan.audit_id);
    try std.testing.expect(std.mem.indexOf(u8, plan.safety_summary, "allowlist") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.safety_summary, "rollback snapshot") != null);
    try std.testing.expectEqualStrings("cpuset.cpus", sim.controller.controlKindLabel(.cpuset_cpus));
}
