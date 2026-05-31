const std = @import("std");
const tui = @import("tui_root");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    const options = tui.parseArgs(argv[1..]) catch {
        try usage();
        return;
    };

    tui.run(allocator, options) catch |err| {
        switch (err) {
            error.NotATerminal => {
                try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "zig-scheduler-tui interactive mode requires a TTY; use --snapshot for redirected output\n");
                return;
            },
            error.NonTtyDashboardRequiresSnapshot => {
                try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "zig-scheduler-tui without a TTY needs an explicit source plus --snapshot, e.g. --stdin --snapshot or --input <report.json> --snapshot\n");
                return;
            },
            error.InvalidArguments => {
                try usage();
                return;
            },
            else => return err,
        }
    };
}

fn usage() !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
    try tui.writeUsage(&stderr_writer.interface, "zig-scheduler-tui");
    try stderr_writer.interface.flush();
}
