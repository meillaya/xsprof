const std = @import("std");
const format = @import("journal_format.zig");
const protocol = @import("protocol.zig");

pub const JournalError = error{ DuplicateActionId, DuplicateTargetId, InvalidActionId, InvalidJournal, OutOfMemory } || std.Io.Writer.Error;

pub const LoadResult = struct {
    count: usize,
    next_seq: usize,
};

pub const LabStatus = enum { active, rolled_back };

pub const LabRun = struct {
    action_id: []u8,
    target_id: []u8,
    rollback_id: []u8,
    artifact: []u8,
    status: LabStatus,
};

pub const Tracker = struct {
    seen: std.ArrayList([]u8) = .empty,
    labs: std.ArrayList(LabRun) = .empty,

    pub fn deinit(self: *Tracker, allocator: std.mem.Allocator) void {
        for (self.seen.items) |item| allocator.free(item);
        self.seen.deinit(allocator);
        for (self.labs.items) |item| {
            allocator.free(item.action_id);
            allocator.free(item.target_id);
            allocator.free(item.rollback_id);
            allocator.free(item.artifact);
        }
        self.labs.deinit(allocator);
    }

    pub fn remember(self: *Tracker, allocator: std.mem.Allocator, action_id: []const u8) JournalError!void {
        if (action_id.len == 0) return;
        try validateActionId(action_id);
        for (self.seen.items) |existing| {
            if (std.mem.eql(u8, existing, action_id)) return error.DuplicateActionId;
        }
        try self.seen.append(allocator, try allocator.dupe(u8, action_id));
    }

    pub fn loadExisting(self: *Tracker, allocator: std.mem.Allocator, raw: []const u8) JournalError!LoadResult {
        var count: usize = 0;
        var expected_seq: usize = 1;
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            count += 1;
            var parsed = std.json.parseFromSlice(RawEvent, allocator, trimmed, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch return error.InvalidJournal;
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.schema, protocol.event_schema) or parsed.value.host_mutation) return error.InvalidJournal;
            if (parsed.value.seq != expected_seq) return error.InvalidJournal;
            expected_seq += 1;
            if (std.mem.eql(u8, parsed.value.event orelse "", "journal_record")) {
                if (!std.mem.eql(u8, parsed.value.status orelse "", "accepted")) return error.InvalidJournal;
                if (parsed.value.action_id) |action_id| try self.remember(allocator, action_id);
            } else if (std.mem.eql(u8, parsed.value.event orelse "", "lab_run_active")) {
                try self.recordLab(allocator, parsed.value.action_id orelse "", parsed.value.target_id orelse "", parsed.value.rollback_id orelse "", parsed.value.artifact orelse "");
            } else if (shouldClearActiveState(parsed.value.event orelse "", parsed.value.status orelse "", parsed.value.state orelse "")) {
                const target_action_id = parsed.value.target_action_id orelse "";
                const active_action_id = if (target_action_id.len != 0) target_action_id else parsed.value.action_id orelse "";
                try self.markRolledBack(allocator, active_action_id, parsed.value.artifact orelse "");
            }
        }
        return .{ .count = count, .next_seq = expected_seq };
    }

    pub fn recordLab(self: *Tracker, allocator: std.mem.Allocator, action_id: []const u8, target_id: []const u8, rollback_id: []const u8, artifact: []const u8) JournalError!void {
        try validateActionId(action_id);
        try validateActionId(target_id);
        for (self.labs.items) |lab| {
            if (std.mem.eql(u8, lab.action_id, action_id)) return;
            if (lab.status == .active and std.mem.eql(u8, lab.target_id, target_id)) return error.DuplicateTargetId;
        }
        try self.labs.append(allocator, .{
            .action_id = try allocator.dupe(u8, action_id),
            .target_id = try allocator.dupe(u8, target_id),
            .rollback_id = try allocator.dupe(u8, rollback_id),
            .artifact = try allocator.dupe(u8, artifact),
            .status = .active,
        });
    }

    pub fn findLab(self: *const Tracker, target_action_id: []const u8) ?*LabRun {
        for (self.labs.items) |*lab| {
            if (std.mem.eql(u8, lab.action_id, target_action_id)) return lab;
        }
        return null;
    }

    pub fn activeTarget(self: *const Tracker, target_id: []const u8) bool {
        if (target_id.len == 0) return false;
        for (self.labs.items) |lab| {
            if (lab.status == .active and std.mem.eql(u8, lab.target_id, target_id)) return true;
        }
        return false;
    }

    pub fn markRolledBack(self: *Tracker, allocator: std.mem.Allocator, target_action_id: []const u8, artifact: []const u8) JournalError!void {
        const lab = self.findLab(target_action_id) orelse return error.InvalidActionId;
        lab.status = .rolled_back;
        if (artifact.len != 0) {
            const replacement = try allocator.dupe(u8, artifact);
            allocator.free(lab.artifact);
            lab.artifact = replacement;
        }
    }
};

