const std = @import("std");
const list_writer = @import("list_writer");
const scheduler = @import("zig_scheduler_internal");
const analysis = @import("analysis_root");
const args_mod = @import("args.zig");
const term_mod = @import("terminal.zig");
const render = @import("render.zig");
const actions = @import("actions.zig");

pub const Options = args_mod.Options;
pub const InputSource = args_mod.InputSource;
pub const RuntimeMode = args_mod.RuntimeMode;
pub const parseArgs = args_mod.parseArgs;

pub fn writeUsage(writer: anytype, exe_name: []const u8) !void {
    try writer.print(
        "usage: {s} [--input <report.json> | --stdin | --scenario <name> --policy <policy> | --scenario-file <path> --policy <policy> | --observability | --observability-manifest <path> | --comparison | --comparison-pairing <path>] [--snapshot [--width <cols>] [--height <rows>] [--tick <n>]]\n\ninteractive mode requires a real TTY\nsnapshot mode is explicit and requires a report-producing source or an explicit observability/comparison selection\n",
        .{exe_name},
    );
}

const ParsedReport = std.json.Parsed(analysis.model.Report);
const LoadedFixture = scheduler.observability.LoadedFixture;
const ComparisonSummary = scheduler.observability_comparison.ComparisonSummary;

const DomainMode = render.DomainMode;
const DashboardEntry = render.DashboardEntry;
const AppView = render.AppView;
const ThemeKind = render.ThemeKind;
const View = render.View;
const PaneFocus = render.PaneFocus;

const SimulationSource = union(enum) {
    builtin: []const u8,
    file: []const u8,
};

const App = struct {
    allocator: std.mem.Allocator,
    current_report: ?ParsedReport = null,
    compare_report: ?ParsedReport = null,
    observability_fixture: ?LoadedFixture = null,
    observability_comparison: ?ComparisonSummary = null,
    domain_mode: DomainMode = .simulator,
    view: View = .home,
    theme: ThemeKind = .dark,
    focus: PaneFocus = .gantt,
    cursor: u32 = 0,
    selected_task_index: ?usize = null,
    dashboard_index: usize = 0,
    playing: bool = false,
    dashboard_entries: []DashboardEntry,
    history: std.ArrayList([]const u8) = .empty,
    source: ?SimulationSource = null,

    fn deinit(self: *App) void {
        if (self.current_report) |*parsed| parsed.deinit();
        if (self.compare_report) |*parsed| parsed.deinit();
        if (self.observability_fixture) |*fixture| fixture.deinit(self.allocator);
        if (self.observability_comparison) |*loaded_comparison| loaded_comparison.deinit(self.allocator);
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit(self.allocator);
        self.allocator.free(self.dashboard_entries);
    }

    fn report(self: *const App) ?*const analysis.model.Report {
        if (self.current_report) |*parsed| return &parsed.value;
        return null;
    }

    fn compare(self: *const App) ?*const analysis.model.Report {
        if (self.compare_report) |*parsed| return &parsed.value;
        return null;
    }

    fn summary(self: *const App) ?*const scheduler.observability.ObservabilitySummary {
        if (self.observability_fixture) |*fixture| return &fixture.summary;
        return null;
    }

    fn comparison(self: *const App) ?*const ComparisonSummary {
        if (self.observability_comparison) |*loaded_comparison| return loaded_comparison;
        return null;
    }
};

const default_interactive_size: term_mod.Size = .{ .cols = 120, .rows = 40 };
const max_render_area: usize = 400_000;

fn normalizeInteractiveSize(raw: term_mod.Size, fallback: term_mod.Size) term_mod.Size {
    if (raw.cols == 0 or raw.rows == 0) return fallback;
    const area = @as(usize, raw.cols) * @as(usize, raw.rows);
    if (area > max_render_area) return fallback;
    return raw;
}

