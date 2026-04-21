const std = @import("std");
const sim_app = @import("sim_cli_app.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    sim_app.runWithArgs(allocator, argv[1..]) catch |err| {
        switch (err) {
            error.InvalidArguments, error.InvalidPolicy => {
                var stderr_buffer: [1024]u8 = undefined;
                var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
                try sim_app.writeUsage(&stderr_writer.interface, "zig-scheduler-sim");
                try stderr_writer.interface.flush();
                return;
            },
            else => return err,
        }
    };
}

test {
    _ = @import("sim_cli_app.zig");
}
