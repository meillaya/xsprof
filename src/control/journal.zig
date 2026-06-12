const std = @import("std");
const protocol = @import("protocol.zig");

pub const JournalError = error{ DuplicateActionId, InvalidActionId, InvalidJournal, OutOfMemory } || std.Io.Writer.Error;

pub const LoadResult = struct {
    count: usize,
    next_seq: usize,
};

pub const Tracker = struct {
    seen: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Tracker, allocator: std.mem.Allocator) void {
        for (self.seen.items) |item| allocator.free(item);
        self.seen.deinit(allocator);
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
            }
        }
        return .{ .count = count, .next_seq = expected_seq };
    }
};

const RawEvent = struct {
    schema: []const u8,
    seq: usize,
    event: ?[]const u8 = null,
    status: ?[]const u8 = null,
    action_id: ?[]const u8 = null,
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
    try writeJsonString(writer, action.action_id);
    try writer.writeAll(",\"audit_id\":");
    try writeJsonString(writer, action.audit_id);
    try writer.writeAll(",\"git_sha\":");
    try writeJsonString(writer, git_sha);
    try writer.writeAll(",\"state\":\"read_only\",\"status\":\"accepted\",\"command_argv_hash\":\"none\",\"artifact_paths\":[],\"cleanup\":\"pending\",\"host_mutation\":false}\n");
}

pub fn writeDuplicateRefusal(writer: anytype, seq: usize, action: protocol.OperatorAction) !void {
    try writeActionIdRefusal(writer, seq, action, "duplicate_action_id");
}

pub fn writeInvalidActionIdRefusal(writer: anytype, seq: usize, action: protocol.OperatorAction) !void {
    try writeActionIdRefusal(writer, seq, action, "invalid_action_id");
}

fn writeActionIdRefusal(writer: anytype, seq: usize, action: protocol.OperatorAction, reason: []const u8) !void {
    try writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"refusal\",\"action\":\"{s}\",\"action_id\":",
        .{ protocol.event_schema, seq, @tagName(action.kind) },
    );
    try writeJsonString(writer, action.action_id);
    try writer.writeAll(",\"state\":\"refused_host\",\"status\":\"refused\",\"reason\":");
    try writeJsonString(writer, reason);
    try writer.writeAll(",\"host_mutation\":false}\n");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u{x:0>4}", .{byte}) else try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

test "daemon journal tracker rejects duplicate action ids" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    try tracker.remember(std.testing.allocator, "act-1");
    try std.testing.expectError(error.DuplicateActionId, tracker.remember(std.testing.allocator, "act-1"));
    try std.testing.expectError(error.InvalidActionId, tracker.remember(std.testing.allocator, "bad id"));
}

test "daemon journal tracker loads existing action ids" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"journal_record\",\"status\":\"accepted\",\"action_id\":\"act-1\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"journal_record\",\"status\":\"accepted\",\"action_id\":\"act-2\",\"host_mutation\":false}\n";
    const loaded = try tracker.loadExisting(std.testing.allocator, raw);
    try std.testing.expectEqual(@as(usize, 2), loaded.count);
    try std.testing.expectEqual(@as(usize, 3), loaded.next_seq);
    try std.testing.expectError(error.DuplicateActionId, tracker.remember(std.testing.allocator, "act-2"));
}

test "daemon journal tracker rejects nonmonotonic existing sequence" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":99,\"event\":\"journal_record\",\"status\":\"accepted\",\"action_id\":\"act-1\",\"host_mutation\":false}\n";
    try std.testing.expectError(error.InvalidJournal, tracker.loadExisting(std.testing.allocator, raw));
}
