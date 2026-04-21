const std = @import("std");
const scheduler = @import("zig_scheduler");
const analysis = @import("analysis_root");
const args_mod = @import("args.zig");
const term_mod = @import("terminal.zig");
const render = @import("render.zig");

pub const Options = args_mod.Options;
pub const LaunchMode = args_mod.LaunchMode;
pub const parseArgs = args_mod.parseArgs;

const ParsedReport = std.json.Parsed(analysis.model.Report);

const PickerEntry = render.PickerEntry;
const AppView = render.AppView;
const ThemeKind = render.ThemeKind;
const View = render.View;
const PaneFocus = render.PaneFocus;

const PickerSource = union(enum) {
    builtin: []const u8,
    file: []const u8,
};

const App = struct {
    allocator: std.mem.Allocator,
    current_report: ?ParsedReport = null,
    compare_report: ?ParsedReport = null,
    view: View = .picker,
    theme: ThemeKind = .dark,
    focus: PaneFocus = .gantt,
    cursor: u32 = 0,
    selected_task_index: ?usize = null,
    picker_index: usize = 0,
    playing: bool = false,
    picker_entries: []const PickerEntry,
    history: std.ArrayList([]const u8) = .empty,
    source: ?PickerSource = null,

    fn deinit(self: *App) void {
        if (self.current_report) |*parsed| parsed.deinit();
        if (self.compare_report) |*parsed| parsed.deinit();
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit(self.allocator);
    }

    fn report(self: *App) ?*const analysis.model.Report {
        if (self.current_report) |*parsed| return &parsed.value;
        return null;
    }

    fn compare(self: *App) ?*const analysis.model.Report {
        if (self.compare_report) |*parsed| return &parsed.value;
        return null;
    }

    fn selectedTaskCount(self: *App) usize {
        const current = self.report() orelse return 0;
        return current.tasks.len;
    }
};

pub fn run(allocator: std.mem.Allocator, options: Options) !void {
    var app = App{
        .allocator = allocator,
        .picker_entries = pickerEntries(),
    };
    defer app.deinit();

    try bootstrap(&app, options);

    var terminal = try term_mod.Terminal.init();
    defer terminal.deinit();

    while (true) {
        const size = terminal.size();
        const frame = try render.renderFrame(allocator, size.cols, size.rows, appView(&app));
        defer allocator.free(frame);
        try terminal.writeFrame(frame);

        const timeout: i32 = if (app.playing and app.view == .explorer) 200 else -1;
        const event = try terminal.readEvent(timeout);
        switch (event) {
            .none => if (app.playing and app.view == .explorer) advanceCursor(&app) else {},
            .char => |ch| if (try handleChar(&app, ch)) break,
            else => if (try handleEvent(&app, event)) break,
        }
    }
}

fn bootstrap(app: *App, options: Options) !void {
    switch (options.mode) {
        .picker => {
            if (std.fs.File.stdin().isTty()) {
                app.view = .picker;
                return;
            }
            const bytes = try std.fs.File.stdin().readToEndAlloc(app.allocator, std.math.maxInt(usize));
            defer app.allocator.free(bytes);
            try loadReportBytes(app, bytes);
            app.view = .explorer;
        },
        .input_file => {
            const bytes = try std.fs.cwd().readFileAlloc(app.allocator, options.input_path.?, std.math.maxInt(usize));
            defer app.allocator.free(bytes);
            try loadReportBytes(app, bytes);
            app.view = .explorer;
        },
        .stdin_report => {
            const bytes = try std.fs.File.stdin().readToEndAlloc(app.allocator, std.math.maxInt(usize));
            defer app.allocator.free(bytes);
            try loadReportBytes(app, bytes);
            app.view = .explorer;
        },
        .simulate_builtin => {
            try loadSimulation(app, .{ .builtin = options.scenario_name.? }, options.policy.?);
            app.view = .explorer;
        },
        .simulate_file => {
            try loadSimulation(app, .{ .file = options.scenario_file.? }, options.policy.?);
            app.view = .explorer;
        },
    }
}

