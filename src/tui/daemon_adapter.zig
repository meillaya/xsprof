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

    const follow_argv = [_][]const u8{ options.daemon_bin, "--foreground", "--follow", "--state-dir", state_dir };
    const normal_argv = [_][]const u8{ options.daemon_bin, "--foreground", "--state-dir", state_dir };
    const argv: []const []const u8 = if (action.kind == .run_lab_microvm_live) &follow_argv else &normal_argv;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .expand_arg0 = .expand,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    try child.stdin.?.writeStreamingAll(io, input);
    child.stdin.?.close(io);
    child.stdin = null;

    const raw = readDaemonOutput(allocator, io, child.stdout.?, action.kind == .run_lab_microvm_live) catch |err| switch (err) {
        error.StreamTimeout => try syntheticIncident(allocator, "stream_timeout"),
        else => |e| return e,
    };
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return .{ .status = "daemon unsafe_to_assume", .raw = raw };
    return .{ .status = statusFromDaemonOutput(allocator, raw, action), .raw = raw };
}

const max_daemon_output_bytes: usize = 64 * 1024;
const stream_poll_timeout_ms: i32 = 250;
const stream_idle_limit: usize = 40;

const StreamReadError = error{ StreamTimeout, OutOfMemory } || std.posix.PollError || std.Io.File.ReadStreamingError;

fn readDaemonOutput(allocator: std.mem.Allocator, io: std.Io, stdout: std.Io.File, incremental: bool) StreamReadError![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(allocator);
    var idle_polls: usize = 0;
    while (true) {
        var fds = [_]std.posix.pollfd{.{
            .fd = stdout.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP,
            .revents = 0,
        }};
        const timeout_ms = if (incremental) stream_poll_timeout_ms else 5000;
        const ready = try std.posix.poll(&fds, timeout_ms);
        if (ready == 0) {
            idle_polls += 1;
            if (idle_polls >= stream_idle_limit) return error.StreamTimeout;
            continue;
        }
        idle_polls = 0;
        var chunk: [2048]u8 = undefined;
        const read_len = stdout.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (read_len == 0) break;
        if (raw.items.len + read_len > max_daemon_output_bytes) return syntheticIncident(allocator, "stream_backpressure_dropped");
        try raw.appendSlice(allocator, chunk[0..read_len]);
    }
    return raw.toOwnedSlice(allocator);
}

fn syntheticIncident(allocator: std.mem.Allocator, reason: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"incident\",\"state\":\"unsafe_to_assume\",\"status\":\"unsafe_to_assume\",\"reason\":\"{s}\",\"host_mutation\":false}}\n",
        .{reason},
    );
}

pub fn statusForAction(action: protocol.OperatorAction) []const u8 {
    return switch (action.kind) {
        .verifier_only => "verifier queued local-daemon",
        .run_lab_host_safe => "host-safe lab queued local-daemon",
        .partial_attach => "partial attach queued local-daemon",
        .observe => "observe queued local-daemon",
        .stop, .stop_lab_run => "stop queued local-daemon",
        .rollback, .rollback_lab_run => "rollback queued local-daemon",
        .preflight => "preflight queued local-daemon",
        .run_lab_vm => "vm lab queued local-daemon",
        .run_lab_microvm_live => "live microvm queued local-daemon",
        .incident_drill => "incident drill queued local-daemon",
    };
}

