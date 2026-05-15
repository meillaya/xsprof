const std = @import("std");
const perf = @import("perf_root");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const rendered = perf.renderMarkdown(allocator) catch |err| {
        try writeError(err);
        std.process.exit(1);
    };
    defer allocator.free(rendered);

    try perf.assertBudgets(allocator);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(rendered);
    try stdout.flush();
}

fn writeError(err: anyerror) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("performance gate failed: {s}\n", .{@errorName(err)});
    try stderr.flush();
}
