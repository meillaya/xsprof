const std = @import("std");
const bpf = @import("../capture/bpf.zig");
const json = @import("../core/json.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;

pub fn cmdBpf(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    for (args) |arg| {
        if (!std.mem.eql(u8, arg, "--json")) {
            try err.print("bpf-gate: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    const result = bpf.run(io, allocator) catch |run_error| {
        try err.print("bpf-gate: {s}\n", .{@errorName(run_error)});
        return .refuse;
    };
    try json.write(out, .{ .object = &.{
        .{ .key = "attached", .value = .{ .boolean = result.attached } },
        .{ .key = "capability", .value = .{ .string = @tagName(result.state) } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "libbpf", .value = .{ .boolean = result.libbpf } },
        .{ .key = "program_loaded", .value = .{ .boolean = result.program_loaded } },
        .{ .key = "reason", .value = .{ .string = result.reason } },
        .{ .key = "schema", .value = .{ .string = "xsprof/bpf-gate/v1" } },
        .{ .key = "vm_marker", .value = .{ .string = result.vm_marker } },
    } });
    try out.writeByte('\n');
    return if (result.state == .READY) .ok else .refuse;
}