pub fn run(allocator: std.mem.Allocator, options: Options) !void {
    var app = App{
        .allocator = allocator,
        .dashboard_entries = try buildDashboardEntries(allocator),
    };
    defer app.deinit();

    const stdin_is_tty = try std.Io.File.stdin().isTty(std.Io.Threaded.global_single_threaded.io());
    const stdout_is_tty = try std.Io.File.stdout().isTty(std.Io.Threaded.global_single_threaded.io());
    try validateTerminalMode(options, stdin_is_tty, stdout_is_tty);
    try bootstrap(&app, options, stdin_is_tty);

    switch (options.runtime_mode) {
        .snapshot => {
            var stdout_buffer: [8192]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
            const stdout = &stdout_writer.interface;
            const frame = try renderSnapshotAlloc(allocator, &app, options);
            defer allocator.free(frame);
            try stdout.writeAll(frame);
            try stdout.writeByte('\n');
            try stdout.flush();
            return;
        },
        .interactive => {},
    }

    var terminal = try term_mod.Terminal.init();
    defer terminal.deinit();

    var size = normalizeInteractiveSize(terminal.size(), default_interactive_size);
    normalizeLayoutState(&app, size);
    var needs_redraw = true;

    while (true) {
        if (needs_redraw) {
            const frame = render.renderFrame(allocator, size.cols, size.rows, appView(&app)) catch |err| switch (err) {
                error.OutOfMemory => {
                    size = default_interactive_size;
                    needs_redraw = true;
                    continue;
                },
            };
            defer allocator.free(frame);
            try terminal.writeFrame(frame);
            needs_redraw = false;
        }

        const timeout: i32 = if (app.playing and app.view == .explorer) 200 else 100;
        const event = try terminal.readEvent(timeout);

        const next_size = normalizeInteractiveSize(terminal.size(), size);
        if (!term_mod.eqlSize(size, next_size)) {
            size = next_size;
            normalizeLayoutState(&app, size);
            needs_redraw = true;
        }

        switch (event) {
            .none => {
                if (app.playing and app.view == .explorer) {
                    advanceCursor(&app);
                    needs_redraw = true;
                }
            },
            .char => |ch| {
                if (try handleChar(&app, ch, size)) break;
                normalizeLayoutState(&app, size);
                needs_redraw = true;
            },
            else => {
                if (try handleEvent(&app, event, size)) break;
                normalizeLayoutState(&app, size);
                needs_redraw = true;
            },
        }
    }
}

fn bootstrap(app: *App, options: Options, stdin_is_tty: bool) !void {
    switch (options.input_source) {
        .dashboard => {
            if (!stdin_is_tty) return error.NonTtyDashboardRequiresSnapshot;
            app.domain_mode = .simulator;
            app.view = .home;
        },
        .input_file => |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, app.allocator, .unlimited);
            defer app.allocator.free(bytes);
            try loadReportBytes(app, bytes);
            app.view = .explorer;
        },
        .stdin_report => {
            var stdin_buffer: [8192]u8 = undefined;
            var stdin_reader = std.Io.File.stdin().readerStreaming(std.Io.Threaded.global_single_threaded.io(), &stdin_buffer);
            const bytes = try stdin_reader.interface.readAlloc(app.allocator, std.math.maxInt(usize));
            defer app.allocator.free(bytes);
            try loadReportBytes(app, bytes);
            app.view = .explorer;
        },
        .simulate_builtin => |name| {
            try loadSimulation(app, .{ .builtin = name }, options.policy.?);
            app.view = .explorer;
        },
        .simulate_file => |path| {
            try loadSimulation(app, .{ .file = path }, options.policy.?);
            app.view = .explorer;
        },
        .observability_default => {
            try loadObservabilityFixture(app, scheduler.observability.default_manifest_path);
            app.view = .observability_summary;
        },
        .observability_manifest => |path| {
            try loadObservabilityFixture(app, path);
            app.view = .observability_summary;
        },
        .comparison_default => {
            try loadObservabilityComparison(app, scheduler.observability_comparison.default_pairing_manifest_path);
            app.view = .observability_comparison;
        },
        .comparison_pairing => |path| {
            try loadObservabilityComparison(app, path);
            app.view = .observability_comparison;
        },
    }
}

fn appView(app: *App) AppView {
    return .{
        .domain_mode = app.domain_mode,
        .theme = app.theme,
        .view = app.view,
        .focus = app.focus,
        .cursor = app.cursor,
        .selected_task_index = app.selected_task_index,
        .dashboard_index = app.dashboard_index,
        .playing = app.playing,
        .report = app.report(),
        .compare_report = app.compare(),
        .observability_summary = app.summary(),
        .observability_comparison = app.comparison(),
        .dashboard_entries = app.dashboard_entries,
        .history = app.history.items,
    };
}

fn validateTerminalMode(options: Options, stdin_is_tty: bool, stdout_is_tty: bool) !void {
    if (options.runtime_mode == .snapshot) return;
    if (stdin_is_tty and stdout_is_tty) return;
    if (options.input_source == .dashboard and !stdin_is_tty) return error.NonTtyDashboardRequiresSnapshot;
    return error.NotATerminal;
}

fn renderSnapshotAlloc(allocator: std.mem.Allocator, app: *App, options: Options) ![]u8 {
    if (options.input_source == .dashboard) return error.InvalidArguments;
    switch (app.domain_mode) {
        .simulator => {
            const report = app.report() orelse return error.InvalidArguments;
            if (options.snapshot_tick) |tick| {
                const end = lastTick(report);
                if (tick > end) return error.InvalidArguments;
                app.cursor = tick;
            } else {
                app.cursor = 0;
            }
            app.view = .explorer;
        },
        .observability_summary => {
            app.view = .observability_summary;
        },
        .observability_comparison => {
            app.view = .observability_comparison;
        },
    }
    app.playing = false;
    return try render.renderSnapshotFrame(allocator, options.snapshot_width, options.snapshot_height, appView(app));
}

