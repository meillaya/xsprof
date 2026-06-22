const std = @import("std");

pub const max_daemon_output_bytes: usize = 64 * 1024;
const stream_poll_timeout_ms: i32 = 250;
const stream_idle_limit: usize = 40;
pub const terminate_to_kill_grace_ms: i64 = 200;

pub const StreamReadError = error{ StreamTimeout, OutOfMemory } || std.posix.PollError || std.Io.File.ReadStreamingError;

pub const CleanupReason = enum { normal_exit, stream_timeout, dispatch_error };

pub const CleanupTarget = union(enum) {
    none,
    owned_process_group: std.posix.pid_t,
};

pub const CleanupDecision = struct {
    target: CleanupTarget,
    signals: []const std.posix.SIG,

    pub fn terminateOwnedProcessGroup(self: CleanupDecision) bool {
        return switch (self.target) {
            .none => false,
            .owned_process_group => true,
        };
    }

    pub fn targetPgid(self: CleanupDecision) ?std.posix.pid_t {
        return switch (self.target) {
            .none => null,
            .owned_process_group => |pgid| pgid,
        };
    }
};

const cleanup_escalation_signals = [_]std.posix.SIG{ .TERM, .KILL };

pub fn cleanupDecision(child_id: ?std.posix.pid_t, reason: CleanupReason) CleanupDecision {
    if (reason == .normal_exit) return noCleanupDecision();
    const pid = child_id orelse return noCleanupDecision();
    if (pid <= 1) return noCleanupDecision();
    return .{
        .target = .{ .owned_process_group = pid },
        .signals = &cleanup_escalation_signals,
    };
}

fn noCleanupDecision() CleanupDecision {
    return .{ .target = .none, .signals = &.{} };
}

pub fn terminateChildProcessGroup(io: std.Io, child: *std.process.Child) void {
    terminateChildProcessGroupForReason(io, child, .dispatch_error);
}

pub fn terminateChildProcessGroupForReason(io: std.Io, child: *std.process.Child, reason: CleanupReason) void {
    const decision = cleanupDecision(child.id, reason);
    const pgid = decision.targetPgid() orelse return;
    const group_pid: std.posix.pid_t = -pgid;
    for (decision.signals, 0..) |sig, index| {
        std.posix.kill(group_pid, sig) catch {};
        if (index + 1 < decision.signals.len) boundedGracePoll();
    }
    _ = child.wait(io) catch {};
}

fn boundedGracePoll() void {
    var fds = [_]std.posix.pollfd{};
    _ = std.posix.poll(&fds, @intCast(terminate_to_kill_grace_ms)) catch {};
}

pub fn readDaemonOutput(allocator: std.mem.Allocator, io: std.Io, stdout: std.Io.File, incremental: bool) StreamReadError![]u8 {
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

pub fn syntheticIncident(allocator: std.mem.Allocator, reason: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"incident\",\"state\":\"unsafe_to_assume\",\"status\":\"unsafe_to_assume\",\"reason\":\"{s}\",\"host_mutation\":false}}\n",
        .{reason},
    );
}

test "cleanup decision only targets owned process groups on timeout/error paths" {
    const timeout = cleanupDecision(1234, .stream_timeout);
    try std.testing.expect(timeout.terminateOwnedProcessGroup());
    try std.testing.expectEqual(@as(?std.posix.pid_t, 1234), timeout.targetPgid());
    try std.testing.expectEqual(@as(usize, 2), timeout.signals.len);
    try std.testing.expectEqual(std.posix.SIG.TERM, timeout.signals[0]);
    try std.testing.expectEqual(std.posix.SIG.KILL, timeout.signals[1]);

    const dispatch_error = cleanupDecision(1234, .dispatch_error);
    try std.testing.expect(dispatch_error.terminateOwnedProcessGroup());
    try std.testing.expectEqual(@as(?std.posix.pid_t, 1234), dispatch_error.targetPgid());

    try std.testing.expect(!cleanupDecision(1234, .normal_exit).terminateOwnedProcessGroup());
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), cleanupDecision(1234, .normal_exit).targetPgid());
    try std.testing.expect(!cleanupDecision(null, .stream_timeout).terminateOwnedProcessGroup());
    try std.testing.expect(!cleanupDecision(0, .dispatch_error).terminateOwnedProcessGroup());
}