pub fn statusFromDaemonOutput(allocator: std.mem.Allocator, raw: []const u8, action: protocol.OperatorAction) []const u8 {
    var found: []const u8 = "";
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = parseDaemonEvent(allocator, trimmed) catch return "daemon unsafe_to_assume";
        defer parsed.deinit();

        const event = parsed.value;
        if (!std.mem.eql(u8, event.schema, protocol.event_schema) or event.host_mutation) return "daemon unsafe_to_assume";
        if (isUnsafeIncident(event)) return "daemon unsafe_to_assume";
        const event_action = event.action orelse continue;
        if (!std.mem.eql(u8, event_action, @tagName(action.kind))) continue;
        if (isRefusal(event)) found = refusalStatus(action, event.reason.?);
        if (isStatus(event, "REFUSE")) {
            found = terminalRefuseStatus(action, event.reason orelse "refused");
            continue;
        }
        if (isStatus(event, "SKIP")) {
            found = terminalSkipStatus(action, event.reason orelse "skipped");
            continue;
        }
        if (std.mem.eql(u8, event.event, "incident") and isStatus(event, "INCIDENT")) {
            found = "INCIDENT rollback/fallback drill";
            continue;
        }
        if (isStatus(event, "queued") and found.len == 0) found = statusForAction(action);
        if (isStatus(event, "active")) found = activeStatus(action);
        if (isStatus(event, "PASS")) found = passStatus(action);
        if (isStatus(event, "already_rolled_back")) found = idempotentStatus(action);
        if (isStatus(event, "completed")) found = "daemon completed read-only action";
    }
    if (found.len != 0) return found;
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

fn isUnsafeIncident(event: RawDaemonEvent) bool {
    if (!std.mem.eql(u8, event.event, "incident")) return false;
    if (isStatus(event, "unsafe_to_assume")) return true;
    const reason = event.reason orelse return false;
    return std.mem.eql(u8, reason, "private_fields_rejected") or
        std.mem.eql(u8, reason, "malformed_runtime_sample") or
        std.mem.eql(u8, reason, "stream_backpressure_dropped");
}

fn parseDaemonEvent(allocator: std.mem.Allocator, raw: []const u8) !std.json.Parsed(RawDaemonEvent) {
    return std.json.parseFromSlice(RawDaemonEvent, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

fn isRefusal(event: RawDaemonEvent) bool {
    return std.mem.eql(u8, event.event, "refusal") and
        isStatus(event, "refused") and
        event.reason != null;
}

fn isStatus(event: RawDaemonEvent, expected: []const u8) bool {
    return event.status != null and std.mem.eql(u8, event.status.?, expected);
}

fn activeStatus(action: protocol.OperatorAction) []const u8 {
    return switch (action.kind) {
        .run_lab_vm => "vm lab active rollback ready",
        .run_lab_microvm_live => "live microvm active rollback ready",
        .incident_drill => "INCIDENT rollback/fallback drill",
        else => statusForAction(action),
    };
}

fn passStatus(action: protocol.OperatorAction) []const u8 {
    return switch (action.kind) {
        .rollback, .rollback_lab_run => "rollback completed PASS",
        .stop, .stop_lab_run => "stop completed PASS",
        .incident_drill => "INCIDENT rollback/fallback drill",
        else => "daemon completed read-only action",
    };
}

fn idempotentStatus(action: protocol.OperatorAction) []const u8 {
    return switch (action.kind) {
        .rollback, .rollback_lab_run => "rollback already_rolled_back",
        .stop, .stop_lab_run => "stop completed already_rolled_back",
        else => "daemon completed idempotent",
    };
}

fn refusalStatus(action: protocol.OperatorAction, reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "host_mutation_refused")) {
        return switch (action.kind) {
            .verifier_only => "verifier queued/refused host-safe",
            .partial_attach => "partial attach queued/refused host-safe",
            .stop, .rollback, .stop_lab_run, .rollback_lab_run => "rollback queued/refused host-safe",
            .incident_drill => "incident drill refused host-safe",
            .run_lab_microvm_live => "live microvm queued/refused host-safe",
            else => "daemon refused host-safe",
        };
    }
    if (std.mem.eql(u8, reason, "target_action_id_and_rollback_id_required")) return "rollback refused missing target/rollback id";
    if (std.mem.eql(u8, reason, "stale_or_unknown_target_action_id")) return "rollback refused stale target";
    if (std.mem.eql(u8, reason, "stale_rollback_id")) return "rollback refused stale rollback id";
    return "daemon refused host-safe";
}

