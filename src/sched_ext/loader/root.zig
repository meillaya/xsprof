const std = @import("std");
const audit = @import("../../audit/root.zig");
const controller = @import("../../controller/root.zig");

pub const vm_marker_path = "/run/zig-scheduler-vm-lab.marker";

pub const AttachRequest = struct {
    lab: bool,
    partial: bool,
    target_cgroup: []const u8,
    audit_id: []const u8,
    rollback_id: []const u8,
};

pub const AttachPlan = struct {
    target_cgroup: []const u8,
    audit_id: []const u8,
    rollback_id: []const u8,
    mode: []const u8 = "partial_switch_lab",
};

pub const ScopeSnapshot = struct {
    target_cgroup: []const u8,
    parent_cgroup: []const u8,
    membership_digest: []const u8,
    rollback_id: []const u8,
};

pub const ScopeFreshnessError = error{
    TargetDisappeared,
    ParentScopeChanged,
    ProcessMembershipChanged,
    StaleRollbackId,
    TargetAllowlistRequired,
};

pub fn validateFreshScope(before: ScopeSnapshot, current: ScopeSnapshot) ScopeFreshnessError!void {
    if (!controller.isAllowedLabTarget(current.target_cgroup)) return error.TargetAllowlistRequired;
    if (current.target_cgroup.len == 0) return error.TargetDisappeared;
    if (!std.mem.eql(u8, before.target_cgroup, current.target_cgroup)) return error.TargetDisappeared;
    if (!std.mem.eql(u8, before.parent_cgroup, current.parent_cgroup)) return error.ParentScopeChanged;
    if (!std.mem.eql(u8, before.membership_digest, current.membership_digest)) return error.ProcessMembershipChanged;
    if (!std.mem.eql(u8, before.rollback_id, current.rollback_id)) return error.StaleRollbackId;
}

pub fn validateSystemdUnitResolution(unit_name: []const u8, resolved_cgroup: []const u8) ScopeFreshnessError!void {
    if (unit_name.len == 0) return error.TargetAllowlistRequired;
    if (!std.mem.endsWith(u8, unit_name, ".scope") and !std.mem.endsWith(u8, unit_name, ".service")) {
        return error.TargetAllowlistRequired;
    }
    if (!controller.isAllowedLabTarget(resolved_cgroup)) return error.TargetAllowlistRequired;
}

pub const AttachError = error{
    LabFlagRequired,
    PartialFlagRequired,
    TargetAllowlistRequired,
    InvalidAuditId,
    RollbackSnapshotRequired,
};

pub fn buildAttachPlan(request: AttachRequest) AttachError!AttachPlan {
    if (!request.lab) return error.LabFlagRequired;
    if (!request.partial) return error.PartialFlagRequired;
    if (!controller.isAllowedLabTarget(request.target_cgroup)) return error.TargetAllowlistRequired;
    if (!audit.validateAuditId(request.audit_id)) return error.InvalidAuditId;
    if (request.rollback_id.len == 0) return error.RollbackSnapshotRequired;
    return .{
        .target_cgroup = request.target_cgroup,
        .audit_id = request.audit_id,
        .rollback_id = request.rollback_id,
    };
}

pub fn vmMarkerExists() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.openFileAbsolute(io, vm_marker_path, .{}) catch return false;
    file.close(io);
    return true;
}