const RawEvent = struct {
    schema: []const u8,
    seq: usize,
    event: ?[]const u8 = null,
    status: ?[]const u8 = null,
    state: ?[]const u8 = null,
    action: ?[]const u8 = null,
    action_id: ?[]const u8 = null,
    target_action_id: ?[]const u8 = null,
    target_id: ?[]const u8 = null,
    rollback_id: ?[]const u8 = null,
    artifact: ?[]const u8 = null,
    host_mutation: bool,
};

pub fn validateActionId(action_id: []const u8) JournalError!void {
    if (action_id.len == 0 or action_id.len > 96) return error.InvalidActionId;
    for (action_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidActionId;
    }
}

pub fn writeRecord(writer: anytype, seq: usize, action: protocol.OperatorAction, git_sha: []const u8) !void {
    try writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"journal_record\",\"action\":\"{s}\",\"action_id\":",
        .{ protocol.event_schema, seq, @tagName(action.kind) },
    );
    try format.writeJsonString(writer, action.action_id);
    try writer.writeAll(",\"audit_id\":");
    try format.writeJsonString(writer, action.audit_id);
    try writer.writeAll(",\"target_id\":");
    try format.writeJsonString(writer, action.target_id);
    try writer.writeAll(",\"rollback_id\":");
    try format.writeJsonString(writer, action.rollback_id);
    try writer.writeAll(",\"target_action_id\":");
    try format.writeJsonString(writer, action.target_action_id);
    try writer.writeAll(",\"git_sha\":");
    try format.writeJsonString(writer, git_sha);
    try writer.writeAll(",\"state\":\"read_only\",\"status\":\"accepted\",\"command_argv_hash\":\"none\",\"artifact_paths\":[],\"cleanup\":\"pending\",\"host_mutation\":false}\n");
}

pub fn writeLabActive(writer: anytype, seq: usize, action: protocol.OperatorAction, artifact: []const u8) !void {
    try writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"lab_run_active\",\"action\":\"{s}\",\"action_id\":",
        .{ protocol.event_schema, seq, @tagName(action.kind) },
    );
    try format.writeJsonString(writer, action.action_id);
    try writer.writeAll(",\"target_id\":");
    try format.writeJsonString(writer, action.target_id);
    try writer.writeAll(",\"audit_id\":");
    try format.writeJsonString(writer, action.audit_id);
    try writer.writeAll(",\"rollback_id\":");
    try format.writeJsonString(writer, action.rollback_id);
    try writer.writeAll(",\"artifact\":");
    try format.writeJsonString(writer, artifact);
    try writer.writeAll(",\"state\":\"partial_switch_lab\",\"status\":\"active\",\"host_mutation\":false}\n");
}

pub fn writeRollbackCompleted(writer: anytype, seq: usize, action: protocol.OperatorAction, artifact: []const u8, idempotent: bool) !void {
    try writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"rollback_completed\",\"action\":\"{s}\",\"action_id\":",
        .{ protocol.event_schema, seq, @tagName(action.kind) },
    );
    try format.writeJsonString(writer, action.action_id);
    try writer.writeAll(",\"target_id\":");
    try format.writeJsonString(writer, action.target_id);
    try writer.writeAll(",\"target_action_id\":");
    try format.writeJsonString(writer, action.target_action_id);
    try writer.writeAll(",\"rollback_id\":");
    try format.writeJsonString(writer, action.rollback_id);
    try writer.writeAll(",\"artifact\":");
    try format.writeJsonString(writer, artifact);
    try writer.print(",\"state\":\"rolled_back\",\"status\":\"{s}\",\"host_mutation\":false}}\n", .{if (idempotent) "already_rolled_back" else "PASS"});
}

