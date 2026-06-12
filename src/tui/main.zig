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
    if (options.interactive) return runInteractive(allocator, options);

    const frame = try tui.renderSnapshot(allocator, options);
    defer allocator.free(frame);
    try writeStdout(frame);
}

fn runInteractive(allocator: std.mem.Allocator, options: tui.Options) !void {
    const original_termios = enableRawMode();
    defer if (original_termios) |original| std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original) catch {};

    const initial = try tui.renderInteractive(allocator, options, null);
    defer allocator.free(initial);
    try writeStdout(initial);

    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(std.Io.Threaded.global_single_threaded.io(), &stdin_buffer);
    while (true) {
        const key = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (key == 'q' or key == 3) break;
        const action = tui.interactiveActionForKey(key) orelse continue;
        const frame = try tui.renderInteractive(allocator, options, action);
        defer allocator.free(frame);
        try writeStdout("\n");
        try writeStdout(frame);
    }
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
