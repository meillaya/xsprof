const std = @import("std");

pub const schema = "zig-scheduler/operator-action/v1";
pub const event_schema = "zig-scheduler/daemon-event/v1";

pub const ProtocolError = error{
    UnknownAction,
    InvalidField,
    InvalidSchema,
    InvalidJson,
    OutOfMemory,
};

pub const ActionKind = enum {
    preflight,
    run_lab_host_safe,
    run_lab_vm,
    run_lab_microvm_live,
    verifier_only,
    partial_attach,
    observe,
    stop,
    rollback,
    stop_lab_run,
    rollback_lab_run,
    incident_drill,
};

pub const EventKind = enum {
    state_changed,
    stage_started,
    stage_finished,
    microvm_boot,
    vm_marker,
    bpf_register,
    runtime_sample,
    rollback,
    cleanup,
    validation,
    incident,
    refusal,
};

pub const OperatorAction = struct {
    kind: ActionKind,
    action_id: []const u8 = "",
    run_id: []const u8 = "",
    target_cgroup: []const u8 = "",
    audit_id: []const u8 = "",
    rollback_id: []const u8 = "",
    target_action_id: []const u8 = "",

    pub fn toJson(self: OperatorAction, allocator: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);

        var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
        try writer.writer.print(
            "{{\"schema\":\"{s}\",\"action\":\"{s}\"",
            .{ schema, @tagName(self.kind) },
        );
        try appendOptionalJsonField(&writer.writer, "action_id", self.action_id);
        try appendOptionalJsonField(&writer.writer, "run_id", self.run_id);
        try appendOptionalJsonField(&writer.writer, "target_cgroup", self.target_cgroup);
        try appendOptionalJsonField(&writer.writer, "audit_id", self.audit_id);
        try appendOptionalJsonField(&writer.writer, "rollback_id", self.rollback_id);
        try appendOptionalJsonField(&writer.writer, "target_action_id", self.target_action_id);
        try writer.writer.writeByte('}');

        list = writer.toArrayList();
        return try list.toOwnedSlice(allocator);
    }
};

pub const DaemonEvent = struct {
    kind: EventKind,
    action_id: []const u8,
    status: []const u8,
    live_bundle_path: []const u8 = "",

    pub fn toJson(self: DaemonEvent, allocator: std.mem.Allocator) ![]const u8 {
        if (self.kind == .validation and self.live_bundle_path.len == 0) return error.InvalidField;
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
        try writer.writer.print(
            "{{\"schema\":\"{s}\",\"event\":\"{s}\",\"action_id\":\"{s}\",\"status\":\"{s}\",\"host_mutation\":false",
            .{ event_schema, @tagName(self.kind), self.action_id, self.status },
        );
        try appendOptionalJsonField(&writer.writer, "live_bundle_path", self.live_bundle_path);
        try writer.writer.writeByte('}');
        list = writer.toArrayList();
        return try list.toOwnedSlice(allocator);
    }
};

fn appendOptionalJsonField(writer: anytype, name: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try writer.writeAll(",\"");
    try writer.writeAll(name);
    try writer.writeAll("\":");
    try writeJsonString(writer, value);
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

const RawAction = struct {
    schema: ?[]const u8 = null,
    action: []const u8,
    action_id: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    target_cgroup: ?[]const u8 = null,
    audit_id: ?[]const u8 = null,
    rollback_id: ?[]const u8 = null,
    target_action_id: ?[]const u8 = null,
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
    host_mutation: ?bool = null,
};

pub const ParsedAction = struct {
    arena: std.json.Parsed(RawAction),
    value: OperatorAction,

    pub fn deinit(self: *const ParsedAction) void {
        var arena = self.arena;
        arena.deinit();
    }
};

pub fn parseActionJson(allocator: std.mem.Allocator, source: []const u8) ProtocolError!ParsedAction {
    var parsed = std.json.parseFromSlice(RawAction, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.InvalidJson;
    errdefer parsed.deinit();

    const raw = parsed.value;
    if (raw.schema) |found| {
        if (!std.mem.eql(u8, found, schema)) return error.InvalidSchema;
    }
    if (raw.command != null or raw.shell != null or raw.argv != null or raw.host_mutation != null) return error.InvalidField;

    const kind = parseActionKind(raw.action) orelse return error.UnknownAction;
    try validateOptional(raw.action_id);
    try validateOptional(raw.run_id);
    try validateOptionalTargetCgroup(raw.target_cgroup);
    try validateOptional(raw.audit_id);
    try validateOptional(raw.rollback_id);
    try validateOptional(raw.target_action_id);

    return .{ .arena = parsed, .value = .{
        .kind = kind,
        .action_id = raw.action_id orelse "",
        .run_id = raw.run_id orelse "",
        .target_cgroup = raw.target_cgroup orelse "",
        .audit_id = raw.audit_id orelse "",
        .rollback_id = raw.rollback_id orelse "",
        .target_action_id = raw.target_action_id orelse "",
    } };
}

fn parseActionKind(raw: []const u8) ?ActionKind {
    if (std.mem.eql(u8, raw, "stop")) return .stop_lab_run;
    if (std.mem.eql(u8, raw, "rollback")) return .rollback_lab_run;
    inline for (@typeInfo(ActionKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn validateOptionalTargetCgroup(value: ?[]const u8) ProtocolError!void {
    const raw = value orelse return;
    try validateSafeText(raw);
    var parts = std.mem.splitScalar(u8, raw, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidField;
    }
}

fn validateOptional(value: ?[]const u8) ProtocolError!void {
    if (value) |raw| try validateSafeText(raw);
}

fn validateSafeText(raw: []const u8) ProtocolError!void {
    if (raw.len == 0 or raw.len > 256) return error.InvalidField;
    for (raw) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidField;
        switch (byte) {
            '"', '\\', '`', '$', '&', '|', ';', '<', '>', '(', ')' => return error.InvalidField,
            else => {},
        }
    }
}