pub fn writeCleanupCompleted(writer: anytype, seq: usize, action: protocol.OperatorAction, artifact: []const u8, idempotent: bool) !void {
    try writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"cleanup\",\"action\":\"{s}\",\"action_id\":",
        .{ protocol.event_schema, seq, @tagName(action.kind) },
    );
    try format.writeJsonString(writer, action.action_id);
    try writer.writeAll(",\"target_id\":");
    try format.writeJsonString(writer, action.target_id);
    try writer.writeAll(",\"target_action_id\":");
    try format.writeJsonString(writer, action.target_action_id);
    try writer.writeAll(",\"rollback_id\":");
    try format.writeJsonString(writer, action.rollback_id);
    try writer.writeAll(",\"artifact\":");
    try format.writeJsonString(writer, artifact);
    try writer.print(",\"state\":\"clean\",\"status\":\"{s}\",\"reason\":\"stop_cleanup_requested\",\"host_mutation\":false}}\n", .{if (idempotent) "already_clean" else "PASS"});
}

pub fn writeTargetRefusal(writer: anytype, seq: usize, action: protocol.OperatorAction, reason: []const u8) !void {
    try writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"refusal\",\"action\":\"{s}\",\"action_id\":",
        .{ protocol.event_schema, seq, @tagName(action.kind) },
    );
    try format.writeJsonString(writer, action.action_id);
    try writer.writeAll(",\"target_id\":");
    try format.writeJsonString(writer, action.target_id);
    try writer.writeAll(",\"target_action_id\":");
    try format.writeJsonString(writer, action.target_action_id);
    try writer.writeAll(",\"audit_id\":");
    try format.writeJsonString(writer, action.audit_id);
    try writer.writeAll(",\"rollback_id\":");
    try format.writeJsonString(writer, action.rollback_id);
    try writer.writeAll(",\"state\":\"refused_host\",\"status\":\"REFUSE\",\"reason\":");
    try format.writeJsonString(writer, reason);
    try writer.writeAll(",\"host_mutation\":false}\n");
}

pub fn writeDuplicateRefusal(writer: anytype, seq: usize, action: protocol.OperatorAction) !void {
    try writeActionIdRefusal(writer, seq, action, "duplicate_action_id");
}

pub fn writeDuplicateTargetRefusal(writer: anytype, seq: usize, action: protocol.OperatorAction) !void {
    try writeTargetRefusal(writer, seq, action, "duplicate_target_id");
}

pub fn writeInvalidActionIdRefusal(writer: anytype, seq: usize, action: protocol.OperatorAction) !void {
    try writeActionIdRefusal(writer, seq, action, "invalid_action_id");
}

fn writeActionIdRefusal(writer: anytype, seq: usize, action: protocol.OperatorAction, reason: []const u8) !void {
    try writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"refusal\",\"action\":\"{s}\",\"action_id\":",
        .{ protocol.event_schema, seq, @tagName(action.kind) },
    );
    try format.writeJsonString(writer, action.action_id);
    try writer.writeAll(",\"target_id\":");
    try format.writeJsonString(writer, action.target_id);
    try writer.writeAll(",\"state\":\"refused_host\",\"status\":\"refused\",\"reason\":");
    try format.writeJsonString(writer, reason);
    try writer.writeAll(",\"host_mutation\":false}\n");
}

fn shouldClearActiveState(event: []const u8, status: []const u8, state: []const u8) bool {
    if (std.mem.eql(u8, event, "rollback_completed") or std.mem.eql(u8, event, "rollback")) {
        return successfulRollbackStatus(status) and std.mem.eql(u8, state, "rolled_back");
    }
    if (std.mem.eql(u8, event, "cleanup")) {
        return successfulCleanupStatus(status) and std.mem.eql(u8, state, "clean");
    }
    return false;
}

fn successfulRollbackStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "PASS") or std.mem.eql(u8, status, "already_rolled_back");
}

fn successfulCleanupStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "PASS") or std.mem.eql(u8, status, "already_clean");
}

test "daemon journal behavior tests are linked" {
    std.testing.refAllDecls(@import("journal_tests.zig"));
}
