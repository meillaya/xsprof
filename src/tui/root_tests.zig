const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");

const Screen = root.Screen;
const OperatorAction = root.OperatorAction;
const countRows = layout.countRows;

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

test "operator_tui_uses_simulator_family_header_footer" {
    const frame = try root.renderSnapshot(std.testing.allocator, .{
        .snapshot = true,
        .screen = .sched_ext,
        .width = 120,
        .height = 30,
        .fixture_path = "fixtures/lab/run-all-vm-live-summary.json",
    });
    defer std.testing.allocator.free(frame);

    try std.testing.expectEqual(@as(usize, 30), countRows(frame));
    try std.testing.expect(layout.maxLineCells(frame) <= 120);
    try expectContains(frame, "▚ zig-scheduler");
    try expectContains(frame, "NORMAL");
    try expectContains(frame, "↵");
    try expectContains(frame, "FAIL-CLOSED");
    try expectContains(frame, "q");
}

test "operator_tui_has_dense_panes_without_simulator_semantics" {
    const frame = try root.renderSnapshot(std.testing.allocator, .{
        .snapshot = true,
        .screen = .sched_ext,
        .width = 120,
        .height = 30,
        .fixture_path = "fixtures/lab/run-all-vm-live-summary.json",
    });
    defer std.testing.allocator.free(frame);

    try expectContains(frame, "vm lab");
    try expectContains(frame, "lifecycle");
    try expectContains(frame, "events");
    try expectContains(frame, "counters");
    try expectNotContains(frame, "│ sched_ext Readiness                │                          │ Fallback Drill");
    try expectNotContains(frame, "Task Metrics");
    try expectNotContains(frame, "completion_order");
    try expectNotContains(frame, "Gantt");
    try expectNotContains(frame, "scenario arrivals");
    try expectNotContains(frame, "policy [FCFS]");
}

test "operator dashboard home uses simulator family density without simulator semantics" {
    const frame = try root.renderSnapshot(std.testing.allocator, .{
        .snapshot = true,
        .screen = .preflight,
        .width = 165,
        .height = 48,
        .fixture_path = "fixtures/lab/run-all-vm-live-summary.json",
    });
    defer std.testing.allocator.free(frame);

    try std.testing.expectEqual(@as(usize, 48), countRows(frame));
    try std.testing.expect(layout.maxLineCells(frame) <= 165);
    for ([_][]const u8{
        "operator dashboard home",
        "dashboard home",
        "choose a flow",
        "sched_ext readiness",
        "live microVM lab",
        "rollback / audit",
        "operator sources",
        "start here",
        "recent evidence",
        "FAIL-CLOSED",
    }) |label| try expectContains(frame, label);
    try expectNotContains(frame, "Task Metrics");
    try expectNotContains(frame, "completion_order");
    try expectNotContains(frame, "Gantt");
    try expectNotContains(frame, "scenario arrivals");
    try expectNotContains(frame, "policy [FCFS]");
}

test "operator_tui_footer_exposes_lab_controls_once" {
    const frame = try root.renderInteractiveStatus(std.testing.allocator, .{
        .interactive = true,
        .test_mode = true,
        .screen = .sched_ext,
        .width = 120,
        .height = 30,
        .fixture_path = "fixtures/lab/run-all-vm-live-summary.json",
    }, "ACTION idle typed queue empty");
    defer std.testing.allocator.free(frame);

    try expectContains(frame, "m live vm");
    try expectContains(frame, "b rollback");
    try expectContains(frame, "s stop");
    try expectContains(frame, "? help");
    try expectContains(frame, "h home");
    try expectContains(frame, "w theme");
}

test "operator_tui_interactive_ansi_uses_semantic_palette" {
    const frame = try root.renderInteractiveStatus(std.testing.allocator, .{
        .interactive = true,
        .test_mode = true,
        .screen = .sched_ext,
        .width = 120,
        .height = 30,
        .fixture_path = "fixtures/lab/run-all-vm-live-summary.json",
    }, "ACTION idle typed queue empty");
    defer std.testing.allocator.free(frame);

    for ([_][]const u8{
        "\x1b[48;5;16m",
        "\x1b[38;5;45m",
        "\x1b[38;5;220m",
        "\x1b[38;5;114m",
        "\x1b[38;5;205m",
        "\x1b[38;5;242m",
    }) |code| try expectContains(frame, code);
    try expectContains(frame, "cleanup receipt PASS");
    try expectContains(frame, "unsafe_to_assume");
    try expectContains(frame, "FAIL-CLOSED");
}

