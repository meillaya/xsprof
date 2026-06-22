const std = @import("std");
const live_summary = @import("live_summary.zig");
const protocol = @import("../protocol.zig");

const appendRunnerLifecycleLine = live_summary.appendRunnerLifecycleLine;

test "live microvm runner refusal reason stays explicit in lifecycle stream" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    const action = protocol.OperatorAction{ .kind = .run_lab_microvm_live, .action_id = "live-refusal", .run_id = "live-refusal" };

    try std.testing.expect(try appendRunnerLifecycleLine(std.testing.allocator, &output, &seq, action,
        \\ZIGSCHED_DAEMON_EVENT {"event":"stage_finished","status":"REFUSE","state":"refused_host","reason":"microvm_runner_refused","artifact":"evidence/lab/live"}
    ));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"reason\":\"microvm_runner_refused\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"host_mutation\":false") != null);
}
