const std = @import("std");
const audit = @import("../audit/root.zig");
const config_mod = @import("../config/root.zig");

const lab_cgroup_prefix = "/sys/fs/cgroup/zig-scheduler-lab.slice/";

pub const ScopedPlanRequest = struct {
    config: config_mod.RootConfig,
    dry_run: bool,
    target_cgroup: []const u8,
    audit_id: []const u8,
    rollback_id: []const u8,
};

pub const PlannedOperation = struct {
    operation: []const u8,
    path: []const u8,
    would_write: bool,
};

pub const ScopedDryRunPlan = struct {
    scheduler_name: []const u8,
    target_cgroup: []const u8,
    audit_id: []const u8,
    rollback_id: []const u8,
    would_write: bool,
    operations: [3]PlannedOperation,
};

pub fn buildScopedDryRunPlan(request: ScopedPlanRequest) !ScopedDryRunPlan {
    if (!request.dry_run) return error.DryRunRequired;
    if (request.audit_id.len == 0) return error.AuditIdRequired;
    if (!audit.validateAuditId(request.audit_id)) return error.InvalidAuditId;
    if (request.rollback_id.len == 0) return error.RollbackSnapshotRequired;
    if (!isAllowedLabTarget(request.target_cgroup)) return error.TargetAllowlistRequired;
    if (request.config.mutation_profile and request.config.audit_id == null) return error.AuditIdRequired;
    if (request.config.audit_id) |config_audit| {
        if (!std.mem.eql(u8, config_audit, request.audit_id)) return error.InvalidAuditId;
    }

    return .{
        .scheduler_name = request.config.scheduler_name,
        .target_cgroup = request.target_cgroup,
        .audit_id = request.audit_id,
        .rollback_id = request.rollback_id,
        .would_write = false,
        .operations = .{
            .{ .operation = "validate-cgroup-scope", .path = request.target_cgroup, .would_write = false },
            .{ .operation = "prepare-rollback", .path = request.target_cgroup, .would_write = false },
            .{ .operation = "render-dry-run-plan", .path = request.target_cgroup, .would_write = false },
        },
    };
}

pub fn writeScopedDryRunPlanJson(writer: anytype, plan: ScopedDryRunPlan) !void {
    try writer.writeAll("{\"schema\":\"zig-scheduler/controller-dry-run/v1\"");
    try writer.writeAll(",\"scheduler_name\":");
    try writeJsonString(writer, plan.scheduler_name);
    try writer.writeAll(",\"target_cgroup\":");
    try writeJsonString(writer, plan.target_cgroup);
    try writer.writeAll(",\"audit_id\":");
    try writeJsonString(writer, plan.audit_id);
    try writer.writeAll(",\"rollback_id\":");
    try writeJsonString(writer, plan.rollback_id);
    try writer.print(",\"would_write\":{}", .{plan.would_write});
    try writer.writeAll(",\"operations\":[");
    for (plan.operations, 0..) |operation, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"operation\":");
        try writeJsonString(writer, operation.operation);
        try writer.writeAll(",\"path\":");
        try writeJsonString(writer, operation.path);
        try writer.print(",\"would_write\":{}", .{operation.would_write});
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

pub fn isAllowedLabTarget(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, lab_cgroup_prefix)) return false;
    const relative = path[lab_cgroup_prefix.len..];
    if (relative.len == 0) return false;
    return hasSafePathComponents(relative);
}

fn hasSafePathComponents(relative: []const u8) bool {
    var component_start: usize = 0;
    var index: usize = 0;
    while (index <= relative.len) : (index += 1) {
        if (index == relative.len or relative[index] == '/') {
            const component = relative[component_start..index];
            if (component.len == 0) return false;
            if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
            component_start = index + 1;
        } else if (!isSafePathByte(relative[index])) return false;
    }
    return true;
}

fn isSafePathByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => {
            if (byte < 0x20) {
                try writer.print("\\u{x:0>4}", .{byte});
            } else {
                try writer.writeByte(byte);
            }
        },
    };
    try writer.writeByte('"');
}

test "scoped controller dry-run rejects unsafe cgroup and missing ids" {
    const base = ScopedPlanRequest{
        .config = .{
            .scheduler_name = "scx_safe",
            .mutation_profile = true,
            .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        },
        .dry_run = true,
        .target_cgroup = "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-test",
    };

    try std.testing.expectError(error.TargetAllowlistRequired, buildScopedDryRunPlan(.{
        .config = base.config,
        .dry_run = base.dry_run,
        .target_cgroup = "/sys/fs/cgroup",
        .audit_id = base.audit_id,
        .rollback_id = base.rollback_id,
    }));
    try std.testing.expectError(error.TargetAllowlistRequired, buildScopedDryRunPlan(.{
        .config = base.config,
        .dry_run = base.dry_run,
        .target_cgroup = "/sys/fs/cgroup/zig-scheduler-lab.slice/../escape.scope",
        .audit_id = base.audit_id,
        .rollback_id = base.rollback_id,
    }));
    try std.testing.expectError(error.RollbackSnapshotRequired, buildScopedDryRunPlan(.{
        .config = base.config,
        .dry_run = base.dry_run,
        .target_cgroup = base.target_cgroup,
        .audit_id = base.audit_id,
        .rollback_id = "",
    }));
    try std.testing.expectError(error.AuditIdRequired, buildScopedDryRunPlan(.{
        .config = base.config,
        .dry_run = base.dry_run,
        .target_cgroup = base.target_cgroup,
        .audit_id = "",
        .rollback_id = base.rollback_id,
    }));
}

test "scoped controller dry-run JSON lists non-mutating operations" {
    const plan = try buildScopedDryRunPlan(.{
        .config = .{
            .scheduler_name = "scx_safe",
            .mutation_profile = true,
            .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        },
        .dry_run = true,
        .target_cgroup = "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-test",
    });

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeScopedDryRunPlanJson(&writer, plan);
    const rendered = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"would_write\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"target_cgroup\":\"/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"operation\":\"validate-cgroup-scope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"operation\":\"prepare-rollback\"") != null);
}