fn terminalRefuseStatus(action: protocol.OperatorAction, reason: []const u8) []const u8 {
    if (action.kind == .run_lab_microvm_live) {
        if (std.mem.eql(u8, reason, "qemu_not_found")) return "live microvm REFUSE qemu_not_found";
        if (std.mem.eql(u8, reason, "kvm_unavailable")) return "live microvm REFUSE kvm_unavailable";
        if (std.mem.eql(u8, reason, "kernel_unavailable")) return "live microvm REFUSE kernel_unavailable";
        if (std.mem.eql(u8, reason, "nix_busybox_unavailable")) return "live microvm REFUSE nix_busybox_unavailable";
        return "live microvm REFUSE runner";
    }
    return refusalStatus(action, reason);
}

fn terminalSkipStatus(action: protocol.OperatorAction, reason: []const u8) []const u8 {
    if (action.kind == .run_lab_microvm_live) {
        if (std.mem.eql(u8, reason, "qemu_not_found")) return "live microvm SKIP qemu_not_found";
        if (std.mem.eql(u8, reason, "kvm_unavailable")) return "live microvm SKIP kvm_unavailable";
        return "live microvm SKIP host prerequisite";
    }
    return "daemon skipped host-safe";
}

test "daemon adapter source uses incremental poll loop with timeout" {
    const source = @embedFile("daemon_adapter.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "readDaemonOutput") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "std.posix.poll") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "StreamTimeout") != null);
}

test "daemon output parser treats private and dropped stream incidents as unsafe" {
    const private = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"incident\",\"status\":\"unsafe_to_assume\",\"reason\":\"private_fields_rejected\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, private, .{ .kind = .run_lab_microvm_live }));

    const dropped = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"incident\",\"status\":\"unsafe_to_assume\",\"reason\":\"stream_backpressure_dropped\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, dropped, .{ .kind = .run_lab_microvm_live }));
}

test "daemon output parser reports live microvm host-safe refusal" {
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_started\",\"action\":\"run_lab_microvm_live\",\"status\":\"queued\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"run_lab_microvm_live\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("live microvm queued/refused host-safe", statusFromDaemonOutput(std.testing.allocator, raw, .{ .kind = .run_lab_microvm_live }));
}

test "daemon output parser reports live microvm terminal runner refusal" {
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_started\",\"action\":\"run_lab_microvm_live\",\"status\":\"active\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_finished\",\"action\":\"run_lab_microvm_live\",\"status\":\"REFUSE\",\"reason\":\"qemu_not_found\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("live microvm REFUSE qemu_not_found", statusFromDaemonOutput(std.testing.allocator, raw, .{ .kind = .run_lab_microvm_live }));
}

test "daemon output parser marks malformed event unsafe" {
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, "not-json", .{ .kind = .verifier_only }));
}

test "daemon output parser reports verifier host-safe refusal" {
    const raw = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"verifier_only\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("verifier queued/refused host-safe", statusFromDaemonOutput(std.testing.allocator, raw, .{ .kind = .verifier_only }));
}

test "daemon output parser skips replayed actions and rejects host mutation" {
    const replay_then_match =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"partial_attach\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"rollback_completed\",\"action\":\"rollback_lab_run\",\"status\":\"already_rolled_back\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("rollback already_rolled_back", statusFromDaemonOutput(std.testing.allocator, replay_then_match, .{ .kind = .rollback_lab_run }));

    const mutation = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"verifier_only\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":true}\n";
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, mutation, .{ .kind = .verifier_only }));
}

test "daemon output parser reports rollback target refusals and PASS" {
    const missing = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"rollback_lab_run\",\"status\":\"refused\",\"reason\":\"target_action_id_and_rollback_id_required\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("rollback refused missing target/rollback id", statusFromDaemonOutput(std.testing.allocator, missing, .{ .kind = .rollback_lab_run }));

    const pass = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"rollback_completed\",\"action\":\"rollback_lab_run\",\"status\":\"PASS\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("rollback completed PASS", statusFromDaemonOutput(std.testing.allocator, pass, .{ .kind = .rollback_lab_run }));
}

test "daemon output parser preserves incident status after PASS event" {
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"incident\",\"action\":\"incident_drill\",\"status\":\"INCIDENT\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_finished\",\"action\":\"incident_drill\",\"status\":\"PASS\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("INCIDENT rollback/fallback drill", statusFromDaemonOutput(std.testing.allocator, raw, .{ .kind = .incident_drill }));
}
