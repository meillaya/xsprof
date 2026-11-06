//! Shared CLI capability records. Fail-closed probes use the same canonical
//! shape on every command so scripts can parse SKIP/REFUSE reasons.

const std = @import("std");
const json = @import("../core/json.zig");
const live = @import("../capture/live.zig");

const Writer = std.Io.Writer;

pub fn stateName(state: live.State) []const u8 {
    return switch (state) {
        .READY => "READY",
        .DEGRADED => "DEGRADED",
        .SKIP => "SKIP",
        .REFUSE => "REFUSE",
    };
}

pub fn writeCapabilityEvent(
    out: *Writer,
    name: []const u8,
    state: []const u8,
    reason: []const u8,
) !void {
    try json.write(out, .{ .object = &.{
        .{ .key = "event", .value = .{ .string = "capability" } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "name", .value = .{ .string = name } },
        .{ .key = "reason", .value = .{ .string = reason } },
        .{ .key = "schema", .value = .{ .string = "xsprof/event/v1" } },
        .{ .key = "state", .value = .{ .string = state } },
    } });
    try out.writeByte('\n');
}
