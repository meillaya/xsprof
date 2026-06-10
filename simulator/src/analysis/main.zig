const std = @import("std");
const analysis = @import("analysis_root");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const options = analysis.parseArgs(argv[1..]) catch {
        try writeUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    };

    const rendered = analysis.analyzeFile(allocator, options.input_path, options.output_format) catch |err| {
        try writeError(stderr, err);
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

fn writeUsage(writer: anytype) !void {
    try writer.writeAll(
        "usage: zig-scheduler-analyze --input <report.json> [--format markdown|svg]\n",
    );
}

fn writeError(writer: anytype, err: anyerror) !void {
    switch (err) {
        error.MissingSchema => try writer.writeAll("analysis failed: missing export schema\n"),
        error.UnsupportedSchema => try writer.writeAll("analysis failed: unsupported export schema\n"),
        error.MissingVersion => try writer.writeAll("analysis failed: missing export version\n"),
        error.UnsupportedVersion => try writer.writeAll("analysis failed: unsupported export version\n"),
        else => try writer.print("analysis failed: {s}\n", .{@errorName(err)}),
    }
}
