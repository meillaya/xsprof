const std = @import("std");
const linux = @import("linux_scheduler");
pub const actions = @import("actions.zig");
const args = @import("args.zig");
pub const daemon_adapter = @import("daemon_adapter.zig");
pub const daemon_model = @import("daemon_model.zig");
const fixture = @import("fixture.zig");
pub const interaction = @import("interaction.zig");
const layout = @import("layout.zig");
pub const live_store = @import("live_store.zig");
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

fn interactiveAnsiFrame(allocator: std.mem.Allocator, plain: []const u8) ![]u8 {
    return render.renderInteractiveAnsi(allocator, plain);
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
    const plain = try out.toOwnedSlice(allocator);
    defer allocator.free(plain);
    return interactiveAnsiFrame(allocator, plain);
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
    const plain = try out.toOwnedSlice(allocator);
    defer allocator.free(plain);
    return interactiveAnsiFrame(allocator, plain);
}

pub fn renderInteractiveDaemonOutput(
    allocator: std.mem.Allocator,
    options: Options,
    raw_events: []const u8,
    action_status: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    var render_options = options;
    render_options.screen = .vm_lab;
    const model = daemon_model.modelFromDaemonOutput(allocator, raw_events, action_status);
    try renderFrame(&writer.writer, render_options, model, action_status);
    out = writer.toArrayList();
    const plain = try out.toOwnedSlice(allocator);
    defer allocator.free(plain);
    return interactiveAnsiFrame(allocator, plain);
}

pub fn renderInteractiveLiveStore(
    allocator: std.mem.Allocator,
    options: Options,
    store: *const live_store.Store,
    action_status: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    var render_options = options;
    render_options.screen = .vm_lab;
    try renderFrame(&writer.writer, render_options, store.toModel(), action_status);
    out = writer.toArrayList();
    const plain = try out.toOwnedSlice(allocator);
    defer allocator.free(plain);
    return interactiveAnsiFrame(allocator, plain);
}

pub fn renderInteractiveDaemonQueued(
    allocator: std.mem.Allocator,
    options: Options,
    action_status: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    var render_options = options;
    render_options.screen = .vm_lab;
    try renderFrame(&writer.writer, render_options, daemon_model.queuedModel(action_status), action_status);
    out = writer.toArrayList();
    const plain = try out.toOwnedSlice(allocator);
    defer allocator.free(plain);
    return interactiveAnsiFrame(allocator, plain);
}

pub fn interactiveActionForKey(key: u8) ?linux.control.protocol.OperatorAction {
    return interaction.actionForKey(key);
}

fn renderFrame(writer: anytype, options: Options, model: fixture.SnapshotModel, action_status: []const u8) !void {
    const width = @max(options.width, 80);
    const mode_label = if (options.interactive and model.footer_mode.len != 0) model.footer_mode else if (options.interactive) "INTERACTIVE test queue" else if (model.fixture_warning.len == 0) "SNAPSHOT read-only" else "FIXTURE read-only";
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
    if (action_status.len != 0) try row(writer, width, action_status, "typed only", "host unchanged");
    const footer_status = if (options.interactive and action_status.len == 0) model.footer_mode else action_status;
    try render.renderStatusBar(writer, width, footer_status);
    try line(writer, width, "╰", "─", "╯");
}

pub const writeUsage = args.writeUsage;

test "root TUI behavior tests are linked" {
    std.testing.refAllDecls(@import("root_tests.zig"));
}
