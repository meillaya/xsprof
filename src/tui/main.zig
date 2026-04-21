const std = @import("std");
const tui = @import("tui_root");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const options = tui.parseArgs(argv[1..]) catch {
        try usage();
        return;
    };

    tui.run(allocator, options) catch |err| {
        switch (err) {
            error.NotATerminal => {
                try std.fs.File.stderr().writeAll("zig-scheduler-tui interactive mode requires a TTY; use --snapshot for redirected output\n");
                return;
            },
            error.NonTtyPickerRequiresSnapshot => {
                try std.fs.File.stderr().writeAll("zig-scheduler-tui without a TTY needs an explicit source plus --snapshot, e.g. --stdin --snapshot or --input <report.json> --snapshot\n");
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
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try tui.writeUsage(&stderr_writer.interface, "zig-scheduler-tui");
    try stderr_writer.interface.flush();
}
