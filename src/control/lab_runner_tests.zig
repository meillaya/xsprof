const std = @import("std");
const lab_runner = @import("lab_runner.zig");

const appendMicrovmLiveStartEvents = lab_runner.appendMicrovmLiveStartEvents;

test "live microvm start events publish active rollback target before runner blocks" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendMicrovmLiveStartEvents(std.testing.allocator, &output, .{
        .kind = .run_lab_microvm_live,
        .action_id = "live-active",
        .run_id = "live-active",
        .target_id = "target-live-active",
        .rollback_id = "RB-live-active",
    }, &seq);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"lab_run_active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"action_id\":\"live-active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"rollback_id\":\"RB-live-active\"") != null);
}
