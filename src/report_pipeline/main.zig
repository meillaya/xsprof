const std = @import("std");
const report_pipeline = @import("report_pipeline_root");

const Options = struct {
    check: bool = false,
    output_dir: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    const options = parseArgs(argv[1..]) catch |err| switch (err) {
        error.ShowHelp => {
            try writeUsageAndExit(0);
            return;
        },
        else => {
            try writeUsageAndExit(1);
            return;
        },
    };

    if (options.check) {
        const ok = if (options.output_dir) |output_dir| blk: {
            break :blk report_pipeline.checkAllInPath(allocator, output_dir) catch |err| {
                try writeError(err);
                std.process.exit(1);
            };
        } else blk: {
            break :blk report_pipeline.checkAll(allocator) catch |err| {
                try writeError(err);
                std.process.exit(1);
            };
        };
        if (!ok) std.process.exit(1);

        var stdout_buffer: [256]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.writeAll("report pipeline is up to date\n");
        try stdout.flush();
        return;
    }

    if (options.output_dir) |output_dir| {
        report_pipeline.writeAllToPath(allocator, output_dir) catch |err| {
            try writeError(err);
            std.process.exit(1);
        };
    } else {
        report_pipeline.writeAll(allocator) catch |err| {
            try writeError(err);
            std.process.exit(1);
        };
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("regenerated reproducible report artifacts\n");
    try stdout.flush();
}

fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--check")) {
            options.check = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--output-dir")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.output_dir = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) return error.ShowHelp;
        return error.InvalidArguments;
    }
    return options;
}

fn writeUsageAndExit(exit_code: u8) !void {
    var stderr_buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll("usage: zig-scheduler-reports [--check] [--output-dir <path>]\n");
    try stderr.flush();
    std.process.exit(exit_code);
}

fn writeError(err: anyerror) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("report pipeline failed: {s}\n", .{@errorName(err)});
    try stderr.flush();
}