fn appView(app: *App) AppView {
    return .{
        .theme = app.theme,
        .view = app.view,
        .focus = app.focus,
        .cursor = app.cursor,
        .selected_task_index = app.selected_task_index,
        .picker_index = app.picker_index,
        .playing = app.playing,
        .report = app.report(),
        .compare_report = app.compare(),
        .picker_entries = app.picker_entries,
        .history = app.history.items,
    };
}

fn handleEvent(app: *App, event: term_mod.Event) !bool {
    switch (event) {
        .left => moveCursor(app, -1),
        .right => moveCursor(app, 1),
        .up => try moveSelection(app, -1),
        .down => try moveSelection(app, 1),
        .home => app.cursor = 0,
        .end => {
            if (app.report()) |report| app.cursor = lastTick(report);
        },
        .enter => try handleEnter(app),
        .tab => cycleFocus(app),
        .backtab => cycleFocusReverse(app),
        .space => {
            if (app.view == .explorer) app.playing = !app.playing;
        },
        .escape => handleEscape(app),
        else => {},
    }
    return false;
}

fn handleChar(app: *App, ch: u8) !bool {
    switch (ch) {
        'q' => return true,
        'j' => try moveTask(app, 1),
        'k' => try moveTask(app, -1),
        'd' => try toggleDiff(app),
        's' => togglePicker(app),
        'w' => app.theme = if (app.theme == .dark) .light else .dark,
        '?' => app.view = if (app.view == .help) if (app.report() != null) .explorer else .picker else .help,
        'p' => if (app.view == .picker) cyclePickerPolicy(app),
        else => {},
    }
    return false;
}

fn moveCursor(app: *App, delta: i32) void {
    const report = app.report() orelse return;
    const end = lastTick(report);
    const next = @as(i32, @intCast(app.cursor)) + delta;
    if (next < 0) app.cursor = 0 else app.cursor = @min(end, @as(u32, @intCast(next)));
}

fn advanceCursor(app: *App) void {
    const report = app.report() orelse return;
    const end = lastTick(report);
    app.cursor = if (app.cursor >= end) 0 else app.cursor + 1;
}

fn moveSelection(app: *App, delta: i32) !void {
    if (app.view == .picker) {
        const len = app.picker_entries.len;
        if (len == 0) return;
        if (delta < 0) {
            app.picker_index = if (app.picker_index == 0) 0 else app.picker_index - 1;
        } else {
            app.picker_index = @min(len - 1, app.picker_index + 1);
        }
        return;
    }
    try moveTask(app, delta);
}

fn moveTask(app: *App, delta: i32) !void {
    const report = app.report() orelse return;
    if (report.tasks.len == 0) return;
    const cur = app.selected_task_index orelse 0;
    const next_signed = @as(i32, @intCast(cur)) + delta;
    const next = if (next_signed < 0) report.tasks.len - 1 else @as(usize, @intCast(next_signed)) % report.tasks.len;
    app.selected_task_index = next;
    app.focus = .tasks;
}

fn handleEnter(app: *App) !void {
    switch (app.view) {
        .picker => try openPickerSelection(app),
        .explorer => {
            if (app.selected_task_index != null) app.view = .drawer;
        },
        .drawer => {},
        .diff => {},
        .help => app.view = if (app.report() != null) .explorer else .picker,
    }
}

fn handleEscape(app: *App) void {
    switch (app.view) {
        .help => app.view = if (app.report() != null) .explorer else .picker,
        .drawer, .diff => app.view = .explorer,
        .picker => {
            if (app.report() != null) app.view = .explorer;
        },
        .explorer => app.selected_task_index = null,
    }
}

fn cycleFocus(app: *App) void {
    app.focus = switch (app.focus) {
        .gantt => .tasks,
        .tasks => .events,
        .events => .tick,
        .tick => .gantt,
    };
}

fn cycleFocusReverse(app: *App) void {
    app.focus = switch (app.focus) {
        .gantt => .tick,
        .tasks => .gantt,
        .events => .tasks,
        .tick => .events,
    };
}

fn togglePicker(app: *App) void {
    app.view = if (app.view == .picker and app.report() != null) .explorer else .picker;
    app.playing = false;
}

