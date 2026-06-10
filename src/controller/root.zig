const std = @import("std");

pub const Error = error{
    LabGateRequired,
    DryRunRequired,
    TargetNotAllowed,
    RollbackSnapshotRequired,
    TuiConfirmationRequired,
    PermissionDenied,
    AuditIdRequired,
    MutationOutOfBounds,
};

pub const ControlKind = enum {
    cgroup_cpu_weight,
    cgroup_cpu_max,
    cpuset_cpus,
    sched_affinity,
};

pub const ControlIntent = struct {
    kind: ControlKind,
    target_id: []const u8,
    requested_value: []const u8,
    lab_gate_ready: bool = false,
    dry_run: bool = true,
    target_allowed: bool = false,
    rollback_snapshot_id: []const u8 = "",
    tui_confirmed: bool = false,
    permission_ok: bool = false,
    audit_id: []const u8 = "",
    bounded_scope: bool = false,
};

pub const DryRunPlan = struct {
    kind: ControlKind,
    target_id: []const u8,
    requested_value: []const u8,
    rollback_snapshot_id: []const u8,
    audit_id: []const u8,
    execution_mode: []const u8,
    safety_summary: []const u8,
};

pub fn buildDryRunPlan(intent: ControlIntent) Error!DryRunPlan {
    if (!intent.lab_gate_ready) return Error.LabGateRequired;
    if (!intent.dry_run) return Error.DryRunRequired;
    if (!intent.target_allowed) return Error.TargetNotAllowed;
    if (intent.rollback_snapshot_id.len == 0) return Error.RollbackSnapshotRequired;
    if (!intent.tui_confirmed) return Error.TuiConfirmationRequired;
    if (!intent.permission_ok) return Error.PermissionDenied;
    if (intent.audit_id.len == 0) return Error.AuditIdRequired;
    if (!intent.bounded_scope) return Error.MutationOutOfBounds;
    return .{
        .kind = intent.kind,
        .target_id = intent.target_id,
        .requested_value = intent.requested_value,
        .rollback_snapshot_id = intent.rollback_snapshot_id,
        .audit_id = intent.audit_id,
        .execution_mode = "dry-run-only",
        .safety_summary = "validated lab gate, allowlist, rollback snapshot, TUI confirmation, permission check, bounded scope, and audit id before mutation",
    };
}

pub fn controlKindLabel(kind: ControlKind) []const u8 {
    return switch (kind) {
        .cgroup_cpu_weight => "cgroup-v2 cpu.weight",
        .cgroup_cpu_max => "cgroup-v2 cpu.max",
        .cpuset_cpus => "cpuset.cpus",
        .sched_affinity => "sched_setaffinity plan",
    };
}

test "controller root is dependency-light" {
    _ = std;
}