fn activeContract(app: *App, size: term_mod.Size) render.ViewLayoutContract {
    return render.viewContract(app.view, size.cols, size.rows, app.compare() != null);
}

fn normalizeLayoutState(app: *App, size: term_mod.Size) void {
    const contract = activeContract(app, size);
    if (render.normalizedFocus(app.focus, contract)) |focus| {
        app.focus = focus;
    }
}

fn handleEvent(app: *App, event: term_mod.Event, size: term_mod.Size) !bool {
    const contract = activeContract(app, size);
    const key = keyNameForEvent(event) orelse return false;
    if (actions.actionForKey(render.dashboardScreenForView(app.view), key)) |action| {
        return try handleAction(app, action, contract, event);
    }
    return false;
}

fn handleChar(app: *App, ch: u8, size: term_mod.Size) !bool {
    const contract = activeContract(app, size);
    const key = keyNameForChar(ch) orelse return false;
    if (actions.actionForKey(render.dashboardScreenForView(app.view), key)) |action| {
        return try handleAction(app, action, contract, .{ .char = ch });
    }
    return false;
}

fn keyNameForEvent(event: term_mod.Event) ?[]const u8 {
    return switch (event) {
        .escape => "esc",
        .enter => "enter",
        .tab => "tab",
        .backtab => "shift-tab",
        .space => "space",
        .left => "left",
        .right => "right",
        .up => "up",
        .down => "down",
        .home => "home",
        .end => "end",
        .char => |ch| keyNameForChar(ch),
        else => null,
    };
}

fn keyNameForChar(ch: u8) ?[]const u8 {
    return switch (ch) {
        3 => "ctrl-c",
        'q' => "q",
        '?' => "?",
        'h' => "h",
        'w' => "w",
        'j' => "j",
        'k' => "k",
        's' => "s",
        't' => "t",
        'o' => "o",
        'c' => "c",
        'p' => "p",
        'r' => "r",
        'd' => "d",
        '[' => "[",
        ']' => "]",
        else => null,
    };
}

