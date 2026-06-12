const std = @import("std");
const linux = @import("linux_scheduler");
const args = @import("args.zig");

const protocol = linux.control.protocol;

pub const Dispatch = struct {
    status: []const u8,
    raw: []u8,

    pub fn deinit(self: Dispatch, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
    }
};

pub fn dispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: args.Options,
    action: protocol.OperatorAction,
) !Dispatch {
    const state_dir = options.daemon_state_dir orelse return .{
        .status = statusForAction(action),
        .raw = try allocator.dupe(u8, ""),
    };
    try linux.control.daemon.validateStateDir(state_dir);
    const payload = try action.toJson(allocator);
    defer allocator.free(payload);
    const input = try std.fmt.allocPrint(allocator, "{s}\n", .{payload});
    defer allocator.free(input);

    const argv = [_][]const u8{ options.daemon_bin, "--foreground", "--state-dir", state_dir };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .expand_arg0 = .expand,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    try child.stdin.?.writeStreamingAll(io, input);
    child.stdin.?.close(io);
    child.stdin = null;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &stdout_buffer);
    const raw = try stdout_reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return .{ .status = "daemon unsafe_to_assume", .raw = raw };
    return .{ .status = statusFromDaemonOutput(allocator, raw, action), .raw = raw };
}

pub fn statusForAction(action: protocol.OperatorAction) []const u8 {
    return switch (action.kind) {
        .verifier_only => "verifier queued local-daemon",
        .run_lab_host_safe => "host-safe lab queued local-daemon",
        .partial_attach => "partial attach queued local-daemon",
        .observe => "observe queued local-daemon",
        .stop => "stop queued local-daemon",
        .rollback => "rollback queued local-daemon",
        .preflight => "preflight queued local-daemon",
        .run_lab_vm => "vm lab queued local-daemon",
    };
}

pub fn statusFromDaemonOutput(allocator: std.mem.Allocator, raw: []const u8, action: protocol.OperatorAction) []const u8 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = parseDaemonEvent(allocator, trimmed) catch return "daemon unsafe_to_assume";
        defer parsed.deinit();

        const event = parsed.value;
        if (!std.mem.eql(u8, event.schema, protocol.event_schema) or event.host_mutation) return "daemon unsafe_to_assume";
        const event_action = event.action orelse continue;
        if (!std.mem.eql(u8, event_action, @tagName(action.kind))) return "daemon unsafe_to_assume";
        if (isRefusal(event)) return refusalStatus(action);
        if (isStatus(event, "queued")) return statusForAction(action);
        if (isStatus(event, "completed")) return "daemon completed read-only action";
    }
    return "daemon unsafe_to_assume";
}

const RawDaemonEvent = struct {
    schema: []const u8,
    event: []const u8,
    action: ?[]const u8 = null,
    status: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    host_mutation: bool,
};

fn parseDaemonEvent(allocator: std.mem.Allocator, raw: []const u8) !std.json.Parsed(RawDaemonEvent) {
    return std.json.parseFromSlice(RawDaemonEvent, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

fn isRefusal(event: RawDaemonEvent) bool {
    return std.mem.eql(u8, event.event, "refusal") and
        isStatus(event, "refused") and
        event.reason != null and
        std.mem.eql(u8, event.reason.?, "host_mutation_refused");
}

fn isStatus(event: RawDaemonEvent, expected: []const u8) bool {
    return event.status != null and std.mem.eql(u8, event.status.?, expected);
}

fn refusalStatus(action: protocol.OperatorAction) []const u8 {
    return switch (action.kind) {
        .verifier_only => "verifier queued/refused host-safe",
        .partial_attach => "partial attach queued/refused host-safe",
        .stop, .rollback => "rollback queued/refused host-safe",
        else => "daemon refused host-safe",
    };
}

test "daemon output parser marks malformed event unsafe" {
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, "not-json", .{ .kind = .verifier_only }));
}

test "daemon output parser reports verifier host-safe refusal" {
    const raw = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"verifier_only\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("verifier queued/refused host-safe", statusFromDaemonOutput(std.testing.allocator, raw, .{ .kind = .verifier_only }));
}

test "daemon output parser rejects mismatched action and host mutation" {
    const mismatch = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"partial_attach\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, mismatch, .{ .kind = .verifier_only }));

    const mutation = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"verifier_only\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":true}\n";
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, mutation, .{ .kind = .verifier_only }));
}
