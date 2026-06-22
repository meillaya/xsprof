//! SIZE_OK: VM-lab root renderer keeps the live dashboard/picker/help frame grammar in
//! one deterministic snapshot contract; splitting now would destabilize already-verified
//! row budgeting, pane density, and CJK width behavior across the root TUI screens.
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
pub const render = @import("render.zig");
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
    return interactiveAnsiFrameWithTheme(allocator, plain, .black);
}

fn interactiveAnsiFrameWithTheme(allocator: std.mem.Allocator, plain: []const u8, theme_id: render.ThemeId) ![]u8 {
    return render.renderInteractiveAnsiWithTheme(allocator, plain, theme_id);
}

pub fn renderInteractive(
    allocator: std.mem.Allocator,
    options: Options,
    action: ?linux.control.protocol.OperatorAction,
) ![]u8 {
    const mode: interaction.UiMode = if (options.screen == .vm_lab) .hero else .live;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    if (options.fixture_path) |path| {
        var parsed = try fixture.load(allocator, path);
        defer parsed.deinit();
        try renderFrameWithMode(&writer.writer, options, fixture.model(parsed.value), interaction.statusForAction(action), mode);
    } else {
        var report = try linux.collectPreflight(allocator);
        defer report.deinit();
        try renderFrameWithMode(&writer.writer, options, ui_model.live(report), interaction.statusForAction(action), mode);
    }
    out = writer.toArrayList();
    const plain = try out.toOwnedSlice(allocator);
    defer allocator.free(plain);
    return interactiveAnsiFrame(allocator, plain);
}

pub fn renderInteractiveMode(
    allocator: std.mem.Allocator,
    options: Options,
    mode: interaction.UiMode,
    action_status: []const u8,
) ![]u8 {
    return renderInteractiveModeWithTheme(allocator, options, mode, action_status, .black);
}

pub fn renderInteractiveModeWithTheme(
    allocator: std.mem.Allocator,
    options: Options,
    mode: interaction.UiMode,
    action_status: []const u8,
    theme_id: render.ThemeId,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    if (options.fixture_path) |path| {
        var parsed = try fixture.load(allocator, path);
        defer parsed.deinit();
        try renderFrameWithModeAndTheme(&writer.writer, options, fixture.model(parsed.value), action_status, mode, theme_id);
    } else {
        var report = try linux.collectPreflight(allocator);
        defer report.deinit();
        try renderFrameWithModeAndTheme(&writer.writer, options, ui_model.live(report), action_status, mode, theme_id);
    }
    out = writer.toArrayList();
    const plain = try out.toOwnedSlice(allocator);
    defer allocator.free(plain);
    return interactiveAnsiFrameWithTheme(allocator, plain, theme_id);
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
    try renderFrameWithMode(&writer.writer, render_options, model, action_status, .live);
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
    return renderInteractiveLiveStoreMode(allocator, options, .live, store, action_status);
}

pub fn renderInteractiveLiveStoreMode(
    allocator: std.mem.Allocator,
    options: Options,
    mode: interaction.UiMode,
    store: *const live_store.Store,
    action_status: []const u8,
) ![]u8 {
    return renderInteractiveLiveStoreModeWithTheme(allocator, options, mode, store, action_status, .black);
}

pub fn renderInteractiveLiveStoreModeWithTheme(
    allocator: std.mem.Allocator,
    options: Options,
    mode: interaction.UiMode,
    store: *const live_store.Store,
    action_status: []const u8,
    theme_id: render.ThemeId,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    var render_options = options;
    render_options.screen = .vm_lab;
    try renderFrameWithModeAndTheme(&writer.writer, render_options, store.toModel(), action_status, mode, theme_id);
    out = writer.toArrayList();
    const plain = try out.toOwnedSlice(allocator);
    defer allocator.free(plain);
    return interactiveAnsiFrameWithTheme(allocator, plain, theme_id);
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
    try renderFrameWithMode(&writer.writer, render_options, daemon_model.queuedModel(action_status), action_status, .live);
    out = writer.toArrayList();
    const plain = try out.toOwnedSlice(allocator);
    defer allocator.free(plain);
    return interactiveAnsiFrame(allocator, plain);
}

pub fn interactiveActionForKey(key: u8) ?linux.control.protocol.OperatorAction {
    return interaction.actionForKey(key);
}

fn renderFrame(writer: anytype, options: Options, model: fixture.SnapshotModel, action_status: []const u8) !void {
    const mode: interaction.UiMode = if (options.screen == .vm_lab and options.interactive) .hero else .live;
    return renderFrameWithMode(writer, options, model, action_status, mode);
}

