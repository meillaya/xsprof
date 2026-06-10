const std = @import("std");
const linux = @import("linux_scheduler");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = argv[1..];
    if (args.len != 1 or !std.mem.eql(u8, args[0], "--json")) {
        try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "refused: linux-preflight is read-only and only accepts --json; no mutation or apply mode exists\n");
        std.process.exit(2);
    }

    var report = try linux.collectPreflight(allocator);
    defer report.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
    try linux.writePreflightJson(&stdout_writer.interface, report);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

test "preflight executable module links safety facade" {
    try std.testing.expect(!linux.isUnsafeCommand("preflight"));
}
