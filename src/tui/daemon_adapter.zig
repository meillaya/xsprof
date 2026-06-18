const std = @import("std");
const linux = @import("linux_scheduler");
const args = @import("args.zig");
const daemon_output = @import("daemon_output.zig");
const daemon_process = @import("daemon_process.zig");

const protocol = linux.control.protocol;

pub const Dispatch = struct {
    status: []const u8,
    raw: []u8,

    pub fn deinit(self: Dispatch, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
    }
};

pub const LiveSession = struct {
    child: std.process.Child,
    raw: std.ArrayList(u8) = .empty,
    waited: bool = false,

    pub fn stdoutFd(self: *const LiveSession) std.posix.fd_t {
        return self.child.stdout.?.handle;
    }

    pub fn readAvailable(self: *LiveSession, allocator: std.mem.Allocator, io: std.Io) ![]u8 {
        var chunk: [4096]u8 = undefined;
        const read_len = self.child.stdout.?.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => return try allocator.dupe(u8, ""),
            else => |e| return e,
        };
        if (read_len == 0) return try allocator.dupe(u8, "");
        try self.raw.appendSlice(allocator, chunk[0..read_len]);
        return try allocator.dupe(u8, chunk[0..read_len]);
    }

    pub fn terminate(self: *LiveSession, io: std.Io) void {
        if (self.waited) return;
        daemon_process.terminateChildProcessGroup(io, &self.child);
        self.waited = true;
    }

    pub fn wait(self: *LiveSession, io: std.Io) !std.process.Child.Term {
        if (self.waited) return .{ .exited = 0 };
        const term = try self.child.wait(io);
        self.waited = true;
        return term;
    }

    pub fn deinit(self: *LiveSession, allocator: std.mem.Allocator, io: std.Io) void {
        self.terminate(io);
        self.raw.deinit(allocator);
    }
};

pub fn startLive(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: args.Options,
    action: protocol.OperatorAction,
) !LiveSession {
    return startSession(allocator, io, options, action, true);
}

pub fn startControl(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: args.Options,
    action: protocol.OperatorAction,
) !LiveSession {
    return startSession(allocator, io, options, action, false);
}

fn startSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: args.Options,
    action: protocol.OperatorAction,
    follow: bool,
) !LiveSession {
    const state_dir = options.daemon_state_dir orelse return error.InvalidArguments;
    try linux.control.daemon.validateStateDir(state_dir);
    const payload = try action.toJson(allocator);
    defer allocator.free(payload);
    const input = try std.fmt.allocPrint(allocator, "{s}\n", .{payload});
    defer allocator.free(input);

    const follow_argv = [_][]const u8{ options.daemon_bin, "--foreground", "--follow", "--state-dir", state_dir };
    const normal_argv = [_][]const u8{ options.daemon_bin, "--foreground", "--state-dir", state_dir };
    const argv: []const []const u8 = if (follow) &follow_argv else &normal_argv;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .expand_arg0 = .expand,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    errdefer daemon_process.terminateChildProcessGroup(io, &child);
    try child.stdin.?.writeStreamingAll(io, input);
    child.stdin.?.close(io);
    child.stdin = null;
    return .{ .child = child };
}

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
        .pgid = 0,
    });
    var child_waited = false;
    defer if (!child_waited) daemon_process.terminateChildProcessGroup(io, &child);

    try child.stdin.?.writeStreamingAll(io, input);
    child.stdin.?.close(io);
    child.stdin = null;

    const raw = daemon_process.readDaemonOutput(allocator, io, child.stdout.?, action.kind == .run_lab_microvm_live) catch |err| switch (err) {
        error.StreamTimeout => blk: {
            daemon_process.terminateChildProcessGroup(io, &child);
            child_waited = true;
            break :blk try daemon_process.syntheticIncident(allocator, "stream_timeout");
        },
        else => |e| return e,
    };
    if (child_waited) return .{ .status = "daemon unsafe_to_assume", .raw = raw };
    const term = try child.wait(io);
    child_waited = true;
    if (term != .exited or term.exited != 0) return .{ .status = "daemon unsafe_to_assume", .raw = raw };
    return .{ .status = statusFromDaemonOutput(allocator, raw, action), .raw = raw };
}

pub const statusForAction = daemon_output.statusForAction;
pub const statusFromDaemonOutput = daemon_output.statusFromDaemonOutput;

test "daemon adapter helper modules are linked" {
    std.testing.refAllDecls(daemon_output);
    std.testing.refAllDecls(daemon_process);
}
