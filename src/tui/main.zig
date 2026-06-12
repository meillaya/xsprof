const std = @import("std");
const tui = @import("linux_scheduler_tui");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const options = tui.parseArgs(argv[1..]) catch {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
        try tui.writeUsage(&stderr_writer.interface, "zig-scheduler-tui");
        try stderr_writer.interface.flush();
        std.process.exit(2);
    };
    if (options.interactive) return runInteractive(allocator, init.io, options);

    const frame = try tui.renderSnapshot(allocator, options);
    defer allocator.free(frame);
    try writeStdout(frame);
}

fn runInteractive(allocator: std.mem.Allocator, io: std.Io, options: tui.Options) !void {
    const original_termios = enableRawMode();
    defer if (original_termios) |original| std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original) catch {};

    const initial = try tui.renderInteractive(allocator, options, null);
    defer allocator.free(initial);
    try writeStdout(initial);

    var control_state = tui.interaction.ControlState{};
    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(std.Io.Threaded.global_single_threaded.io(), &stdin_buffer);
    while (true) {
        const key = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (key == 'q' or key == 3) break;
        const result = tui.interaction.controlForKey(key, &control_state, options.test_mode) orelse continue;
        const status = try controlStatus(allocator, io, options, result);
        defer status.deinit(allocator);
        const frame = try tui.renderInteractiveStatus(allocator, options, status.text);
        defer allocator.free(frame);
        try writeStdout("\n");
        try writeStdout(frame);
    }
}

const ActionStatus = struct {
    text: []const u8,
    owned: ?tui.daemon_adapter.Dispatch = null,

    fn deinit(self: ActionStatus, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| owned.deinit(allocator);
    }
};

fn controlStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    result: tui.interaction.ControlResult,
) !ActionStatus {
    return switch (result) {
        .status => |text| .{ .text = text },
        .action => |action| dispatchStatus(allocator, io, options, action),
    };
}

fn dispatchStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    action: tui.OperatorAction,
) !ActionStatus {
    if (options.daemon_state_dir == null) return .{ .text = tui.interaction.statusForAction(action) };
    const dispatch = tui.daemon_adapter.dispatch(allocator, io, options, action) catch {
        return .{ .text = "daemon unsafe_to_assume" };
    };
    return .{ .text = dispatch.status, .owned = dispatch };
}

fn enableRawMode() ?std.posix.termios {
    const original = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return null;
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch return null;
    return original;
}

fn writeStdout(bytes: []const u8) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
    try stdout_writer.interface.writeAll(bytes);
    try stdout_writer.interface.flush();
}

test "tui executable links parser" {
    _ = try tui.parseArgs(&.{ "--snapshot", "--screen", "preflight" });
}