fn toggleDiff(app: *App) !void {
    if (app.view == .diff) {
        app.view = .explorer;
        return;
    }
    if (app.report() == null) return;
    try ensureCompareReport(app);
    if (app.compare() != null) app.view = .diff;
}

fn openPickerSelection(app: *App) !void {
    const entry = app.picker_entries[app.picker_index];
    try loadSimulation(app, .{ .file = entry.scenario_key }, entry.policy);
    app.view = .explorer;
}

fn cyclePickerPolicy(app: *App) void {
    const scenario_key = app.picker_entries[app.picker_index].scenario_key;
    const current = app.picker_entries[app.picker_index].policy;
    const order = [_]scheduler.PolicyKind{ .fcfs, .round_robin, .cfs_like, .deadline };
    var next_policy = current;
    for (order, 0..) |policy, idx| {
        if (policy == current) {
            next_policy = order[(idx + 1) % order.len];
            break;
        }
    }
    if (findPickerEntry(app.picker_entries, scenario_key, next_policy)) |index| {
        app.picker_index = index;
    }
}

fn findPickerEntry(entries: []const PickerEntry, scenario_key: []const u8, policy: scheduler.PolicyKind) ?usize {
    for (entries, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.scenario_key, scenario_key) and entry.policy == policy) return idx;
    }
    return null;
}

fn loadReportBytes(app: *App, bytes: []const u8) !void {
    if (app.current_report) |*parsed| parsed.deinit();
    app.current_report = try analysis.model.parseReport(app.allocator, bytes);
    if (app.compare_report) |*parsed| {
        parsed.deinit();
        app.compare_report = null;
    }
    app.cursor = 0;
    app.selected_task_index = if (app.current_report.?.value.tasks.len > 0) 0 else null;
    app.source = switch (app.current_report.?.value.source.kind) {
        .builtin => .{ .builtin = app.current_report.?.value.source.value },
        .file => .{ .file = app.current_report.?.value.source.value },
    };
    const label = try std.fmt.allocPrint(app.allocator, "· {s} · {s}", .{ app.current_report.?.value.scenario.name, @tagName(app.current_report.?.value.policy.kind) });
    errdefer app.allocator.free(label);
    try appendHistory(app, label);
}

fn loadSimulation(app: *App, source: PickerSource, policy: scheduler.PolicyKind) !void {
    var scenario = try switch (source) {
        .builtin => |name| scheduler.loadScenarioByName(app.allocator, name),
        .file => |path| scheduler.loadScenarioFile(app.allocator, path),
    };
    defer scenario.deinit();

    var result = try scheduler.simulate(app.allocator, &scenario, policy);
    defer result.deinit();

    const source_info: scheduler.cli.SourceInfo = switch (source) {
        .builtin => |name| .{ .kind = .builtin, .value = name },
        .file => |path| .{ .kind = .file, .value = path },
    };
    const report = scheduler.cli.SimulationReport.init(source_info, &scenario, &result);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(app.allocator);
    var writer = buffer.writer(app.allocator);
    try scheduler.cli.writeJsonReport(&writer, report);

    try loadReportBytes(app, buffer.items);
    app.source = source;
}

fn ensureCompareReport(app: *App) !void {
    if (app.compare_report != null) return;
    const report = app.report() orelse return;
    const compare_policy = switch (report.policy.kind) {
        .fcfs => scheduler.PolicyKind.round_robin,
        .round_robin => scheduler.PolicyKind.fcfs,
        .cfs_like => scheduler.PolicyKind.fcfs,
        .deadline => scheduler.PolicyKind.fcfs,
    };
    const source = app.source orelse return;

    var scenario = try switch (source) {
        .builtin => |name| scheduler.loadScenarioByName(app.allocator, name),
        .file => |path| scheduler.loadScenarioFile(app.allocator, path),
    };
    defer scenario.deinit();
    if (compare_policy == .round_robin) scenario.round_robin_quantum = report.scenario.round_robin_quantum;

    var result = try scheduler.simulate(app.allocator, &scenario, compare_policy);
    defer result.deinit();
    const source_info: scheduler.cli.SourceInfo = switch (source) {
        .builtin => |name| .{ .kind = .builtin, .value = name },
        .file => |path| .{ .kind = .file, .value = path },
    };
    const sim_report = scheduler.cli.SimulationReport.init(source_info, &scenario, &result);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(app.allocator);
    var writer = buffer.writer(app.allocator);
    try scheduler.cli.writeJsonReport(&writer, sim_report);
    app.compare_report = try analysis.model.parseReport(app.allocator, buffer.items);
}