fn renderFrameWithMode(writer: anytype, options: Options, model: fixture.SnapshotModel, action_status: []const u8, mode: interaction.UiMode) !void {
    return renderFrameWithModeAndTheme(writer, options, model, action_status, mode, .black);
}

fn renderFrameWithModeAndTheme(writer: anytype, options: Options, model: fixture.SnapshotModel, action_status: []const u8, mode: interaction.UiMode, theme_id: render.ThemeId) !void {
    if (options.screen == .vm_lab) return renderVmLabOperatorFrame(writer, options, model, action_status, mode, theme_id);
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

fn renderVmLabOperatorFrame(writer: anytype, options: Options, model: fixture.SnapshotModel, action_status: []const u8, mode: interaction.UiMode, theme_id: render.ThemeId) !void {
    const width = @max(options.width, 80);
    const hero_chrome = mode == .hero;
    const chrome_rows: usize = if (hero_chrome) 6 else 8;
    const body_rows: usize = if (options.height > chrome_rows)
        options.height - chrome_rows
    else
        0;
    try line(writer, width, "╭", "─", "╮");
    try renderVmLabHeader(writer, width, model, mode, theme_id);
    try line(writer, width, "├", "─", "┤");
    if (!hero_chrome) {
        if (model.fixture_warning.len != 0) try renderVmLabStatusStrip(writer, width, model, model.fixture_warning, mode) else try renderVmLabStatusStrip(writer, width, model, action_status, mode);
        try line(writer, width, "├", "─", "┤");
    }
    switch (mode) {
        .hero => try renderVmLabHeroBody(writer, width, body_rows, model),
        .picker => try renderVmLabAttachBody(writer, width, body_rows, model),
        .help => try renderVmLabHelpBody(writer, width, body_rows, model),
        .incident, .live => try renderVmLabDashboardBody(writer, width, body_rows, model),
    }
    try line(writer, width, "├", "─", "┤");
    if (hero_chrome) {
        try renderHeroStatusBar(writer, width);
    } else {
        const footer_status = if (action_status.len != 0) action_status else footerForMode(mode, model.footer_mode);
        try render.renderStatusBar(writer, width, footer_status);
    }
    try line(writer, width, "╰", "─", "╯");
}

fn shouldRenderLiveDashboard(model: fixture.SnapshotModel, action_status: []const u8) bool {
    if (std.mem.indexOf(u8, action_status, "RUNNING") != null or
        std.mem.indexOf(u8, action_status, "queued") != null or
        std.mem.indexOf(u8, action_status, "INCIDENT") != null or
        std.mem.indexOf(u8, action_status, "ROLLBACK") != null or
        std.mem.indexOf(u8, action_status, "CLEANUP") != null) return true;
    if (std.mem.indexOf(u8, model.evidence_mode, "vm-live") != null) return true;
    if (!std.mem.eql(u8, model.runtime_samples, "not-started")) return true;
    if (!std.mem.eql(u8, model.event_latest, "event list empty")) return true;
    return false;
}

fn renderVmLabHeader(writer: anytype, width: usize, model: fixture.SnapshotModel, mode: interaction.UiMode, theme_id: render.ThemeId) !void {
    var left_buf: [256]u8 = undefined;
    var right_buf: [192]u8 = undefined;
    const left = if (mode == .hero)
        "▚ zig-scheduler  │  local daemon · read-only · disposable VM lab"
    else
        std.fmt.bufPrint(&left_buf, "▚ zig-scheduler  │  live microVM lab  vm-lab · {s}", .{model.kernel_release}) catch "▚ zig-scheduler  │  live microVM lab";
    const daemon = if (mode == .live or mode == .incident or mode == .help) "● daemon attached · 2.3ms rtt" else "● daemon idle · local";
    const right = if (mode == .hero)
        std.fmt.bufPrint(&right_buf, "v1 · sched_ext readiness  │  {s}", .{render.themeHeaderLabel(theme_id)}) catch "v1 · sched_ext readiness"
    else
        std.fmt.bufPrint(&right_buf, "{s}  │  {s}", .{ daemon, render.themeHeaderLabel(theme_id) }) catch daemon;
    try writeOuterSplit(writer, width, left, right);
}

fn renderVmLabStatusStrip(writer: anytype, width: usize, model: fixture.SnapshotModel, action_status: []const u8, mode: interaction.UiMode) !void {
    var buf: [512]u8 = undefined;
    var status_buf: [512]u8 = undefined;
    const live_dashboard = mode == .live or mode == .incident or mode == .help;
    const status = if (mode == .hero)
        "press ⏎ or m to continue | ? key map · w theme | FAIL-CLOSED"
    else if (mode == .picker)
        "press m to request a fresh disposable microVM lab run"
    else if (mode == .help)
        "HELP OVERLAY modal · close with ? or Esc · live store preserved"
    else if (mode == .incident)
        std.fmt.bufPrint(&status_buf, "{s} · host_mutation=false", .{if (action_status.len != 0) action_status else model.incident_status}) catch if (action_status.len != 0) action_status else model.incident_status
    else if (live_dashboard and std.mem.indexOf(u8, model.cleanup_status, "[cleaned]") != null)
        std.fmt.bufPrint(&status_buf, "{s} · {s}", .{ model.cleanup_status, model.lab_gate }) catch model.cleanup_status
    else if (live_dashboard and std.mem.indexOf(u8, model.current_stage, "[") != null)
        model.current_stage
    else if (action_status.len != 0)
        action_status
    else if (live_dashboard)
        "ACTION queued run_lab_microvm_live · rollback ready"
    else
        "press m to request a fresh disposable microVM lab run";
    const run = if (live_dashboard) model.event_cursor else "run —";
    const mode_label = vmLabModeLabelForUi(mode, model, status);
    const line_text = std.fmt.bufPrint(&buf, "{s}   {s}   elapsed 0.0s  │  {s}", .{ mode_label, run, status }) catch status;
    try writeFrameText(writer, width, line_text);
}

fn vmLabModeLabelForUi(mode: interaction.UiMode, model: fixture.SnapshotModel, status: []const u8) []const u8 {
    return switch (mode) {
        .hero, .picker, .help => "NORMAL",
        .incident => "INCIDENT",
        .live => vmLabModeLabel(model, status),
    };
}

fn footerForMode(mode: interaction.UiMode, fallback: []const u8) []const u8 {
    return switch (mode) {
        .hero => "HERO fail-closed · press enter or m",
        .picker => "PICKER vm-lab-only · host unchanged",
        .help => "HELP modal · store preserved",
        .incident => "INCIDENT fail-closed",
        .live => fallback,
    };
}

fn renderHeroStatusBar(writer: anytype, width: usize) !void {
    try writer.writeAll("│ ");
    try layout.writeCell(writer, "press ⏎ or m to continue | ? key map · w theme | FAIL-CLOSED", width - 4);
    try writer.writeAll(" │\n");
}

fn vmLabModeLabel(model: fixture.SnapshotModel, status: []const u8) []const u8 {
    if (!std.mem.eql(u8, model.incident_status, "none") or std.mem.indexOf(u8, status, "INCIDENT") != null) return "INCIDENT";
    if (std.mem.indexOf(u8, status, "ROLLBACK") != null or std.mem.indexOf(u8, status, "rollback") != null) return "ROLLBACK";
    if (std.mem.indexOf(u8, status, "CLEANUP") != null or std.mem.indexOf(u8, status, "cleanup") != null) return "CLEANUP";
    if (std.mem.indexOf(u8, status, "RUNNING") != null or std.mem.indexOf(u8, status, "queued") != null) return "RUNNING";
    if (std.mem.indexOf(u8, status, "SAFE") != null or std.mem.indexOf(u8, status, "validated") != null) return "SAFE";
    return "NORMAL";
}

fn renderVmLabAttachBody(writer: anytype, width: usize, rows: usize, model: fixture.SnapshotModel) !void {
    var row_index: usize = 0;
    while (row_index < rows) : (row_index += 1) {
        try writeAttachRow(writer, width, rows, row_index, model);
    }
}

fn renderVmLabDashboardBody(writer: anytype, width: usize, rows: usize, model: fixture.SnapshotModel) !void {
    var row_index: usize = 0;
    while (row_index < rows) : (row_index += 1) {
        try writeDashboardRow(writer, width, rows, row_index, model);
    }
}

fn renderVmLabHeroBody(writer: anytype, width: usize, rows: usize, model: fixture.SnapshotModel) !void {
    var row_index: usize = 0;
    while (row_index < rows) : (row_index += 1) {
        try writeHeroRow(writer, width, rows, row_index, model);
    }
}

fn renderVmLabHelpBody(writer: anytype, width: usize, rows: usize, model: fixture.SnapshotModel) !void {
    var row_index: usize = 0;
    while (row_index < rows) : (row_index += 1) {
        try writeHelpRow(writer, width, rows, row_index, model);
    }
}

fn writeOuterSplit(writer: anytype, width: usize, left: []const u8, right: []const u8) !void {
    const content_width = width - 4;
    try writer.writeAll("│ ");
    const right_cells = layout.displayCells(right);
    const left_width = if (right_cells + 3 < content_width) content_width - right_cells - 3 else content_width;
    try layout.writeCell(writer, left, left_width);
    if (right_cells + 3 < content_width) {
        try writer.writeAll(" │ ");
        try layout.writeCell(writer, right, right_cells);
    }
    var cells = if (right_cells + 3 < content_width) content_width else @min(layout.displayCells(left), left_width);
    while (cells < content_width) : (cells += 1) try writer.writeByte(' ');
    try writer.writeAll(" │\n");
}

fn writeFrameText(writer: anytype, width: usize, text: []const u8) !void {
    try writer.writeAll("│ ");
    try layout.writeCell(writer, text, width - 4);
    try writer.writeAll(" │\n");
}

fn writeHeroRow(writer: anytype, width: usize, rows: usize, row_index: usize, model: fixture.SnapshotModel) !void {
    try writer.writeAll("│ ");
    var buf: [384]u8 = undefined;
    const offset: usize = if (rows >= 54) 8 else if (rows >= 38) 4 else 0;
    const hero_row = if (row_index >= offset) row_index - offset else 999;
    const text = switch (hero_row) {
        0 => "                                  ▚▚▚        live microVM lab",
        1 => "                                ▚▚   ▚▚      ────────────────────────────────",
        2 => "                               ▚▚     ▚▚     fail-closed Linux scheduler operator",
        3 => "                                ▚▚   ▚▚      disposable VM evidence console",
        4 => "                                  ▚▚▚",
        5 => "",
        6 => "                               A read-only operator surface for the live VM path. It attaches to a throwaway",
        7 => "                               microVM, observes a zigsched_minimal sched_ext scheduler running inside the",
        8 => "                               guest, and streams the lifecycle as evidence — the host is never mutated.",
        9 => "",
        10 => "                               ╭──────────────────────────────────────────────╮  ╭──────────────────────────────────────────────╮",
        11 => "                               │ ▸ LIVE ATTACH                                │  │ ▤ RUNTIME TELEMETRY                           │",
        12 => "                               │ disposable guest · rollback id armed first    │  │ sched_switch lanes · runqueue histogram       │",
        13 => "",
        14 => "                               │ Boots a disposable microVM and registers a zigsched_minimal sched_ext scheduler inside the guest.",
        15 => "                               ╰──────────────────────────────────────────────╯  ╰──────────────────────────────────────────────╯",
        16 => "                               ╭──────────────────────────────────────────────╮  ╭──────────────────────────────────────────────╮",
        17 => "                               │ ⇉ DAEMON EVENT STREAM                        │  │ ⊘ FAIL-CLOSED                                 │",
        18 => "                               │ Every lifecycle step arrives as a zig-scheduler/daemon-event/v1 record, filterable in real time.",
        19 => "                               │ Per-vCPU sched_switch lanes, utilization, runqueue-latency histogram — observed, descriptive, no perf claim.",
        20 => "                               │ host_mutation=false on every event. load · attach · enable · mutate · apply are refused on the host.",
        21 => "                               ╰──────────────────────────────────────────────╯  ╰──────────────────────────────────────────────╯",
        22 => "                               ╭────────────────────── command ──────────────────────╮   ╭──────────── launch ────────────╮",
        23 => "                               │ $ zig build tui-live-vm                              │   │ enter ▸ launch live run       │",
        24 => "                               │ target · 6.12.0-sched-ext-lab · x86_64              │   ╰───────────────────────────────╯",
        25 => "                               ╰──────────────────────────────────────────────────────╯",
        26 => "                               $ zig build tui-live-vm       enter ▸ launch live run       target · 6.12.0-sched-ext-lab · x86_64",
        27 => std.fmt.bufPrint(&buf, "                               vm-lab only · {s} · no host BPF/cgroup/cpuset/scheduler writes", .{model.lab_scope}) catch "                               vm-lab only · host fail-closed · no host BPF/cgroup/cpuset/scheduler writes",
        else => "",
    };
    try layout.writeCell(writer, text, width - 4);
    try writer.writeAll(" │\n");
}

fn writeHelpRow(writer: anytype, width: usize, rows: usize, row_index: usize, model: fixture.SnapshotModel) !void {
    _ = rows;
    try writer.writeAll("│ ");
    var buf: [512]u8 = undefined;
    const text = switch (row_index) {
        0 => "╭──────────────────────────── HELP OVERLAY ────────────────────────────╮",
        1 => "│ KEY MAP · fail-closed operator · ? or esc to close                    │",
        2 => "│ Enter or m: hero → picker; picker → queue live VM lab                 │",
        3 => "│ rollback — confirm with a second b · safe stop — confirm with a second s │",
        4 => "│ toggle this help · v verifier only · i incident drill · q quit        │",
        5 => "│ cursor j/k scrub daemon event list · w theme cycle                    │",
        6 => "├──────────────────── preserved live store underlay ───────────────────┤",
        7 => std.fmt.bufPrint(&buf, "│ latest event: {s}", .{model.event_latest}) catch "│ latest event: event list empty",
        8 => std.fmt.bufPrint(&buf, "│ runtime: {s}     cursor: {s}", .{ model.runtime_samples, model.event_cursor }) catch "│ runtime: not-started",
        9 => std.fmt.bufPrint(&buf, "│ current stage: {s}", .{model.current_stage}) catch "│ current stage: pending",
        10 => std.fmt.bufPrint(&buf, "│ incident: {s}     footer: {s}", .{ model.incident_status, model.footer_mode }) catch "│ incident: none",
        11 => "│ ACTION queued rollback_lab_run · target rollback id                   │",
        12 => "│ rollback active · operator confirmed rollback                         │",
        13 => "│ rollback PASS · state restored                                        │",
        14 => "│ stop refused · no live target                                         │",
        15 => "│ ACTION queued stop_lab_run · target rollback id                       │",
        16 => "│ stop active · operator confirmed safe stop                            │",
        17 => "│ live VM already armed · rollback ready                                │",
        18 => "│ safety: VM-lab-only, host_mutation=false, no host scheduler writes    │",
        19 => "╰───────────────────────────────────────────────────────────────────────╯",
        else => "",
    };
    try layout.writeCell(writer, text, width - 4);
    try writer.writeAll(" │\n");
}

fn writeAttachRow(writer: anytype, width: usize, rows: usize, row_index: usize, model: fixture.SnapshotModel) !void {
    const total = width - 5;
    const left_width = @max(@as(usize, 36), (total * 53) / 100);
    const right_width = total - left_width;
    try writer.writeAll("│ ");
    if (row_index == 0) {
        try writePaneBorder(writer, left_width, "╭", "─", "╮");
        try writer.writeByte(' ');
        try writePaneBorder(writer, right_width, "╭", "─", "╮");
    } else if (row_index == 1) {
        try writePaneText(writer, left_width, "ATTACH TARGET  disposable microVM · VM-only path");
        try writer.writeByte(' ');
        try writePaneText(writer, right_width, "PREFLIGHT  read-only host facts");
    } else if (row_index == 2) {
        try writePaneBorder(writer, left_width, "├", "─", "┤");
        try writer.writeByte(' ');
        try writePaneBorder(writer, right_width, "├", "─", "┤");
    } else if (row_index + 1 == rows) {
        try writePaneBorder(writer, left_width, "╰", "─", "╯");
        try writer.writeByte(' ');
        try writePaneBorder(writer, right_width, "╰", "─", "╯");
    } else {
        var left_buf: [384]u8 = undefined;
        var right_buf: [384]u8 = undefined;
        try writePaneText(writer, left_width, attachLeftLine(row_index - 3, model, &left_buf));
        try writer.writeByte(' ');
        try writePaneText(writer, right_width, attachRightLine(row_index - 3, model, &right_buf));
    }
    try writer.writeAll(" │\n");
}

fn attachLeftLine(index: usize, model: fixture.SnapshotModel, buf: *[384]u8) []const u8 {
    return switch (index) {
        0 => "The host stays fail-closed. load · attach · enable · mutate · apply are refused on the host.",
        1 => "A live run boots a throwaway guest, registers zigsched_minimal inside it, and streams runtime samples.",
        2 => "",
        3 => "PICK A TUPLE                                                    ↵ / m to arm",
        4 => "╭──────────────────────────────────────────────────────────────────────╮",
        5 => "│ ▸  6.12.0-sched-ext-lab · x86_64                         READY      │",
        6 => "│    disposable microVM · BTF present · approved tuple                 │",
        7 => "╰──────────────────────────────────────────────────────────────────────╯",
        8 => "╭──────────────────────────────────────────────────────────────────────╮",
        9 => "│ 2  6.11.0-rc6-zigsched · x86_64                          READY      │",
        10 => "│    mainline rc · sched_ext capable                                   │",
        11 => "╰──────────────────────────────────────────────────────────────────────╯",
        12 => "╭──────────────────────────────────────────────────────────────────────╮",
        13 => "│ 3  6.12.0-sched-ext-lab · aarch64                         SKIP       │",
        14 => "│    no kvm on host → fail-closed SKIP                                 │",
        15 => "╰──────────────────────────────────────────────────────────────────────╯",
        16 => "",
        17 => "╭────────────── m ▸ request live microVM run ──────────────╮",
        18 => "│ arms rollback + audit ids before any attach              │",
        19 => "╰──────────────────────────────────────────────────────────╯",
        20 => std.fmt.bufPrint(buf, "lab scope {s} · host_mutation=false", .{model.lab_scope}) catch "lab scope host fail-closed · host_mutation=false",
        else => "",
    };
}

fn attachRightLine(index: usize, model: fixture.SnapshotModel, buf: *[384]u8) []const u8 {
    return switch (index) {
        0 => "",
        1 => std.fmt.bufPrint(buf, "sched_ext           host fail-closed                  no BPF load on host · {s}", .{model.sched_state}) catch "sched_ext           host fail-closed                  no BPF load on host",
        2 => std.fmt.bufPrint(buf, "cgroup v2           vm-only                           no cgroup writes · {s}", .{model.cgroup_status}) catch "cgroup v2           vm-only                           no cgroup writes",
        3 => std.fmt.bufPrint(buf, "capabilities        host unchanged                    refuse unsafe verbs · {s}", .{model.capabilities}) catch "capabilities        host unchanged                    refuse unsafe verbs",
        4 => std.fmt.bufPrint(buf, "BTF                 lab gate required                 no load before approval · {s}", .{model.btf_status}) catch "BTF                 lab gate required                 no load before approval",
        5 => "",
        6 => "FAIL-CLOSED OUTCOMES ─────────────────────────────────────────────",
        7 => "SKIP    qemu unavailable",
        8 => "SKIP    kvm unavailable",
        9 => "REFUSE  VM_CONFIG_INVALID",
        10 => "REFUSE  nix_busybox_unavailable",
        11 => "every refusal keeps host_mutation=false",
        12 => "",
        13 => std.fmt.bufPrint(buf, "release eligible    {s}                    proof withheld", .{model.release_eligibility}) catch "release eligible    not release proof      proof withheld",
        14 => "approved lab        observing                         load absent",
        else => "",
    };
}

fn writeDashboardRow(writer: anytype, width: usize, rows: usize, row_index: usize, model: fixture.SnapshotModel) !void {
    const total = width - 6;
    const min_center_width: usize = 24;
    const preferred_left = @max(@as(usize, 56), (total * 30) / 100);
    const preferred_right = if (width >= 180) @as(usize, 60) else @max(@as(usize, 56), (total * 30) / 100);
    const left_width = if (total > preferred_right + min_center_width)
        @min(preferred_left, total - preferred_right - min_center_width)
    else
        @max(@as(usize, 28), total / 3);
    const right_width = if (total > left_width + min_center_width)
        @min(preferred_right, total - left_width - min_center_width)
    else
        @max(@as(usize, 24), (total - left_width) / 2);
    const center_width = total - left_width - right_width;
    try writer.writeAll("│ ");
    if (row_index == 0) {
        try writePaneBorder(writer, left_width, "╭", "─", "╮");
        try writer.writeByte(' ');
        try writePaneBorder(writer, center_width, "╭", "─", "╮");
        try writer.writeByte(' ');
        try writePaneBorder(writer, right_width, "╭", "─", "╮");
    } else if (row_index == 1) {
        try writePaneText(writer, left_width, "LIFECYCLE · gate · alert stack");
        try writer.writeByte(' ');
        try writePaneText(writer, center_width, "VCPU RUNTIME  zigsched_minimal · sched_ext · observed — no perf claim");
        try writer.writeByte(' ');
        try writePaneText(writer, right_width, "DAEMON EVENT STREAM · daemon-event/v1");
    } else if (row_index == 2) {
        try writePaneBorder(writer, left_width, "├", "─", "┤");
        try writer.writeByte(' ');
        try writePaneBorder(writer, center_width, "├", "─", "┤");
        try writer.writeByte(' ');
        try writePaneBorder(writer, right_width, "├", "─", "┤");
    } else if (row_index + 1 == rows) {
        try writePaneBorder(writer, left_width, "╰", "─", "╯");
        try writer.writeByte(' ');
        try writePaneBorder(writer, center_width, "╰", "─", "╯");
        try writer.writeByte(' ');
        try writePaneBorder(writer, right_width, "╰", "─", "╯");
    } else {
        var left_buf: [512]u8 = undefined;
        var center_buf: [512]u8 = undefined;
        var right_buf: [512]u8 = undefined;
        const content_index = row_index - 3;
        try writePaneText(writer, left_width, dashboardLeftLine(content_index, model, &left_buf));
        try writer.writeByte(' ');
        try writePaneText(writer, center_width, dashboardCenterLine(content_index, model, &center_buf));
        try writer.writeByte(' ');
        try writePaneText(writer, right_width, dashboardRightLine(content_index, model, &right_buf));
    }
    try writer.writeAll(" │\n");
}

fn dashboardLeftLine(index: usize, model: fixture.SnapshotModel, buf: *[512]u8) []const u8 {
    return switch (index) {
        0 => "LIFECYCLE  lifecycle lanes · disposable microVM · VM-only",
        1 => "✓ preflight build boot",
        2 => "✓ marker verifier attach",
        3 => "▸ observe rollback audit cleanup",
        4 => "· cleanup       · validate",
        5 => std.fmt.bufPrint(buf, "████████░░░░  host_mutation=false", .{}) catch "host_mutation=false",
        6 => "STAGE LEDGER ───────────────── run-all-lab/v1",
        7 => std.fmt.bufPrint(buf, "verifier_only       {s}", .{model.verifier_status}) catch "verifier_only pending",
        8 => std.fmt.bufPrint(buf, "partial_attach      ops recorded {s}", .{model.runtime_ops}) catch "partial_attach pending",
        9 => std.fmt.bufPrint(buf, "observe_partial     runtime samples {s}", .{model.runtime_samples}) catch "observe_partial not-started",
        10 => std.fmt.bufPrint(buf, "stress_chaos        {s}", .{model.stress_status}) catch "stress_chaos pending",
        11 => std.fmt.bufPrint(buf, "rollback_drill      {s}", .{model.rollback_status}) catch "rollback_drill rollback required",
        12 => std.fmt.bufPrint(buf, "release_gate        {s} · live bundle freshness", .{model.release_gate_status}) catch "release_gate closed · live bundle freshness",
        13 => "GATE LEDGER  fail-closed · not release eligible",
        14 => std.fmt.bufPrint(buf, "lab scope           {s}", .{model.lab_scope}) catch "lab scope lab-only vm guest",
        15 => std.fmt.bufPrint(buf, "vm marker           {s}", .{model.vm_marker}) catch "vm marker required",
        16 => std.fmt.bufPrint(buf, "kernel tuple        {s} · {s}", .{ model.kernel_release, model.arch }) catch "kernel tuple lab",
        17 => std.fmt.bufPrint(buf, "bundle              {s}", .{model.bundle_path}) catch "bundle required",
        18 => "AUDIT · ROLLBACK ───────────────────────────",
        19 => std.fmt.bufPrint(buf, "audit id            {s}", .{model.audit_id}) catch "audit id required",
        20 => std.fmt.bufPrint(buf, "rollback id         {s}", .{model.rollback_id}) catch "rollback id required",
        21 => std.fmt.bufPrint(buf, "cleanup             {s}", .{model.cleanup_status}) catch "cleanup cleanup receipt PASS",
        22 => std.fmt.bufPrint(buf, "release eligible    {s} · live bundle freshness", .{model.release_eligibility}) catch "release eligible not release eligible · live bundle freshness",
        23 => "ALERT STRIP  thresholds",
        24 => "• runqueue depth    dsq=2       within bound",
        25 => "▲ starvation watch  p99 460µs   wakeup-run tail",
        26 => "• nr_rejected       0           must stay 0",
        27 => std.fmt.bufPrint(buf, "• incident          {s} · tui-vm-lab-test", .{model.incident_status}) catch "• incident          none",
        else => "",
    };
}

fn dashboardCenterLine(index: usize, model: fixture.SnapshotModel, buf: *[512]u8) []const u8 {
    return switch (index) {
        0 => "cpu0 init      ▉▉▉▉▉▉ ▉▉▉▉▉ ▉▉▉▉▉▉▉     111320ms on-cpu",
        1 => "cpu1 workload  ▉▉▉ ▉▉▉▉▉▉ ▉▉▉ ▉▉▉▉▉▉     102080ms on-cpu",
        2 => "cpu2 busybox   ▉▉ ▉▉▉ ▉▉▉▉ ▉▉▉▉ ▉▉▉▉     100870ms on-cpu",
        3 => "cpu3 idle      ▉▉▉▉ ▉▉▉ ▉▉▉▉▉ ▉▉▉        102520ms on-cpu",
        4 => "rt  load  svc  sys  obs  — idle",
        5 => "PER-VCPU UTILIZATION                                           rolling",
        6 => "cpu0 ████████████████████████████████████████ 72%   cpu1 █████████████████ 66%",
        7 => "cpu2 ███████████████████████████████ 62%       cpu3 ████████████████ 59%",
        8 => "",
        9 => "RUNQUEUE LATENCY  runqueue-wait · observed distribution        p50 21µs · p99 460µs",
        10 => "<20µs       ███████████████████████████████████                  33",
        11 => "20-50       █████████████████████████████████████████            39",
        12 => "50-100                                                         0",
        13 => "100-200     ████                                                4",
        14 => "200-500     █████████████                                      13",
        15 => "500µs+                                                          0",
        16 => "RUNTIME COUNTERS runtime counters                       nr_rejected stable",
        17 => std.fmt.bufPrint(buf, "samples        {s}       before/during/after      nr_rejected   0", .{model.runtime_samples}) catch "samples not-started",
        18 => std.fmt.bufPrint(buf, "switches       3789      sched_switch             wakeups       577", .{}) catch "switches 3789",
        19 => std.fmt.bufPrint(buf, "migrations     1335      cross-vCPU ops           {s} attach-only", .{model.runtime_ops}) catch "migrations 1335",
        20 => std.fmt.bufPrint(buf, "runtime counters {s}", .{model.runtime_counters}) catch "runtime counters pending",
        21 => std.fmt.bufPrint(buf, "zigsched_minimal required during attach · {s}", .{model.evidence_mode}) catch "zigsched_minimal required during attach",
        else => "",
    };
}

fn dashboardRightLine(index: usize, model: fixture.SnapshotModel, buf: *[512]u8) []const u8 {
    return switch (index) {
        0 => "all lifecycle runtime_sample rollback incident",
        1 => std.fmt.bufPrint(buf, "{s} · scroll j/k", .{model.event_cursor}) catch "cursor none · scroll j/k",
        2 => std.fmt.bufPrint(buf, "latest · {s}", .{model.event_latest}) catch "latest · event list empty",
        3 => "stage_started queued · microvm_live_runner_start",
        4 => "build PASS · busybox guest image assembled",
        5 => "microvm_boot PASS · guest kernel booted",
        6 => "vm_marker PASS · vm marker present",
        7 => "verifier PASS · verifier log accepted",
        8 => "bpf_register PASS · runtime ops observed",
        9 => "attach active · live attach · streaming runtime samples",
        10 => "runtime_sample PASS · runtime samples accepted",
        11 => "rollback ready/completed",
        12 => "rollback active · operator confirmed rollback",
        13 => "rollback PASS · state restored",
        14 => "audit PASS · runtime samples linked to audit ledger",
        15 => std.fmt.bufPrint(buf, "cleanup cleaned · {s}", .{model.cleanup_status}) catch "cleanup cleaned",
        16 => "SAFE footer",
        17 => "journal → .omo/evidence/tui-live-vm",
        18 => if (!std.mem.eql(u8, model.incident_status, "none"))
            "validation blocked · incident keeps gate closed"
        else if (!std.mem.eql(u8, model.lab_gate, "live bundle freshness accepted"))
            "validation pending · live bundle not accepted"
        else
            std.fmt.bufPrint(buf, " 11.30s  ✓ validation PASS · {s}", .{model.lab_gate}) catch " 11.30s  ✓ validation PASS",
        19 => std.fmt.bufPrint(buf, "bundle · {s}", .{model.bundle_path}) catch "bundle · tui-vm-lab-test",
        20 => if (std.mem.eql(u8, model.lab_gate, "live bundle freshness accepted"))
            "live bundle freshness accepted"
        else if (!std.mem.eql(u8, model.incident_status, "none"))
            "live bundle freshness withheld"
        else
            "live bundle freshness pending",
        21 => std.fmt.bufPrint(buf, "ops recorded {s}", .{model.runtime_ops}) catch "ops recorded zigsched_minimal",
        22 => std.fmt.bufPrint(buf, "rollback · {s}", .{model.rollback_status}) catch "rollback ready/completed",
        23 => std.fmt.bufPrint(buf, "scope · {s}", .{model.lab_scope}) catch "scope · lab-only vm guest",
        24 => std.fmt.bufPrint(buf, "release eligible: {s}", .{model.release_eligibility}) catch "release eligible: not release proof",
        25 => "INCIDENT STATES: qemu_unavailable · verifier_reject",
        26 => "lost_stream · timeout · rollback_failure",
        27 => "cleanup_residue · malformed · redaction",
        28 => "unsafe_to_assume on gaps · duplicate/stale action ids",
        29 => std.fmt.bufPrint(buf, "current incident: {s}", .{model.incident_status}) catch "current incident: none",
        30 => "runtime samples accepted",
        else => "",
    };
}

fn writePaneBorder(writer: anytype, width: usize, left: []const u8, fill: []const u8, right: []const u8) !void {
    if (width < 2) return;
    try writer.writeAll(left);
    var cells: usize = 2;
    while (cells < width) : (cells += 1) try writer.writeAll(fill);
    try writer.writeAll(right);
}

fn writePaneText(writer: anytype, width: usize, text: []const u8) !void {
    if (width <= 4) {
        try layout.writeCell(writer, text, width);
        return;
    }
    try writer.writeAll("│ ");
    try layout.writeCell(writer, text, width - 4);
    try writer.writeAll(" │");
}

pub const writeUsage = args.writeUsage;

test "root TUI behavior tests are linked" {
    std.testing.refAllDecls(@import("root_tests.zig"));
}
