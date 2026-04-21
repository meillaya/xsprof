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
        if (err == error.NotATerminal) {
            try std.fs.File.stderr().writeAll("zig-scheduler-tui requires a TTY on stdin/stdout\n");
            return;
        }
        return err;
    };
}

fn usage() !void {
    try std.fs.File.stderr().writeAll(
        "usage: zig-scheduler-tui [--input <report.json> | --stdin | --scenario <name> --policy <policy> | --scenario-file <path> --policy <policy>]\n",
    );
}