fn handleAction(app: *App, action: actions.ActionId, contract: render.ViewLayoutContract, event: term_mod.Event) !bool {
    switch (action) {
        .quit => return true,
        .help => {
            if (contract.help_mode != .disabled or app.view == .help) {
                app.view = if (app.view == .help) primaryView(app) else .help;
            }
        },
        .back => handleEscape(app),
        .home => {
            app.domain_mode = .simulator;
            app.view = .home;
            app.playing = false;
        },
        .theme => {
            app.theme = if (app.theme == .dark) .light else .dark;
        },
        .move_up => if (app.domain_mode == .simulator) try moveSelection(app, -1, contract),
        .move_down => if (app.domain_mode == .simulator) try moveSelection(app, 1, contract),
        .next_focus => cycleFocus(app, contract),
        .previous_focus => cycleFocusReverse(app, contract),
        .activate => try handleEnter(app, contract),
        .scenario_details => {
            if (app.domain_mode == .simulator) app.view = .scenario;
        },
        .timeline => if (app.domain_mode == .simulator) {
            if (app.report() != null) {
                app.view = .explorer;
            } else {
                try openDashboardSelection(app);
                app.view = .explorer;
            }
        },
        .observability => try openObservabilitySummary(app),
        .observability_comparison => try openObservabilityComparison(app),
        .performance => {
            app.view = .performance;
        },
        .reports => {
            app.view = .reports;
        },
        .play_pause => {
            if (app.domain_mode == .simulator and app.view == .explorer and contract.tier != .too_small) app.playing = !app.playing;
        },
        .scrub_left => if (app.domain_mode == .simulator) {
            switch (event) {
                .home => app.cursor = 0,
                else => moveCursor(app, -1),
            }
        },
        .scrub_right => if (app.domain_mode == .simulator) {
            switch (event) {
                .end => {
                    if (app.report()) |report| app.cursor = lastTick(report);
                },
                else => moveCursor(app, 1),
            }
        },
        .task_details => try handleEnter(app, contract),
        .policy_compare => if (app.domain_mode == .simulator and (app.view != .explorer or contract.tier != .too_small)) try toggleDiff(app, contract),
        .previous_policy => if (app.domain_mode == .simulator and (app.view == .home or app.view == .scenario)) cycleDashboardPolicy(app, true),
        .next_policy => if (app.domain_mode == .simulator and (app.view == .home or app.view == .scenario)) cycleDashboardPolicy(app, false),
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

fn moveSelection(app: *App, delta: i32, contract: render.ViewLayoutContract) !void {
    if (app.view == .home) {
        const len = app.dashboard_entries.len;
        if (len == 0) return;
        if (delta < 0) {
            app.dashboard_index = if (app.dashboard_index == 0) 0 else app.dashboard_index - 1;
        } else {
            app.dashboard_index = @min(len - 1, app.dashboard_index + 1);
        }
        return;
    }
    if (contract.tier == .too_small) return;
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

fn handleEnter(app: *App, contract: render.ViewLayoutContract) !void {
    switch (app.view) {
        .home => try openDashboardSelection(app),
        .scenario => {
            try openDashboardSelection(app);
            app.view = .explorer;
        },
        .explorer => {
            if (contract.can_enter_drawer and app.selected_task_index != null) app.view = .drawer;
        },
        .performance, .reports, .drawer, .diff, .observability_summary, .observability_comparison => {},
        .help => app.view = primaryView(app),
    }
}

fn handleEscape(app: *App) void {
    switch (app.view) {
        .help => app.view = primaryView(app),
        .drawer, .diff => app.view = .explorer,
        .scenario, .performance, .reports => app.view = .home,
        .home => {
            if (app.domain_mode == .simulator and app.report() != null) app.view = .explorer;
        },
        .explorer => app.selected_task_index = null,
        .observability_summary, .observability_comparison => {},
    }
}

fn cycleFocus(app: *App, contract: render.ViewLayoutContract) void {
    if (render.nextFocus(app.focus, contract, false)) |focus| app.focus = focus;
}

fn cycleFocusReverse(app: *App, contract: render.ViewLayoutContract) void {
    if (render.nextFocus(app.focus, contract, true)) |focus| app.focus = focus;
}

fn toggleHome(app: *App) void {
    app.view = if (app.view == .home and app.report() != null) .explorer else .home;
    app.playing = false;
}

fn toggleDiff(app: *App, contract: render.ViewLayoutContract) !void {
    if (app.domain_mode != .simulator) return;
    if (app.view == .diff) {
        app.view = .explorer;
        return;
    }
    if (contract.tier == .too_small) return;
    if (app.report() == null) return;
    try ensureCompareReport(app);
    if (app.compare() != null) app.view = .diff;
}

fn primaryView(app: *const App) View {
    return switch (app.domain_mode) {
        .simulator => if (app.view == .help and app.report() != null) .explorer else .home,
        .observability_summary => .observability_summary,
        .observability_comparison => .observability_comparison,
    };
}

fn openDashboardSelection(app: *App) !void {
    const entry = app.dashboard_entries[app.dashboard_index];
    try loadSimulation(app, .{ .file = entry.scenario_key }, entry.policy);
    app.view = .explorer;
}

fn openObservabilitySummary(app: *App) !void {
    try loadObservabilityFixture(app, scheduler.observability.default_manifest_path);
    app.view = .observability_summary;
}

fn openObservabilityComparison(app: *App) !void {
    try loadObservabilityComparison(app, scheduler.observability_comparison.default_pairing_manifest_path);
    app.view = .observability_comparison;
}

fn cycleDashboardPolicy(app: *App, reverse: bool) void {
    const current = app.dashboard_entries[app.dashboard_index].policy;
    const order = [_]scheduler.PolicyKind{ .fcfs, .round_robin, .cfs_like, .deadline };
    var next_policy = current;
    for (order, 0..) |policy, idx| {
        if (policy == current) {
            next_policy = if (reverse) order[(idx + order.len - 1) % order.len] else order[(idx + 1) % order.len];
            break;
        }
    }
    updateDashboardEntry(app, app.dashboard_index, next_policy) catch {};
}

fn loadReportBytes(app: *App, bytes: []const u8) !void {
    clearSimulatorState(app);
    clearObservabilityState(app);
    app.current_report = try analysis.model.parseReport(app.allocator, bytes);
    app.domain_mode = .simulator;
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

fn loadSimulation(app: *App, source: SimulationSource, policy: scheduler.PolicyKind) !void {
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
    var writer = list_writer.writer(&buffer, app.allocator);
    try scheduler.cli.writeJsonReport(&writer, report);

    try loadReportBytes(app, buffer.items);
    app.source = source;
}

fn loadObservabilityFixture(app: *App, manifest_path: []const u8) !void {
    clearSimulatorState(app);
    clearObservabilityState(app);
    app.observability_fixture = try scheduler.observability.loadFixture(app.allocator, manifest_path);
    app.domain_mode = .observability_summary;
    app.source = null;
    app.cursor = 0;
    app.selected_task_index = null;
    const summary = &app.observability_fixture.?.summary;
    const label = try std.fmt.allocPrint(app.allocator, "· observability · {s}", .{summary.fixture_name});
    errdefer app.allocator.free(label);
    try appendHistory(app, label);
}

fn loadObservabilityComparison(app: *App, pairing_manifest_path: []const u8) !void {
    clearSimulatorState(app);
    clearObservabilityState(app);
    app.observability_comparison = try scheduler.observability_comparison.buildApprovedComparison(app.allocator, pairing_manifest_path);
    app.domain_mode = .observability_comparison;
    app.source = null;
    app.cursor = 0;
    app.selected_task_index = null;
    const label = try std.fmt.allocPrint(app.allocator, "· comparison · {s}", .{app.observability_comparison.?.pairing_id});
    errdefer app.allocator.free(label);
    try appendHistory(app, label);
}

fn clearSimulatorState(app: *App) void {
    if (app.current_report) |*parsed| {
        parsed.deinit();
        app.current_report = null;
    }
    if (app.compare_report) |*parsed| {
        parsed.deinit();
        app.compare_report = null;
    }
}

fn clearObservabilityState(app: *App) void {
    if (app.observability_fixture) |*fixture| {
        fixture.deinit(app.allocator);
        app.observability_fixture = null;
    }
    if (app.observability_comparison) |*comparison| {
        comparison.deinit(app.allocator);
        app.observability_comparison = null;
    }
}

fn ensureCompareReport(app: *App) !void {
    if (app.domain_mode != .simulator) return;
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
    var writer = list_writer.writer(&buffer, app.allocator);
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

fn buildDashboardEntries(allocator: std.mem.Allocator) ![]DashboardEntry {
    const entries = scheduler.scenario_packs.listScenarioPackEntries(scheduler.scenario_packs.core_pack_key) orelse return error.UnknownScenarioPack;
    var dashboard_entries = try allocator.alloc(DashboardEntry, entries.len);
    errdefer allocator.free(dashboard_entries);

    for (entries, 0..) |entry, index| {
        dashboard_entries[index] = try buildDashboardEntry(allocator, entry, entry.dashboard_policy);
    }

    return dashboard_entries;
}

fn buildDashboardEntry(
    allocator: std.mem.Allocator,
    entry: scheduler.scenario_packs.ScenarioPackEntry,
    policy: scheduler.PolicyKind,
) !DashboardEntry {
    var scenario = try scheduler.loadScenarioFile(allocator, entry.path);
    defer scenario.deinit();

    var result = try scheduler.simulate(allocator, &scenario, policy);
    defer result.deinit();

    var max_tick: u32 = 0;
    for (result.trace) |event| max_tick = @max(max_tick, event.tick);

    const shortlist_rank = teachingRank(entry.key);

    return .{
        .scenario_key = entry.path,
        .scenario_label = entry.key,
        .pack = scheduler.scenario_packs.core_pack_key,
        .policy = policy,
        .policy_label = policyLabel(policy),
        .description = entry.description,
        .theme_label = if (entry.theme) |theme| scheduler.scenario_packs.curriculumThemeLabel(theme) else null,
        .explanation_doc = entry.explanation_doc,
        .start_here_rank = shortlist_rank,
        .cores = scenario.core_count,
        .tasks = @intCast(scenario.tasks.len),
        .ticks = if (result.trace.len == 0) 0 else max_tick + 1,
    };
}

fn updateDashboardEntry(app: *App, index: usize, policy: scheduler.PolicyKind) !void {
    const scenario_label = app.dashboard_entries[index].scenario_label;
    const entry = scheduler.scenario_packs.findScenarioPackEntry(scheduler.scenario_packs.core_pack_key, scenario_label) orelse return error.UnknownScenario;
    app.dashboard_entries[index] = try buildDashboardEntry(app.allocator, entry, policy);
}

fn policyLabel(policy: scheduler.PolicyKind) []const u8 {
    return switch (policy) {
        .fcfs => "fcfs",
        .round_robin => "round_robin",
        .cfs_like => "cfs-like",
        .deadline => "deadline",
    };
}

fn teachingRank(scenario_key: []const u8) ?u8 {
    for (scheduler.scenario_packs.listteachingTeachingEntries(), 0..) |entry, index| {
        if (std.mem.eql(u8, entry.key, scenario_key)) return @intCast(index + 1);
    }
    return null;
}

test {
    _ = @import("args.zig");
}

test "dashboard metadata matches mockup lanes" {
    const entries = try buildDashboardEntries(std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(scheduler.scenario_packs.listScenarioPackEntries(scheduler.scenario_packs.core_pack_key).?.len, entries.len);
    try std.testing.expectEqualStrings("scenarios/basic/arrivals.zon", entries[0].scenario_key);
    try std.testing.expectEqual(scheduler.PolicyKind.fcfs, entries[0].policy);
    try std.testing.expectEqualStrings("scenarios/basic/deadline-priority.zon", entries[2].scenario_key);
    try std.testing.expectEqual(scheduler.PolicyKind.deadline, entries[2].policy);
    try std.testing.expectEqualStrings("scenarios/basic/starvation-pressure.zon", entries[16].scenario_key);
    try std.testing.expectEqual(scheduler.PolicyKind.cfs_like, entries[16].policy);
}

test "dashboard metadata stays aligned with canonical scenario files" {
    const allocator = std.testing.allocator;
    const entries = try buildDashboardEntries(allocator);
    defer allocator.free(entries);

    for (entries) |entry| {
        var scenario = try scheduler.loadScenarioFile(allocator, entry.scenario_key);
        defer scenario.deinit();
        try std.testing.expectEqual(entry.cores, scenario.core_count);
        try std.testing.expectEqual(entry.tasks, scenario.tasks.len);

        var result = try scheduler.simulate(allocator, &scenario, entry.policy);
        defer result.deinit();

        var last_tick: u32 = 0;
        for (result.trace) |event| last_tick = @max(last_tick, event.tick);
        try std.testing.expectEqual(entry.ticks, last_tick + 1);
    }
}

test "dashboard policy presets stay aligned with canonical scenario recommendations" {
    const canonical_entries = scheduler.scenario_packs.listScenarioPackEntries(scheduler.scenario_packs.core_pack_key).?;
    const dashboard_entries = try buildDashboardEntries(std.testing.allocator);
    defer std.testing.allocator.free(dashboard_entries);

    for (dashboard_entries) |dashboard_entry| {
        for (canonical_entries) |canonical_entry| {
            if (!std.mem.eql(u8, dashboard_entry.scenario_key, canonical_entry.path)) continue;
            try std.testing.expectEqual(canonical_entry.dashboard_policy, dashboard_entry.policy);
            if (canonical_entry.canonical) {
                try std.testing.expectEqual(canonical_entry.recommended_policy.?, dashboard_entry.policy);
            }
        }
    }
}

test "terminal size equality helper is exact" {
    try std.testing.expect(term_mod.eqlSize(.{ .cols = 120, .rows = 40 }, .{ .cols = 120, .rows = 40 }));
    try std.testing.expect(!term_mod.eqlSize(.{ .cols = 120, .rows = 40 }, .{ .cols = 121, .rows = 40 }));
    try std.testing.expect(!term_mod.eqlSize(.{ .cols = 120, .rows = 40 }, .{ .cols = 120, .rows = 41 }));
}

test "normalize interactive size falls back for zero or absurd area" {
    try std.testing.expectEqual(default_interactive_size, normalizeInteractiveSize(.{ .cols = 0, .rows = 40 }, default_interactive_size));
    try std.testing.expectEqual(default_interactive_size, normalizeInteractiveSize(.{ .cols = 120, .rows = 0 }, default_interactive_size));
    try std.testing.expectEqual(default_interactive_size, normalizeInteractiveSize(.{ .cols = 2000, .rows = 500 }, default_interactive_size));
    try std.testing.expectEqual(term_mod.Size{ .cols = 160, .rows = 48 }, normalizeInteractiveSize(.{ .cols = 160, .rows = 48 }, default_interactive_size));
}

test "interactive dashboard rejects missing tty without snapshot" {
    var app = App{
        .allocator = std.testing.allocator,
        .dashboard_entries = try buildDashboardEntries(std.testing.allocator),
    };
    defer app.deinit();

    try std.testing.expectError(error.NonTtyDashboardRequiresSnapshot, bootstrap(&app, .{}, false));
}

test "usage text mentions explicit snapshot mode" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer = list_writer.writer(&buffer, std.testing.allocator);
    try writeUsage(&writer, "zig-scheduler-tui");
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "--snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "--width") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "--observability") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "--comparison") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "requires a real TTY") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "zig-scheduler-tui") != null);
}

test "layout tiers classify mixed width and height cases deterministically" {
    try std.testing.expectEqual(render.LayoutTier.large, render.classifyLayout(100, 30));
    try std.testing.expectEqual(render.LayoutTier.medium, render.classifyLayout(95, 40));
    try std.testing.expectEqual(render.LayoutTier.medium, render.classifyLayout(100, 29));
    try std.testing.expectEqual(render.LayoutTier.compact, render.classifyLayout(120, 24));
    try std.testing.expectEqual(render.LayoutTier.compact, render.classifyLayout(89, 40));
    try std.testing.expectEqual(render.LayoutTier.too_small, render.classifyLayout(79, 23));
}

test "explorer focus contract skips hidden panes in too-small tier" {
    const compact_contract = render.viewContract(.explorer, 80, 24, true);
    try std.testing.expectEqual(@as(?PaneFocus, .gantt), render.normalizedFocus(.gantt, compact_contract));
    try std.testing.expectEqual(@as(?PaneFocus, .tasks), render.nextFocus(.gantt, compact_contract, false));
    try std.testing.expectEqual(@as(?PaneFocus, .tick), render.nextFocus(.gantt, compact_contract, true));

    const too_small_contract = render.viewContract(.explorer, 79, 23, true);
    try std.testing.expectEqual(@as(?PaneFocus, null), render.normalizedFocus(.gantt, too_small_contract));
    try std.testing.expectEqual(@as(?PaneFocus, null), render.nextFocus(.gantt, too_small_contract, false));
}

test "snapshot render works from simulation path" {
    var app = App{
        .allocator = std.testing.allocator,
        .dashboard_entries = try buildDashboardEntries(std.testing.allocator),
    };
    defer app.deinit();

    try loadSimulation(&app, .{ .file = "scenarios/basic/multicore-contention.zon" }, .fcfs);
    const options = Options{
        .input_source = .{ .simulate_file = "scenarios/basic/multicore-contention.zon" },
        .runtime_mode = .snapshot,
        .policy = .fcfs,
        .snapshot_width = 120,
        .snapshot_height = 40,
    };
    const frame = try renderSnapshotAlloc(std.testing.allocator, &app, options);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "multicore-contention") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "FCFS") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "cpu lanes") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "snapshot") != null);
}

