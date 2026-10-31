const std = @import("std");
const doctor = @import("../recorder/doctor.zig");

const Writer = std.Io.Writer;

pub fn cmdDoctor(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    for (args) |arg| {
        if (!std.mem.eql(u8, arg, "--json")) {
            try err.print("doctor: unknown option {s}\n", .{arg});
            return 2;
        }
    }
    const result = doctor.run(io, allocator) catch |run_error| {
        try err.print("doctor: {s}\n", .{@errorName(run_error)});
        return 1;
    };
    try doctor.writeJson(out, result);
    try out.writeByte('\n');
    return if (std.mem.eql(u8, result.status, "REFUSE")) 1 else 0;
}
