const std = @import("std");
const linux = @import("linux_scheduler");
const fixture = @import("fixture.zig");
pub const interaction = @import("interaction.zig");
const layout = @import("layout.zig");
const screens = @import("screens.zig");

const line = layout.line;
const row = layout.row;
const countRows = layout.countRows;

pub const Screen = enum { preflight, sched_ext, controller, observer, help };
pub const Options = struct {
    snapshot: bool = false,
    interactive: bool = false,
    test_mode: bool = false,
    screen: Screen = .preflight,
    width: u16 = 100,
    height: u16 = 30,
    fixture_path: ?[]const u8 = null,
};

pub fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--snapshot")) {
            options.snapshot = true;
        } else if (std.mem.eql(u8, arg, "--interactive")) {
            options.interactive = true;
        } else if (std.mem.eql(u8, arg, "--test-mode")) {
            options.test_mode = true;
        } else if (std.mem.eql(u8, arg, "--screen")) {
            options.screen = try parseScreen(try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--width")) {
            options.width = try parseDimension(try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--height")) {
            options.height = try parseDimension(try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--fixture")) {
            options.fixture_path = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--help")) {
            return error.InvalidArguments;
        } else {
            return error.InvalidArguments;
        }
    }
    if (options.snapshot == options.interactive) return error.InvalidArguments;
    if (options.test_mode and !options.interactive) return error.InvalidArguments;
    if (options.width < 80 or options.height < 8) return error.InvalidArguments;
    return options;
}

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
        try renderFrame(&writer.writer, options, liveModel(report), "");
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
        try renderFrame(&writer.writer, options, liveModel(report), interaction.statusForAction(action));
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
    try row(writer, width, "▚ Linux Scheduler Operator", screenTitle(options.screen), mode_label);
    try line(writer, width, "├", "─", "┤");
    if (model.fixture_warning.len != 0) try row(writer, width, "fixture warning", model.fixture_warning, "read-only evidence");
    switch (options.screen) {
        .preflight => try screens.renderPreflight(writer, width, model),
        .sched_ext => try screens.renderSchedExt(writer, width, model),
        .controller => try screens.renderController(writer, width),
        .observer => try screens.renderObserver(writer, width),
        .help => try screens.renderHelp(writer, width),
    }
    while (countRows(writer.buffered()) + @as(usize, if (action_status.len == 0) 3 else 4) < options.height) {
        try row(writer, width, "", "", "");
    }
    try line(writer, width, "├", "─", "┤");
    if (action_status.len != 0) try row(writer, width, action_status, "typed only", "no shell execution");
    try row(writer, width, "q quit  ? help  h home  w theme", "FAIL-CLOSED", "refuse mutation/load");
    try line(writer, width, "╰", "─", "╯");
}

pub fn writeUsage(writer: anytype, exe_name: []const u8) !void {
    try writer.print("usage: {s} (--snapshot|--interactive [--test-mode]) [--fixture <preflight.json>] --screen preflight|sched-ext|controller|observer|help [--width <cols>] [--height <rows>]\n", .{exe_name});
}

fn liveModel(report: linux.PreflightReport) fixture.SnapshotModel {
    return .{
        .kernel_release = report.kernel_release,
        .arch = report.arch,
        .cgroup_status = @tagName(report.cgroup_v2.status),
        .cgroup_controllers = report.cgroup_v2.controllers,
        .capabilities = report.capabilities.effective_hex,
        .sched_state = factText(report.sched_ext.state),
        .sched_enable_seq = factText(report.sched_ext.enable_seq),
        .sched_switch_all = factText(report.sched_ext.switch_all),
        .sched_nr_rejected = factText(report.sched_ext.nr_rejected),
        .btf_status = @tagName(report.btf.status),
    };
}

fn parseScreen(raw: []const u8) !Screen {
    if (std.mem.eql(u8, raw, "preflight")) return .preflight;
    if (std.mem.eql(u8, raw, "sched-ext")) return .sched_ext;
    if (std.mem.eql(u8, raw, "controller")) return .controller;
    if (std.mem.eql(u8, raw, "observer")) return .observer;
    if (std.mem.eql(u8, raw, "help")) return .help;
    return error.InvalidArguments;
}

fn nextArg(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

fn parseDimension(raw: []const u8) !u16 {
    const value = std.fmt.parseUnsigned(u16, raw, 10) catch return error.InvalidArguments;
    if (value == 0) return error.InvalidArguments;
    return value;
}

fn screenTitle(screen: Screen) []const u8 {
    return switch (screen) {
        .preflight => "Home / Preflight",
        .sched_ext => "sched_ext Readiness",
        .controller => "Controller Dry Run",
        .observer => "Observer",
        .help => "Help",
    };
}

fn factText(fact: linux.sched_ext.TextFact) []const u8 {
    if (fact.value.len == 0) return @tagName(fact.status);
    return fact.value;
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
    const screen_names = [_][]const u8{ "preflight", "sched-ext", "controller", "observer", "help" };
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
        "rollback",
        "DSQ",
        "stress",
        "audit",
        "release",
        "fixture",
        "skipped_no_vm",
    }) |label| {
        try std.testing.expect(std.mem.indexOf(u8, frame, label) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, frame, "Task Metrics") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "completion_order") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "production") == null);
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

test "interactive TUI action module tests are linked" {
    std.testing.refAllDecls(interaction);
}
