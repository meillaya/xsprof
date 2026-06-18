const std = @import("std");

pub const max_daemon_output_bytes: usize = 64 * 1024;
const stream_poll_timeout_ms: i32 = 250;
const stream_idle_limit: usize = 40;

pub const StreamReadError = error{ StreamTimeout, OutOfMemory } || std.posix.PollError || std.Io.File.ReadStreamingError;

pub const CleanupReason = enum { normal_exit, stream_timeout, dispatch_error };

pub const CleanupDecision = struct {
    terminate_owned_process_group: bool,
};

pub fn cleanupDecision(child_id: ?std.posix.pid_t, reason: CleanupReason) CleanupDecision {
    return .{ .terminate_owned_process_group = child_id != null and reason != .normal_exit };
}

pub fn terminateChildProcessGroup(io: std.Io, child: *std.process.Child) void {
    const decision = cleanupDecision(child.id, .dispatch_error);
    if (!decision.terminate_owned_process_group) return;
    const pid = child.id.?;
    const group_pid: std.posix.pid_t = -pid;
    std.posix.kill(group_pid, .TERM) catch {};
    std.posix.kill(group_pid, .KILL) catch {};
    child.kill(io);
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
    try std.testing.expect(cleanupDecision(1234, .stream_timeout).terminate_owned_process_group);
    try std.testing.expect(cleanupDecision(1234, .dispatch_error).terminate_owned_process_group);
    try std.testing.expect(!cleanupDecision(1234, .normal_exit).terminate_owned_process_group);
    try std.testing.expect(!cleanupDecision(null, .stream_timeout).terminate_owned_process_group);
}
