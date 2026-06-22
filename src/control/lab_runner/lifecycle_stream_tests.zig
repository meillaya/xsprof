const std = @import("std");
const lifecycle_stream = @import("lifecycle_stream.zig");
const protocol = @import("../protocol.zig");

const appendRunnerLifecycleLine = lifecycle_stream.appendRunnerLifecycleLine;

test "live microvm runner refusal reason stays explicit in lifecycle stream" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    const action = protocol.OperatorAction{ .kind = .run_lab_microvm_live, .action_id = "live-refusal", .run_id = "live-refusal" };

    const line = try appendRunnerLifecycleLine(std.testing.allocator, &output, &seq, action,
        \\ZIGSCHED_DAEMON_EVENT {"event":"stage_finished","status":"REFUSE","state":"refused_host","reason":"microvm_runner_refused","artifact":"evidence/lab/live"}
    );
    try std.testing.expectEqual(lifecycle_stream.RunnerLifecycleKind.other, line.kind);
    try std.testing.expect(line.incident_terminal);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"reason\":\"microvm_runner_refused\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"host_mutation\":false") != null);
}

test "live microvm runner classifies rollback cleanup and ignores ordinary stdout" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    const action = protocol.OperatorAction{ .kind = .run_lab_microvm_live, .action_id = "live-classify", .run_id = "live-classify" };

    const ignored = try appendRunnerLifecycleLine(std.testing.allocator, &output, &seq, action, "PASS ordinary runner stdout");
    try std.testing.expectEqual(lifecycle_stream.RunnerLifecycleKind.ignored, ignored.kind);
    const rollback = try appendRunnerLifecycleLine(std.testing.allocator, &output, &seq, action,
        \\ZIGSCHED_DAEMON_EVENT {"event":"rollback","status":"PASS","state":"rolled_back","reason":"rollback complete","artifact":"evidence/lab/live/audit-ledger.jsonl"}
    );
    try std.testing.expectEqual(lifecycle_stream.RunnerLifecycleKind.rollback, rollback.kind);
    try std.testing.expect(rollback.clears_active);
    const cleanup = try appendRunnerLifecycleLine(std.testing.allocator, &output, &seq, action,
        \\ZIGSCHED_DAEMON_EVENT {"event":"cleanup","status":"PASS","state":"clean","reason":"cleanup complete","artifact":"evidence/lab/live/summary.json"}
    );
    try std.testing.expectEqual(lifecycle_stream.RunnerLifecycleKind.cleanup, cleanup.kind);
    try std.testing.expect(cleanup.clears_active);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"rollback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"cleanup\"") != null);
}

test "failed rollback cleanup lifecycle rows do not clear active target" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    const action = protocol.OperatorAction{ .kind = .run_lab_microvm_live, .action_id = "live-failed", .run_id = "live-failed" };

    const rollback = try appendRunnerLifecycleLine(std.testing.allocator, &output, &seq, action,
        \\ZIGSCHED_DAEMON_EVENT {"event":"rollback","status":"FAIL","state":"incident","reason":"rollback failed","artifact":"evidence/lab/live/audit-ledger.jsonl"}
    );
    try std.testing.expectEqual(lifecycle_stream.RunnerLifecycleKind.rollback, rollback.kind);
    try std.testing.expect(!rollback.clears_active);
    try std.testing.expect(rollback.incident_terminal);

    const cleanup = try appendRunnerLifecycleLine(std.testing.allocator, &output, &seq, action,
        \\ZIGSCHED_DAEMON_EVENT {"event":"cleanup","status":"FAIL","state":"incident","reason":"cleanup failed","artifact":"evidence/lab/live/summary.json"}
    );
    try std.testing.expectEqual(lifecycle_stream.RunnerLifecycleKind.cleanup, cleanup.kind);
    try std.testing.expect(!cleanup.clears_active);
    try std.testing.expect(cleanup.incident_terminal);
}
