const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");

const OperatorAction = root.OperatorAction;
const countRows = layout.countRows;

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

test "vm-live operator model renders failed stale and rollback-done states safely" {
    const cases = [_]struct {
        fixture_path: []const u8,
        expected: []const []const u8,
    }{
        .{
            .fixture_path = "fixtures/lab/run-all-vm-live-failed-boot.json",
            .expected = &.{ "microvm_boot", "unsafe_to_assume", "failed-boot", "cleanup receipt PASS", "closed" },
        },
        .{
            .fixture_path = "fixtures/lab/run-all-vm-live-stale-bundle.json",
            .expected = &.{ "validation", "unsafe_to_assume", "stale", "closed_stale_bundle", "cleanup receipt PASS but" },
        },
        .{
            .fixture_path = "fixtures/lab/run-all-vm-live-rollback-done.json",
            .expected = &.{ "rollback_done", "none after rollback", "RB-rollback-done", "cleanup receipt PASS" },
        },
    };
    for (cases) |case| {
        const frame = try root.renderSnapshot(std.testing.allocator, .{
            .snapshot = true,
            .screen = .sched_ext,
            .width = 120,
            .height = 30,
            .fixture_path = case.fixture_path,
        });
        defer std.testing.allocator.free(frame);
        try std.testing.expectEqual(@as(usize, 30), countRows(frame));
        try std.testing.expect(layout.maxLineCells(frame) <= 120);
        try expectContains(frame, "lab-only vm guest");
        try expectContains(frame, "bundle path");
        try expectContains(frame, "cleanup status");
        for (case.expected) |label| try expectContains(frame, label);
        try expectNotContains(frame, "production");
        try expectNotContains(frame, "Task Metrics");
        try expectNotContains(frame, "policy [FCFS]");
    }
}

test "vm-live lifecycle fields survive narrow supported width" {
    const frame = try root.renderSnapshot(std.testing.allocator, .{
        .snapshot = true,
        .screen = .sched_ext,
        .width = 80,
        .height = 30,
        .fixture_path = "fixtures/lab/run-all-vm-live-summary.json",
    });
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(@as(usize, 30), countRows(frame));
    try std.testing.expect(layout.maxLineCells(frame) <= 80);
    for ([_][]const u8{
        "vm-live",
        "zigsched_minimal",
        "runtime samples",
        "rollback ready/completed",
        "release eligible",
    }) |label| {
        try std.testing.expect(std.mem.indexOf(u8, frame, label) != null);
    }
}

test "vm-lab screen renders lifecycle lanes counters and rollback ledger" {
    const frame = try root.renderSnapshot(std.testing.allocator, .{
        .snapshot = true,
        .screen = .vm_lab,
        .width = 165,
        .height = 48,
        .fixture_path = "fixtures/lab/run-all-vm-live-summary.json",
    });
    defer std.testing.allocator.free(frame);

    try std.testing.expectEqual(@as(usize, 48), countRows(frame));
    try std.testing.expect(layout.maxLineCells(frame) <= 165);
    for ([_][]const u8{
        "lifecycle lanes",
        "preflight build boot",
        "marker verifier attach",
        "observe rollback audit cleanup",
        "runtime counters",
        "zigsched_minimal",
        "runtime samples x3",
        "rollback ready/completed",
        "lab-only vm guest",
        "cleanup receipt PASS",
        "AUD-vmlive-ui",
        "microvm-live-tui-demo",
    }) |label| try expectContains(frame, label);
    try expectNotContains(frame, "Task Metrics");
    try expectNotContains(frame, "completion_order");
    try expectNotContains(frame, "policy [FCFS]");
}

test "CJK lifecycle fixture stays within requested terminal widths" {
    for ([_]u16{ 80, 100, 120 }) |width| {
        const frame = try root.renderSnapshot(std.testing.allocator, .{
            .snapshot = true,
            .screen = .sched_ext,
            .width = width,
            .height = 30,
            .fixture_path = "fixtures/lab/run-all-summary-cjk.json",
        });
        defer std.testing.allocator.free(frame);
        try std.testing.expectEqual(@as(usize, 30), countRows(frame));
        try std.testing.expect(layout.maxLineCells(frame) <= width);
        try std.testing.expect(std.unicode.utf8ValidateSlice(frame));
    }
}
test "interactive TUI control state maps rollback key with confirmation" {
    var control_state = root.interaction.ControlState{};
    const missing = root.interaction.controlForKey('b', &control_state, true).?;
    try std.testing.expectEqualStrings("rollback refused missing audit/rollback id", missing.status);
    const arm = root.interaction.controlForKey('m', &control_state, true).?;
    try std.testing.expectEqual(OperatorAction{
        .kind = .run_lab_microvm_live,
        .action_id = "tui-vm-lab",
        .run_id = "tui-vm-lab",
        .audit_id = "AUD-tui-vm-lab",
        .rollback_id = "RB-tui-vm-lab",
    }, arm.action);
    const confirm = root.interaction.controlForKey('b', &control_state, true).?;
    try std.testing.expectEqualStrings("CONFIRM rollback press b again", confirm.status);
    const rollback = root.interaction.controlForKey('b', &control_state, true).?;
    try std.testing.expectEqualStrings("tui-vm-lab", rollback.action.target_action_id);
    try std.testing.expectEqualStrings("RB-tui-vm-lab", rollback.action.rollback_id);
}

test "interactive TUI action module tests are linked" {
    std.testing.refAllDecls(root.actions);
    std.testing.refAllDecls(root.interaction);
    std.testing.refAllDecls(root.daemon_adapter);
    std.testing.refAllDecls(@import("render.zig"));
}