fn appendHistory(app: *App, label: []const u8) !void {
    if (app.history.items.len == 0 or !std.mem.eql(u8, app.history.items[app.history.items.len - 1], label)) {
        try app.history.append(app.allocator, label);
    } else {
        app.allocator.free(label);
    }
    while (app.history.items.len > 4) {
        const removed = app.history.orderedRemove(0);
        app.allocator.free(removed);
    }
}

fn lastTick(report: *const analysis.model.Report) u32 {
    var max_tick: u32 = 0;
    for (report.trace) |event| max_tick = @max(max_tick, event.tick);
    return max_tick;
}

fn pickerEntries() []const PickerEntry {
    return &.{
        .{ .scenario_key = "scenarios/basic/multicore-contention.zon", .scenario_label = "multicore-contention", .pack = "core/basic", .policy = .fcfs, .policy_label = "fcfs", .description = "two cores, equal arrivals, unbounded bursts", .cores = 2, .tasks = 4, .ticks = 9 },
        .{ .scenario_key = "scenarios/basic/multicore-contention.zon", .scenario_label = "multicore-contention", .pack = "core/basic", .policy = .round_robin, .policy_label = "round_robin", .description = "same scenario, q=2 preemptive quantum", .cores = 2, .tasks = 4, .ticks = 9 },
        .{ .scenario_key = "scenarios/basic/deadline-priority.zon", .scenario_label = "deadline-priority", .pack = "core/basic", .policy = .deadline, .policy_label = "deadline", .description = "edf-style ordering, missed-deadline probe", .cores = 1, .tasks = 3, .ticks = 12 },
        .{ .scenario_key = "scenarios/basic/group-fairness.zon", .scenario_label = "group-fairness", .pack = "core/basic", .policy = .cfs_like, .policy_label = "cfs-like", .description = "two groups, latency vs batch weighting", .cores = 2, .tasks = 5, .ticks = 11 },
        .{ .scenario_key = "scenarios/basic/sleep-wakeup.zon", .scenario_label = "sleep-wakeup", .pack = "core/basic", .policy = .cfs_like, .policy_label = "cfs-like", .description = "blocked/wakeup transitions, single phase", .cores = 1, .tasks = 3, .ticks = 14 },
        .{ .scenario_key = "scenarios/basic/starvation-pressure.zon", .scenario_label = "starvation-pressure", .pack = "core/basic", .policy = .round_robin, .policy_label = "round_robin", .description = "long-running low-priority task under rr", .cores = 1, .tasks = 4, .ticks = 18 },
        .{ .scenario_key = "scenarios/basic/topology-domains.zon", .scenario_label = "topology-domains", .pack = "core/basic", .policy = .fcfs, .policy_label = "fcfs", .description = "domain-aware placement + work stealing", .cores = 4, .tasks = 6, .ticks = 12 },
        .{ .scenario_key = "scenarios/basic/latency-probe.zon", .scenario_label = "latency-probe", .pack = "core/basic", .policy = .deadline, .policy_label = "deadline", .description = "response-time spread under mixed loads", .cores = 2, .tasks = 4, .ticks = 10 },
    };
}

test {
    _ = @import("args.zig");
}

test "picker metadata matches mockup lanes" {
    const entries = pickerEntries();
    try std.testing.expectEqual(@as(usize, 8), entries.len);
    try std.testing.expectEqualStrings("scenarios/basic/multicore-contention.zon", entries[0].scenario_key);
    try std.testing.expectEqual(scheduler.PolicyKind.fcfs, entries[0].policy);
    try std.testing.expectEqualStrings("scenarios/basic/group-fairness.zon", entries[3].scenario_key);
    try std.testing.expectEqual(scheduler.PolicyKind.cfs_like, entries[3].policy);
}