test "teaching anchor scenario snapshots stay deterministic under recommended policies" {
    const shortlist = scheduler.scenario_packs.listteachingTeachingEntries();
    for (shortlist) |entry| {
        var app = App{
            .allocator = std.testing.allocator,
            .dashboard_entries = try buildDashboardEntries(std.testing.allocator),
        };
        defer app.deinit();

        try loadSimulation(&app, .{ .file = entry.path }, entry.recommended_policy.?);
        const options = Options{
            .input_source = .{ .simulate_file = entry.path },
            .runtime_mode = .snapshot,
            .policy = entry.recommended_policy.?,
            .snapshot_width = 120,
            .snapshot_height = 40,
        };
        const first = try renderSnapshotAlloc(std.testing.allocator, &app, options);
        defer std.testing.allocator.free(first);
        const second = try renderSnapshotAlloc(std.testing.allocator, &app, options);
        defer std.testing.allocator.free(second);

        try std.testing.expectEqualStrings(first, second);
        try std.testing.expect(std.mem.indexOf(u8, first, entry.key) != null);
    }
}

test "observability snapshot render is deterministic and observability-bounded" {
    var app = App{
        .allocator = std.testing.allocator,
        .dashboard_entries = try buildDashboardEntries(std.testing.allocator),
    };
    defer app.deinit();

    try loadObservabilityFixture(&app, scheduler.observability.default_manifest_path);
    const options = Options{
        .input_source = .observability_default,
        .runtime_mode = .snapshot,
        .snapshot_width = 120,
        .snapshot_height = 40,
    };
    const first = try renderSnapshotAlloc(std.testing.allocator, &app, options);
    defer std.testing.allocator.free(first);
    const second = try renderSnapshotAlloc(std.testing.allocator, &app, options);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "linux observability summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "observability-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "not replay authority") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "policy diff") == null);
}

