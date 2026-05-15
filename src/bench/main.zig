const std = @import("std");
const bench = @import("bench_root");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
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
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(rendered);
    try stdout.flush();
}
