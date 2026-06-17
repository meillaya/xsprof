const std = @import("std");
const linux = @import("linux_scheduler");
pub const actions = @import("actions.zig");
const args = @import("args.zig");
pub const daemon_adapter = @import("daemon_adapter.zig");
const fixture = @import("fixture.zig");
pub const interaction = @import("interaction.zig");
const layout = @import("layout.zig");
const ui_model = @import("model.zig");
const render = @import("render.zig");
const screens = @import("screens.zig");

const line = layout.line;
const row = layout.row;
const countRows = layout.countRows;

pub const Screen = args.Screen;
pub const Options = args.Options;
pub const OperatorAction = linux.control.protocol.OperatorAction;
pub const parseArgs = args.parse;

pub fn renderSnapshot(allocator: std.mem.Allocator, options: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    if (options.fixture_path) |path| {
        var parsed = try fixture.load(allocator, path);
        defer parsed.deinit();
        try renderFrame(&writer.writer, options, fixture.model(parsed.value), "");
    } else {
        var report = try linux.collectPreflight(allocator);
        defer report.deinit();
        try renderFrame(&writer.writer, options, ui_model.live(report), "");
    }

    out = writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

pub fn renderInteractive(
    allocator: std.mem.Allocator,
    options: Options,
    action: ?linux.control.protocol.OperatorAction,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    if (options.fixture_path) |path| {
        var parsed = try fixture.load(allocator, path);
        defer parsed.deinit();
        try renderFrame(&writer.writer, options, fixture.model(parsed.value), interaction.statusForAction(action));
    } else {
        var report = try linux.collectPreflight(allocator);
        defer report.deinit();
        try renderFrame(&writer.writer, options, ui_model.live(report), interaction.statusForAction(action));
    }
    out = writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

pub fn renderInteractiveStatus(
    allocator: std.mem.Allocator,
    options: Options,
    action_status: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    if (options.fixture_path) |path| {
        var parsed = try fixture.load(allocator, path);
        defer parsed.deinit();
        try renderFrame(&writer.writer, options, fixture.model(parsed.value), action_status);
    } else {
        var report = try linux.collectPreflight(allocator);
        defer report.deinit();
        try renderFrame(&writer.writer, options, ui_model.live(report), action_status);
    }
    out = writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

pub fn interactiveActionForKey(key: u8) ?linux.control.protocol.OperatorAction {
    return interaction.actionForKey(key);
}

fn renderFrame(writer: anytype, options: Options, model: fixture.SnapshotModel, action_status: []const u8) !void {
    const width = @max(options.width, 80);
    const mode_label = if (options.interactive) "INTERACTIVE test queue" else if (model.fixture_warning.len == 0) "SNAPSHOT read-only" else "FIXTURE read-only";
    try line(writer, width, "╭", "─", "╮");
    try render.renderHeader(writer, width, args.screenTitle(options.screen), mode_label);
    try line(writer, width, "├", "─", "┤");
    if (model.fixture_warning.len != 0) try row(writer, width, "fixture warning", model.fixture_warning, "read-only evidence");
    switch (options.screen) {
        .preflight => try screens.renderPreflight(writer, width, model),
        .sched_ext => {
            try render.renderPane(writer, width, "vm lab lifecycle", "events", "counters");
            try screens.renderSchedExt(writer, width, model);
        },
        .vm_lab => try screens.renderVmLab(writer, width, model),
        .controller => try screens.renderController(writer, width, model),
        .observer => try screens.renderObserver(writer, width, model),
        .help => try screens.renderHelp(writer, width),
    }
    while (countRows(writer.buffered()) + @as(usize, if (action_status.len == 0) 3 else 4) < options.height) {
        try row(writer, width, "", "", "");
    }
    try line(writer, width, "├", "─", "┤");
    if (action_status.len != 0) try row(writer, width, action_status, "typed only", "no shell execution");
    try render.renderStatusBar(writer, width, "");
    try line(writer, width, "╰", "─", "╯");
}

pub const writeUsage = args.writeUsage;

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

test "operator_tui_uses_simulator_family_header_footer" {
    const frame = try renderSnapshot(std.testing.allocator, .{
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
    const frame = try renderSnapshot(std.testing.allocator, .{
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
    const frame = try renderSnapshot(std.testing.allocator, .{
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
    const frame = try renderInteractiveStatus(std.testing.allocator, .{
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

test "screen parsing and Linux labels stay simulator-free" {
    const options = try parseArgs(&.{ "--snapshot", "--screen", "sched-ext", "--width", "100", "--height", "30" });
    try std.testing.expectEqual(Screen.sched_ext, options.screen);
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--snapshot", "--screen", "explorer" }));
}

test "snapshot honors requested 30 row height" {
    const frame = try renderSnapshot(std.testing.allocator, .{ .snapshot = true, .screen = .preflight, .width = 100, .height = 30 });
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(@as(usize, 30), countRows(frame));
    try std.testing.expect(std.mem.indexOf(u8, frame, "completion_order") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Task Metrics") == null);
}

test "fixture snapshots cover root screens without simulator labels" {
    const screen_names = [_][]const u8{ "preflight", "sched-ext", "vm-lab", "controller", "observer", "help" };
    for (screen_names) |screen| {
        const options = try parseArgs(&.{ "--snapshot", "--fixture", "fixtures/lab/preflight-ready.json", "--screen", screen, "--width", "100", "--height", "30" });
        const frame = try renderSnapshot(std.testing.allocator, options);
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
    const options = try parseArgs(&.{ "--snapshot", "--fixture", "fixtures/lab/rollback-summary.json", "--screen", "sched-ext", "--width", "100", "--height", "30" });
    const frame = try renderSnapshot(std.testing.allocator, options);
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
    const options = try parseArgs(&.{ "--snapshot", "--fixture", "fixtures/lab/run-all-summary.json", "--screen", "sched-ext", "--width", "100", "--height", "30" });
    const frame = try renderSnapshot(std.testing.allocator, options);
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
    const options = try parseArgs(&.{ "--snapshot", "--fixture", "fixtures/lab/run-all-vm-live-summary.json", "--screen", "sched-ext", "--width", "100", "--height", "30" });
    const frame = try renderSnapshot(std.testing.allocator, options);
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
        const frame = try renderSnapshot(std.testing.allocator, .{
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
    const frame = try renderSnapshot(std.testing.allocator, .{
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
    const frame = try renderSnapshot(std.testing.allocator, .{
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
        const frame = try renderSnapshot(std.testing.allocator, .{
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
    var control_state = interaction.ControlState{};
    const missing = interaction.controlForKey('b', &control_state, true).?;
    try std.testing.expectEqualStrings("rollback refused missing audit/rollback id", missing.status);
    const arm = interaction.controlForKey('m', &control_state, true).?;
    try std.testing.expectEqual(OperatorAction{
        .kind = .run_lab_microvm_live,
        .action_id = "tui-vm-lab",
        .run_id = "tui-vm-lab",
        .audit_id = "AUD-tui-vm-lab",
        .rollback_id = "RB-tui-vm-lab",
    }, arm.action);
    const confirm = interaction.controlForKey('b', &control_state, true).?;
    try std.testing.expectEqualStrings("CONFIRM rollback press b again", confirm.status);
    const rollback = interaction.controlForKey('b', &control_state, true).?;
    try std.testing.expectEqualStrings("tui-vm-lab", rollback.action.target_action_id);
    try std.testing.expectEqualStrings("RB-tui-vm-lab", rollback.action.rollback_id);
}

test "interactive TUI action module tests are linked" {
    std.testing.refAllDecls(actions);
    std.testing.refAllDecls(interaction);
    std.testing.refAllDecls(daemon_adapter);
    std.testing.refAllDecls(render);
}