test "comparison snapshot render is deterministic and non-fidelity-bounded" {
    var app = App{
        .allocator = std.testing.allocator,
        .dashboard_entries = try buildDashboardEntries(std.testing.allocator),
    };
    defer app.deinit();

    try loadObservabilityComparison(&app, scheduler.observability_comparison.default_pairing_manifest_path);
    const options = Options{
        .input_source = .comparison_default,
        .runtime_mode = .snapshot,
        .snapshot_width = 120,
        .snapshot_height = 40,
    };
    const first = try renderSnapshotAlloc(std.testing.allocator, &app, options);
    defer std.testing.allocator.free(first);
    const second = try renderSnapshotAlloc(std.testing.allocator, &app, options);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "simulator-to-trace comparison") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "observability-only comparison") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "not replay or fidelity evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "policy diff") == null);
}

test "observability lane keeps simulator-only dashboard and diff shortcuts disabled" {
    var app = App{
        .allocator = std.testing.allocator,
        .dashboard_entries = try buildDashboardEntries(std.testing.allocator),
    };
    defer app.deinit();

    try loadObservabilityFixture(&app, scheduler.observability.default_manifest_path);
    app.view = .observability_summary;

    _ = try handleChar(&app, 'd', .{ .cols = 120, .rows = 40 });
    try std.testing.expectEqual(View.observability_summary, app.view);

    _ = try handleChar(&app, 's', .{ .cols = 120, .rows = 40 });
    try std.testing.expectEqual(View.observability_summary, app.view);

    _ = try handleChar(&app, '?', .{ .cols = 120, .rows = 40 });
    try std.testing.expectEqual(View.help, app.view);
    handleEscape(&app);
    try std.testing.expectEqual(View.observability_summary, app.view);

    app.view = .help;
    const help = try render.renderSnapshotFrame(std.testing.allocator, 120, 40, appView(&app));
    defer std.testing.allocator.free(help);
    try std.testing.expect(std.mem.indexOf(u8, help, "observability-only lane") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "policy diff") == null);
}

