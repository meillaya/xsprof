const std = @import("std");

pub const controller = @import("controller/root.zig");
pub const sched_ext = @import("sched_ext/root.zig");
pub const observability = @import("observability/root.zig");

pub const PreflightReport = observability.PreflightReport;
pub const OutputFormat = enum { text, json };

pub fn collectPreflight(allocator: std.mem.Allocator) !PreflightReport {
    return observability.collectPreflight(allocator);
}

pub fn writePreflightJson(writer: anytype, report: PreflightReport) !void {
    try observability.writeJson(writer, report);
}

pub fn writePreflightText(writer: anytype, report: PreflightReport) !void {
    try writer.print(
        "Linux scheduler preflight (read-only)\n" ++
            "kernel: {s} arch={s}\n" ++
            "sched_ext: state={s} enable_seq={s} switch_all={s} nr_rejected={s}\n" ++
            "cgroup v2: {s} controllers={s}\n" ++
            "btf: {s}\n" ++
            "capabilities: effective={s}\n" ++
            "safety: {s}\n",
        .{
            report.kernel_release,
            report.arch,
            @tagName(report.sched_ext.state.status),
            @tagName(report.sched_ext.enable_seq.status),
            @tagName(report.sched_ext.switch_all.status),
            @tagName(report.sched_ext.nr_rejected.status),
            @tagName(report.cgroup_v2.status),
            report.cgroup_v2.controllers,
            @tagName(report.btf.status),
            report.capabilities.effective_hex,
            report.safety_summary,
        },
    );
}

pub fn isUnsafeCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "load") or
        std.mem.eql(u8, command, "attach") or
        std.mem.eql(u8, command, "enable") or
        std.mem.eql(u8, command, "mutate") or
        std.mem.eql(u8, command, "apply");
}

pub fn writeHelp(writer: anytype, exe_name: []const u8) !void {
    try writer.print(
        "usage: {s} [help | preflight --json | sched-ext preflight --json | controller plan --dry-run]\n\n" ++
            "zig-scheduler is now a fail-closed Linux scheduler operator surface.\n" ++
            "Initial commands are read-only or dry-run only; no BPF load, cgroup write, affinity write, or scheduler mutation is implemented.\n" ++
            "The simulator is archived separately under simulator/ and runs from that package root.\n",
        .{exe_name},
    );
}

test "unsafe root commands are refused by name" {
    try std.testing.expect(isUnsafeCommand("load"));
    try std.testing.expect(isUnsafeCommand("attach"));
    try std.testing.expect(isUnsafeCommand("enable"));
    try std.testing.expect(isUnsafeCommand("mutate"));
    try std.testing.expect(isUnsafeCommand("apply"));
    try std.testing.expect(!isUnsafeCommand("preflight"));
}

test "dry-run controller plan fails closed without gates" {
    try std.testing.expectError(error.LabGateRequired, controller.buildDryRunPlan(.{
        .dry_run = true,
        .lab_gate = false,
        .target_allowlisted = true,
        .rollback_snapshot_id = "rollback-001",
        .audit_id = "audit-001",
        .operator_confirmed = true,
    }));
    try std.testing.expectError(error.DryRunRequired, controller.buildDryRunPlan(.{
        .dry_run = false,
        .lab_gate = true,
        .target_allowlisted = true,
        .rollback_snapshot_id = "rollback-001",
        .audit_id = "audit-001",
        .operator_confirmed = true,
    }));
}
