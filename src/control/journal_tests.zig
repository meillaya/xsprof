const std = @import("std");
const journal = @import("journal.zig");

const Tracker = journal.Tracker;

test "daemon journal tracker rejects duplicate action ids" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    try tracker.remember(std.testing.allocator, "act-1");
    try std.testing.expectError(error.DuplicateActionId, tracker.remember(std.testing.allocator, "act-1"));
    try std.testing.expectError(error.InvalidActionId, tracker.remember(std.testing.allocator, "bad id"));
}

test "daemon journal tracker loads existing action ids" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"journal_record\",\"status\":\"accepted\",\"action_id\":\"act-1\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"journal_record\",\"status\":\"accepted\",\"action_id\":\"act-2\",\"host_mutation\":false}\n";
    const loaded = try tracker.loadExisting(std.testing.allocator, raw);
    try std.testing.expectEqual(@as(usize, 2), loaded.count);
    try std.testing.expectEqual(@as(usize, 3), loaded.next_seq);
    try std.testing.expectError(error.DuplicateActionId, tracker.remember(std.testing.allocator, "act-2"));
}

test "daemon journal tracker rejects nonmonotonic existing sequence" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":99,\"event\":\"journal_record\",\"status\":\"accepted\",\"action_id\":\"act-1\",\"host_mutation\":false}\n";
    try std.testing.expectError(error.InvalidJournal, tracker.loadExisting(std.testing.allocator, raw));
}

test "daemon journal tracker refuses duplicate active target ids" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidActionId, tracker.recordLab(std.testing.allocator, "act-empty", "", "RB-empty", "evidence/lab/empty"));
    try tracker.recordLab(std.testing.allocator, "act-1", "target-1", "RB-1", "evidence/lab/one");
    try std.testing.expect(tracker.activeTarget("target-1"));
    try std.testing.expectError(error.DuplicateTargetId, tracker.recordLab(std.testing.allocator, "act-2", "target-1", "RB-2", "evidence/lab/two"));
    try tracker.markRolledBack(std.testing.allocator, "act-1", "evidence/lab/one/rolled-back");
    try tracker.recordLab(std.testing.allocator, "act-2", "target-1", "RB-2", "evidence/lab/two");
}

test "daemon journal replay marks lifecycle rollback cleanup deterministically" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"lab_run_active\",\"action_id\":\"act-live\",\"target_id\":\"target-live\",\"rollback_id\":\"RB-live\",\"artifact\":\"evidence/lab/live\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"rollback\",\"action_id\":\"act-live\",\"target_id\":\"target-live\",\"rollback_id\":\"RB-live\",\"artifact\":\"evidence/lab/live/audit-ledger.jsonl\",\"state\":\"rolled_back\",\"status\":\"PASS\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":3,\"event\":\"cleanup\",\"action_id\":\"act-live\",\"target_id\":\"target-live\",\"rollback_id\":\"RB-live\",\"artifact\":\"evidence/lab/live/summary.json\",\"state\":\"clean\",\"status\":\"PASS\",\"host_mutation\":false}\n";
    const loaded = try tracker.loadExisting(std.testing.allocator, raw);
    try std.testing.expectEqual(@as(usize, 3), loaded.count);
    try std.testing.expectEqual(@as(usize, 4), loaded.next_seq);
    try std.testing.expect(!tracker.activeTarget("target-live"));
}

test "daemon journal replay marks stop cleanup controls deterministically" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"lab_run_active\",\"action_id\":\"act-live\",\"target_id\":\"target-live\",\"rollback_id\":\"RB-live\",\"artifact\":\"evidence/lab/live\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"cleanup\",\"action_id\":\"stop-live\",\"target_action_id\":\"act-live\",\"target_id\":\"\",\"rollback_id\":\"RB-live\",\"artifact\":\"evidence/lab/live\",\"state\":\"clean\",\"status\":\"PASS\",\"host_mutation\":false}\n";
    const loaded = try tracker.loadExisting(std.testing.allocator, raw);
    try std.testing.expectEqual(@as(usize, 2), loaded.count);
    try std.testing.expectEqual(@as(usize, 3), loaded.next_seq);
    try std.testing.expect(!tracker.activeTarget("target-live"));
}

test "daemon journal replay failed rollback and cleanup keep target active" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"lab_run_active\",\"action_id\":\"act-live\",\"target_id\":\"target-live\",\"rollback_id\":\"RB-live\",\"artifact\":\"evidence/lab/live\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"rollback\",\"action_id\":\"act-live\",\"target_id\":\"target-live\",\"rollback_id\":\"RB-live\",\"artifact\":\"evidence/lab/live/audit-ledger.jsonl\",\"state\":\"incident\",\"status\":\"FAIL\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":3,\"event\":\"cleanup\",\"action_id\":\"act-live\",\"target_id\":\"target-live\",\"rollback_id\":\"RB-live\",\"artifact\":\"evidence/lab/live/summary.json\",\"state\":\"incident\",\"status\":\"FAIL\",\"host_mutation\":false}\n";
    _ = try tracker.loadExisting(std.testing.allocator, raw);
    try std.testing.expect(tracker.activeTarget("target-live"));
    try std.testing.expectError(error.DuplicateTargetId, tracker.recordLab(std.testing.allocator, "act-new", "target-live", "RB-new", "evidence/lab/new"));
}
