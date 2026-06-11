const std = @import("std");

pub const controller = @import("controller/root.zig");
pub const sched_ext = @import("sched_ext/root.zig");
pub const observability = @import("observability/root.zig");
pub const lab = @import("lab/root.zig");
pub const config = @import("config/root.zig");
pub const audit = @import("audit/root.zig");

pub const PreflightReport = observability.PreflightReport;
pub const OutputFormat = enum { text, json };

pub fn collectPreflight(allocator: std.mem.Allocator) !PreflightReport {
    return observability.collectPreflight(allocator);
}

pub fn collectPreflightFromRoot(allocator: std.mem.Allocator, root_path: []const u8) !PreflightReport {
    return observability.collectPreflightFromRoot(allocator, root_path);
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
    const safe_config = config.RootConfig{
        .scheduler_name = "scx_safe",
        .mutation_profile = true,
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
    };
    try std.testing.expectError(error.DryRunRequired, controller.buildScopedDryRunPlan(.{
        .config = safe_config,
        .dry_run = false,
        .target_cgroup = "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-test",
    }));
    try std.testing.expectError(error.TargetAllowlistRequired, controller.buildScopedDryRunPlan(.{
        .config = safe_config,
        .dry_run = true,
        .target_cgroup = "/sys/fs/cgroup",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-test",
    }));
    try std.testing.expectError(error.RollbackSnapshotRequired, controller.buildScopedDryRunPlan(.{
        .config = safe_config,
        .dry_run = true,
        .target_cgroup = "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "",
    }));
}

test "root module pulls imported module tests" {
    std.testing.refAllDecls(controller);
    std.testing.refAllDecls(sched_ext);
    std.testing.refAllDecls(sched_ext.loader);
    std.testing.refAllDecls(observability);
    std.testing.refAllDecls(lab);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(audit);
}