test "screen parsing and Linux labels stay simulator-free" {
    const options = try root.parseArgs(&.{ "--snapshot", "--screen", "sched-ext", "--width", "100", "--height", "30" });
    try std.testing.expectEqual(Screen.sched_ext, options.screen);
    try std.testing.expectError(error.InvalidArguments, root.parseArgs(&.{ "--snapshot", "--screen", "explorer" }));
}

test "snapshot honors requested 30 row height" {
    const frame = try root.renderSnapshot(std.testing.allocator, .{ .snapshot = true, .screen = .preflight, .width = 100, .height = 30 });
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(@as(usize, 30), countRows(frame));
    try std.testing.expect(std.mem.indexOf(u8, frame, "completion_order") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Task Metrics") == null);
}

test "fixture snapshots cover root screens without simulator labels" {
    const screen_names = [_][]const u8{ "preflight", "sched-ext", "vm-lab", "controller", "observer", "help" };
    for (screen_names) |screen| {
        const options = try root.parseArgs(&.{ "--snapshot", "--fixture", "fixtures/lab/preflight-ready.json", "--screen", screen, "--width", "100", "--height", "30" });
        const frame = try root.renderSnapshot(std.testing.allocator, options);
        defer std.testing.allocator.free(frame);
        try std.testing.expectEqual(@as(usize, 30), countRows(frame));
        try std.testing.expect(std.mem.indexOf(u8, frame, "FIXTURE") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "FAIL-CLOSED") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "completion_order") == null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "Gantt") == null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "Task Metrics") == null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "simulator metrics") == null);
    }
}

test "rollback summary fixture renders lab lifecycle states at fixed size" {
    const options = try root.parseArgs(&.{ "--snapshot", "--fixture", "fixtures/lab/rollback-summary.json", "--screen", "sched-ext", "--width", "100", "--height", "30" });
    const frame = try root.renderSnapshot(std.testing.allocator, options);
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(@as(usize, 30), countRows(frame));
    try std.testing.expect(layout.maxLineCells(frame) <= 100);
    for ([_][]const u8{
        "read-only",
        "verifier-ready",
        "attached-partial",
        "rollback-required",
        "rejected",
        "fallback-fired",
        "partial switch",
        "FAIL-CLOSED",
    }) |label| {
        try std.testing.expect(std.mem.indexOf(u8, frame, label) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, frame, "Task Metrics") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "completion_order") == null);
}

test "run-all fixture renders lab lifecycle evidence rows" {
    const options = try root.parseArgs(&.{ "--snapshot", "--fixture", "fixtures/lab/run-all-summary.json", "--screen", "sched-ext", "--width", "100", "--height", "30" });
    const frame = try root.renderSnapshot(std.testing.allocator, options);
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(@as(usize, 30), countRows(frame));
    try std.testing.expect(layout.maxLineCells(frame) <= 100);
    for ([_][]const u8{
        "evidence mode",
        "verifier",
        "partial attach",
        "rollback status",
        "runtime samples",
        "release eligible",
        "audit id",
        "fixture",
        "skipped_no_vm",
    }) |label| {
        try std.testing.expect(std.mem.indexOf(u8, frame, label) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, frame, "Task Metrics") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "completion_order") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "production") == null);
}

test "vm-live fixture renders live lifecycle stream fields" {
    const options = try root.parseArgs(&.{ "--snapshot", "--fixture", "fixtures/lab/run-all-vm-live-summary.json", "--screen", "sched-ext", "--width", "100", "--height", "30" });
    const frame = try root.renderSnapshot(std.testing.allocator, options);
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(@as(usize, 30), countRows(frame));
    try std.testing.expect(layout.maxLineCells(frame) <= 100);
    for ([_][]const u8{
        "vm-live",
        "lab-only vm guest",
        "microvm-live-tui-demo",
        "cleanup receipt PASS",
        "zigsched_minimal",
        "runtime samples",
        "rollback ready/completed",
        "release eligible",
        "not release eligible",
        "AUD-vmlive-ui",
    }) |label| {
        try std.testing.expect(std.mem.indexOf(u8, frame, label) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, frame, "Task Metrics") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "completion_order") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "production") == null);
}

test "root live and interaction tests are linked" {
    std.testing.refAllDecls(@import("root_live_tests.zig"));
}
