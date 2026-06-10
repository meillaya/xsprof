const std = @import("std");
const sim_app = @import("sim_cli_app.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    sim_app.runWithArgs(allocator, argv[1..]) catch |err| {
        switch (err) {
            error.InvalidArguments, error.InvalidPolicy => {
                var stderr_buffer: [1024]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
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