test "dashboard shortcuts open observability and comparison observability lanes" {
    var app = App{
        .allocator = std.testing.allocator,
        .dashboard_entries = try buildDashboardEntries(std.testing.allocator),
    };
    defer app.deinit();

    app.view = .home;

    _ = try handleChar(&app, 'o', .{ .cols = 120, .rows = 40 });
    try std.testing.expectEqual(DomainMode.observability_summary, app.domain_mode);
    try std.testing.expectEqual(View.observability_summary, app.view);
    try std.testing.expect(app.summary() != null);

    _ = try handleChar(&app, 'c', .{ .cols = 120, .rows = 40 });
    try std.testing.expectEqual(DomainMode.observability_comparison, app.domain_mode);
    try std.testing.expectEqual(View.observability_comparison, app.view);
    try std.testing.expect(app.comparison() != null);
}

test "dashboard action matrix covers core screen transitions" {
    var app = App{
        .allocator = std.testing.allocator,
        .dashboard_entries = try buildDashboardEntries(std.testing.allocator),
    };
    defer app.deinit();

    app.view = .home;
    try std.testing.expectEqual(false, try handleChar(&app, 's', .{ .cols = 120, .rows = 40 }));
    try std.testing.expectEqual(View.scenario, app.view);

    try std.testing.expectEqual(false, try handleChar(&app, 't', .{ .cols = 120, .rows = 40 }));
    try std.testing.expectEqual(View.explorer, app.view);
    try std.testing.expect(app.report() != null);

    try std.testing.expectEqual(false, try handleChar(&app, 'd', .{ .cols = 120, .rows = 40 }));
    try std.testing.expectEqual(View.diff, app.view);
    try std.testing.expect(app.compare() != null);

    try std.testing.expectEqual(false, try handleChar(&app, 't', .{ .cols = 120, .rows = 40 }));
    try std.testing.expectEqual(View.explorer, app.view);

    app.selected_task_index = 0;
    try std.testing.expectEqual(false, try handleEvent(&app, .enter, .{ .cols = 120, .rows = 40 }));
    try std.testing.expectEqual(View.drawer, app.view);
    try std.testing.expectEqual(false, try handleEvent(&app, .escape, .{ .cols = 120, .rows = 40 }));
    try std.testing.expectEqual(View.explorer, app.view);

    try std.testing.expectEqual(false, try handleChar(&app, 'h', .{ .cols = 120, .rows = 40 }));
    try std.testing.expectEqual(View.home, app.view);
    try std.testing.expectEqual(false, try handleChar(&app, '?', .{ .cols = 120, .rows = 40 }));
    try std.testing.expectEqual(View.help, app.view);
    try std.testing.expectEqual(false, try handleChar(&app, '?', .{ .cols = 120, .rows = 40 }));
    try std.testing.expectEqual(View.explorer, app.view);

    try std.testing.expectEqual(true, try handleChar(&app, 'q', .{ .cols = 120, .rows = 40 }));
    try std.testing.expectEqual(true, try handleChar(&app, 3, .{ .cols = 120, .rows = 40 }));
}

