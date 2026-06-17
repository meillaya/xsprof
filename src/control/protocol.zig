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

test "operator action protocol rejects shell strings and unknown actions" {
    // Given: untrusted TUI/daemon action JSON containing an unknown action and shell-shaped text.
    // When: the boundary parser receives it.
    // Then: it must reject before any command registry can observe it.
    try std.testing.expectError(error.UnknownAction, parseActionJson(std.testing.allocator,
        \\{"action":"attach && rm -rf /","target_cgroup":"/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope"}
    ));
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"action":"run_lab_host_safe","run_id":"bad\nrun"}
    ));
}

test "operator action protocol rejects forbidden command fields" {
    // Given: untrusted TUI input tries to smuggle execution authority through JSON fields.
    // When: the boundary parser receives command, shell, or argv keys.
    // Then: the typed protocol rejects them before any daemon action can be created.
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"action":"run_lab_host_safe","command":"bash qa/vm/run_all_lab.sh"}
    ));
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"action":"run_lab_host_safe","shell":"sh"}
    ));
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"action":"run_lab_host_safe","argv":["qa/vm/run_all_lab.sh"]}
    ));
}

test "operator action protocol roundtrips typed lab action" {
    // Given: a valid host-safe lab action.
    // When: it is parsed and serialized at the trust boundary.
    // Then: the typed action and stable schema survive without shell command fields.
    const parsed = try parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_host_safe","run_id":"lab-demo"}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(ActionKind.run_lab_host_safe, parsed.value.kind);
    const rendered = try parsed.value.toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "run_lab_host_safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "command") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shell") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "argv") == null);
}

test "daemon event protocol roundtrips typed refusal" {
    const rendered = try (DaemonEvent{
        .kind = .refusal,
        .action_id = "act-1",
        .status = "refused_host",
    }).toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, event_schema) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "refused_host") != null);
}

test "operator action protocol rejects target cgroup traversal" {
    // Given: a known action with a traversal-shaped target cgroup.
    // When: the boundary parser receives it.
    // Then: the protocol rejects the path before daemon or harness code sees it.
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"action":"partial_attach","target_cgroup":"/sys/fs/cgroup/zig-scheduler-lab.slice/../../system.slice"}
    ));
}

test "operator action protocol preserves partial attach gates when rendering" {
    // Given: a valid partial attach action with cgroup, audit id, and rollback id gates.
    // When: it is parsed and rendered for daemon/TUI journaling.
    // Then: every gate survives the roundtrip and no shell command fields appear.
    const parsed = try parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"partial_attach","target_cgroup":"/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-demo"}
    );
    defer parsed.deinit();
    const rendered = try parsed.value.toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "partial_attach") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AUD-20990101T000000Z-deadbee-abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "RB-demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "command") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shell") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "argv") == null);
}

test "operator action protocol accepts rollback lab targets" {
    const parsed = try parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"rollback_lab_run","action_id":"rb-1","target_action_id":"lab-1","rollback_id":"RB-demo"}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(ActionKind.rollback_lab_run, parsed.value.kind);
    try std.testing.expectEqualStrings("lab-1", parsed.value.target_action_id);
    const rendered = try parsed.value.toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "target_action_id") != null);
}

test "operator action protocol accepts live microvm action without execution fields" {
    const parsed = try parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"live-1","run_id":"live-demo","audit_id":"AUD-live-demo","rollback_id":"RB-live-demo"}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(ActionKind.run_lab_microvm_live, parsed.value.kind);
    try std.testing.expectEqualStrings("live-demo", parsed.value.run_id);

    const rendered = try parsed.value.toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "run_lab_microvm_live") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "command") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shell") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "argv") == null);
}

test "operator action protocol rejects live microvm command smuggling" {
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","run_id":"live-demo","argv":["qemu-system-x86_64"]}
    ));
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","run_id":"live-demo","command":"qa/vm/run_microvm_live_lab.sh"}
    ));
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","run_id":"live-demo","shell":"sh"}
    ));
}

test "operator action protocol rejects live microvm host mutation flags" {
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","run_id":"live-demo","host_mutation":true}
    ));
}

test "daemon event protocol includes live microvm lifecycle event kinds" {
    const lifecycle = [_]EventKind{
        .microvm_boot,
        .vm_marker,
        .bpf_register,
        .runtime_sample,
        .rollback,
        .cleanup,
    };
    inline for (lifecycle) |kind| {
        const rendered = try (DaemonEvent{
            .kind = kind,
            .action_id = "live-1",
            .status = "accepted",
        }).toJson(std.testing.allocator);
        defer std.testing.allocator.free(rendered);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "host_mutation\":false") != null);
    }
}

test "daemon validation event requires live bundle path" {
    try std.testing.expectError(error.InvalidField, (DaemonEvent{
        .kind = .validation,
        .action_id = "live-1",
        .status = "PASS",
    }).toJson(std.testing.allocator));
}

test "daemon event protocol exposes live bundle path for validation events" {
    const rendered = try (DaemonEvent{
        .kind = .validation,
        .action_id = "live-1",
        .status = "PASS",
        .live_bundle_path = "evidence/lab/run-all/microvm-live-tui-demo/summary.json",
    }).toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"live_bundle_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "microvm-live-tui-demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "host_mutation\":false") != null);
}
