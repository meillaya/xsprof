const std = @import("std");
const bench = @import("bench_root");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const options = bench.parseArgs(argv[1..]) catch {
        try stderr.writeAll("usage: zig-scheduler-bench [--format markdown|json]\n");
        try stderr.flush();
        std.process.exit(1);
    };

    const rendered = bench.render(allocator, options.output_format) catch |err| {
        try stderr.print("benchmark failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(rendered);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(rendered);
    try stdout.flush();
}