test "dashboard status shortcuts are command-only and policy cycling uses brackets" {
    var app = App{
        .allocator = std.testing.allocator,
        .dashboard_entries = try buildDashboardEntries(std.testing.allocator),
    };
    defer app.deinit();

    app.view = .home;
    const initial_policy = app.dashboard_entries[app.dashboard_index].policy;

    _ = try handleChar(&app, 'p', .{ .cols = 120, .rows = 40 });
    try std.testing.expectEqual(View.performance, app.view);
    const performance = try render.renderSnapshotFrame(std.testing.allocator, 120, 40, appView(&app));
    defer std.testing.allocator.free(performance);
    try std.testing.expect(std.mem.indexOf(u8, performance, "zig build perf") != null);
    try std.testing.expect(std.mem.indexOf(u8, performance, "no subprocess runner") != null);

    _ = try handleChar(&app, 'h', .{ .cols = 120, .rows = 40 });
    _ = try handleChar(&app, 'r', .{ .cols = 120, .rows = 40 });
    try std.testing.expectEqual(View.reports, app.view);
    const reports = try render.renderSnapshotFrame(std.testing.allocator, 120, 40, appView(&app));
    defer std.testing.allocator.free(reports);
    try std.testing.expect(std.mem.indexOf(u8, reports, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, reports, "no subprocess runner") != null);

    _ = try handleChar(&app, 'h', .{ .cols = 120, .rows = 40 });
    _ = try handleChar(&app, ']', .{ .cols = 120, .rows = 40 });
    try std.testing.expect(app.dashboard_entries[app.dashboard_index].policy != initial_policy);
    _ = try handleChar(&app, '[', .{ .cols = 120, .rows = 40 });
    try std.testing.expectEqual(initial_policy, app.dashboard_entries[app.dashboard_index].policy);
}
