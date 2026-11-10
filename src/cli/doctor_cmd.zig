const std = @import("std");
const doctor = @import("../recorder/doctor.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;

pub fn cmdDoctor(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var json_output = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else {
            try err.print("doctor: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    const result = doctor.run(io, allocator) catch |run_error| {
        try err.print("doctor: {s}\n", .{@errorName(run_error)});
        return .refuse;
    };
    if (json_output) {
        try doctor.writeJson(out, result);
        try out.writeByte('\n');
    } else {
        try out.print("xsprof doctor  status={s}\n", .{result.status});
        for (result.checks) |check| {
            try out.print("  {s:<5} {s:<20} {s}\n", .{ check.state, check.name, check.reason });
        }
        try out.writeAll(
            "\nThis host remains read-only. Fixes are not executed; see docs/guides/flight-recorder.md.\n",
        );
    }
    return if (std.mem.eql(u8, result.status, "REFUSE")) .refuse else .ok;
}