pub fn writeAttachPlanJson(writer: anytype, plan: AttachPlan) !void {
    try writer.writeAll("{\"schema\":\"zig-scheduler/partial-attach-plan/v1\"");
    try writer.writeAll(",\"mode\":");
    try writeJsonString(writer, plan.mode);
    try writer.writeAll(",\"target_cgroup\":");
    try writeJsonString(writer, plan.target_cgroup);
    try writer.writeAll(",\"audit_id\":");
    try writeJsonString(writer, plan.audit_id);
    try writer.writeAll(",\"rollback_id\":");
    try writeJsonString(writer, plan.rollback_id);
    try writer.writeAll(",\"vm_marker\":");
    try writeJsonString(writer, vm_marker_path);
    try writer.writeAll(",\"would_mutate\":true}");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

test "partial attach plan requires lab partial allowlist audit and rollback" {
    const base = AttachRequest{
        .lab = true,
        .partial = true,
        .target_cgroup = "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-demo",
    };
    const plan = try buildAttachPlan(base);
    try std.testing.expectEqualStrings("partial_switch_lab", plan.mode);
    try std.testing.expectError(error.TargetAllowlistRequired, buildAttachPlan(.{
        .lab = base.lab,
        .partial = base.partial,
        .target_cgroup = "/sys/fs/cgroup",
        .audit_id = base.audit_id,
        .rollback_id = base.rollback_id,
    }));
    try std.testing.expectError(error.LabFlagRequired, buildAttachPlan(.{
        .lab = false,
        .partial = base.partial,
        .target_cgroup = base.target_cgroup,
        .audit_id = base.audit_id,
        .rollback_id = base.rollback_id,
    }));
    try std.testing.expectError(error.PartialFlagRequired, buildAttachPlan(.{
        .lab = base.lab,
        .partial = false,
        .target_cgroup = base.target_cgroup,
        .audit_id = base.audit_id,
        .rollback_id = base.rollback_id,
    }));
    try std.testing.expectError(error.InvalidAuditId, buildAttachPlan(.{
        .lab = base.lab,
        .partial = base.partial,
        .target_cgroup = base.target_cgroup,
        .audit_id = "bad",
        .rollback_id = base.rollback_id,
    }));
    try std.testing.expectError(error.RollbackSnapshotRequired, buildAttachPlan(.{
        .lab = base.lab,
        .partial = base.partial,
        .target_cgroup = base.target_cgroup,
        .audit_id = base.audit_id,
        .rollback_id = "",
    }));
}

test "partial attach plan JSON names VM marker and mutation mode" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeAttachPlanJson(&writer, try buildAttachPlan(.{
        .lab = true,
        .partial = true,
        .target_cgroup = "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-demo",
    }));
    const rendered = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "partial_switch_lab") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, vm_marker_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"would_mutate\":true") != null);
}

test "fresh scope validation rejects stale cgroup races" {
    const before = ScopeSnapshot{
        .target_cgroup = "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        .parent_cgroup = "/sys/fs/cgroup/zig-scheduler-lab.slice",
        .membership_digest = "members-a",
        .rollback_id = "RB-demo",
    };
    try validateFreshScope(before, before);
    try std.testing.expectError(error.TargetDisappeared, validateFreshScope(before, .{
        .target_cgroup = "/sys/fs/cgroup/zig-scheduler-lab.slice/other.scope",
        .parent_cgroup = before.parent_cgroup,
        .membership_digest = before.membership_digest,
        .rollback_id = before.rollback_id,
    }));
    try std.testing.expectError(error.ProcessMembershipChanged, validateFreshScope(before, .{
        .target_cgroup = before.target_cgroup,
        .parent_cgroup = before.parent_cgroup,
        .membership_digest = "members-b",
        .rollback_id = before.rollback_id,
    }));
    try std.testing.expectError(error.ParentScopeChanged, validateFreshScope(before, .{
        .target_cgroup = before.target_cgroup,
        .parent_cgroup = "/sys/fs/cgroup/other.slice",
        .membership_digest = before.membership_digest,
        .rollback_id = before.rollback_id,
    }));
    try std.testing.expectError(error.StaleRollbackId, validateFreshScope(before, .{
        .target_cgroup = before.target_cgroup,
        .parent_cgroup = before.parent_cgroup,
        .membership_digest = before.membership_digest,
        .rollback_id = "RB-stale",
    }));
    try std.testing.expectError(error.TargetAllowlistRequired, validateFreshScope(before, .{
        .target_cgroup = "/sys/fs/cgroup/system.slice/demo.scope",
        .parent_cgroup = before.parent_cgroup,
        .membership_digest = before.membership_digest,
        .rollback_id = before.rollback_id,
    }));
    try validateSystemdUnitResolution("demo.scope", before.target_cgroup);
    try std.testing.expectError(error.TargetAllowlistRequired, validateSystemdUnitResolution("ssh.service", "/sys/fs/cgroup/system.slice/ssh.service"));
    try std.testing.expectError(error.TargetAllowlistRequired, validateSystemdUnitResolution("bad-unit", before.target_cgroup));
}
