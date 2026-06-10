const std = @import("std");

pub const PlanRequest = struct {
    dry_run: bool,
    lab_gate: bool,
    target_allowlisted: bool,
    rollback_snapshot_id: []const u8,
    audit_id: []const u8,
    operator_confirmed: bool,
};

pub const DryRunPlan = struct {
    audit_id: []const u8,
    rollback_snapshot_id: []const u8,
    summary: []const u8,
};

pub fn buildDryRunPlan(request: PlanRequest) !DryRunPlan {
    if (!request.dry_run) return error.DryRunRequired;
    if (!request.lab_gate) return error.LabGateRequired;
    if (!request.target_allowlisted) return error.TargetAllowlistRequired;
    if (request.rollback_snapshot_id.len == 0) return error.RollbackSnapshotRequired;
    if (request.audit_id.len == 0) return error.AuditIdRequired;
    if (!request.operator_confirmed) return error.OperatorConfirmationRequired;
    return .{
        .audit_id = request.audit_id,
        .rollback_snapshot_id = request.rollback_snapshot_id,
        .summary = "dry-run only: no cgroup, affinity, scheduler, or BPF mutation will be performed",
    };
}

test "accepted controller plan remains explicitly dry-run" {
    const plan = try buildDryRunPlan(.{
        .dry_run = true,
        .lab_gate = true,
        .target_allowlisted = true,
        .rollback_snapshot_id = "rollback-001",
        .audit_id = "audit-001",
        .operator_confirmed = true,
    });
    try std.testing.expectEqualStrings("audit-001", plan.audit_id);
    try std.testing.expect(std.mem.indexOf(u8, plan.summary, "dry-run only") != null);
}
