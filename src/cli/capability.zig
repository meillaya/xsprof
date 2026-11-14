//! Shared CLI capability records. Fail-closed probes use the same canonical
//! shape on every command so scripts can parse SKIP/REFUSE reasons.
//!
//! This is a `xsprof/capability/v1` document, not an `xsprof/event/v1` row:
//! it is a probe result (name/state/reason), not a captured event sample, and
//! `validate --schema event.v1` intentionally rejects it. The matching schema
//! lives in `schemas/xsprof/capability.v1.schema.json`.

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
        .{ .key = "schema", .value = .{ .string = "xsprof/capability/v1" } },
        .{ .key = "state", .value = .{ .string = state } },
    } });
    try out.writeByte('\n');
}

test "capability records use the capability schema, not event.v1" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCapabilityEvent(
        &w,
        "stack_sampling",
        "SKIP",
        "perf_event_paranoid=2; no CAP_PERFMON (fail-closed SKIP)",
    );
    try std.testing.expectEqualStrings(
        "{\"event\":\"capability\",\"host_mutation\":false,\"name\":\"stack_sampling\"," ++
            "\"reason\":\"perf_event_paranoid=2; no CAP_PERFMON (fail-closed SKIP)\"," ++
            "\"schema\":\"xsprof/capability/v1\",\"state\":\"SKIP\"}\n",
        w.buffered(),
    );
}
