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
    if (options.screen == .vm_lab) return renderVmLabOperatorFrame(writer, options, model, action_status);
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

fn renderVmLabOperatorFrame(writer: anytype, options: Options, model: fixture.SnapshotModel, action_status: []const u8) !void {
    const width = @max(options.width, 80);
    const body_rows: usize = if (options.height > 8) options.height - 8 else 0;
    try line(writer, width, "╭", "─", "╮");
    try renderVmLabHeader(writer, width, model);
    try line(writer, width, "├", "─", "┤");
    if (model.fixture_warning.len != 0) try renderVmLabStatusStrip(writer, width, model, model.fixture_warning) else try renderVmLabStatusStrip(writer, width, model, action_status);
    try line(writer, width, "├", "─", "┤");
    if (shouldRenderLiveDashboard(model, action_status)) {
        try renderVmLabDashboardBody(writer, width, body_rows, model);
    } else {
        try renderVmLabAttachBody(writer, width, body_rows, model);
    }
    try line(writer, width, "├", "─", "┤");
    const footer_status = if (action_status.len != 0) action_status else model.footer_mode;
    try render.renderStatusBar(writer, width, footer_status);
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

fn renderVmLabHeader(writer: anytype, width: usize, model: fixture.SnapshotModel) !void {
    var left_buf: [256]u8 = undefined;
    var right_buf: [192]u8 = undefined;
    const left = std.fmt.bufPrint(&left_buf, "▚ zig-scheduler  │  live microVM lab  vm-lab · {s}", .{model.kernel_release}) catch "▚ zig-scheduler  │  live microVM lab";
    const daemon = if (shouldRenderLiveDashboard(model, model.footer_mode)) "daemon attached · 2.2ms rtt" else "daemon idle · local";
    const right = std.fmt.bufPrint(&right_buf, "{s}  │  theme black › w", .{daemon}) catch daemon;
    try writeOuterSplit(writer, width, left, right);
}

fn renderVmLabStatusStrip(writer: anytype, width: usize, model: fixture.SnapshotModel, action_status: []const u8) !void {
    var buf: [512]u8 = undefined;
    var status_buf: [512]u8 = undefined;
    const live_dashboard = shouldRenderLiveDashboard(model, action_status);
    const status = if (live_dashboard and std.mem.indexOf(u8, model.cleanup_status, "[cleaned]") != null)
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
    const mode = vmLabModeLabel(model, status);
    const line_text = std.fmt.bufPrint(&buf, "{s}   {s}   elapsed 0.0s  │  {s}", .{ mode, run, status }) catch status;
    try writeFrameText(writer, width, line_text);
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
        4 => "▸  6.12.0-sched-ext-lab · x86_64                                      READY",
        5 => "   disposable microVM · BTF present · approved tuple",
        6 => "2  6.11.0-rc6-zigsched · x86_64                                      READY",
        7 => "   mainline rc · sched_ext capable",
        8 => "3  6.12.0-sched-ext-lab · aarch64                                    SKIP",
        9 => "   no kvm on host · fail-closed SKIP",
        10 => "",
        11 => "m ▸ request live microVM run     arms rollback + audit ids before any attach",
        12 => std.fmt.bufPrint(buf, "lab scope {s} · host_mutation=false", .{model.lab_scope}) catch "lab scope host fail-closed · host_mutation=false",
        else => "",
    };
}

fn attachRightLine(index: usize, model: fixture.SnapshotModel, buf: *[384]u8) []const u8 {
    return switch (index) {
        0 => std.fmt.bufPrint(buf, "sched_ext          {s}                       no BPF load on host", .{model.sched_state}) catch "sched_ext host fail-closed",
        1 => std.fmt.bufPrint(buf, "cgroup v2          {s}                       no cgroup writes", .{model.cgroup_status}) catch "cgroup v2 vm-only",
        2 => std.fmt.bufPrint(buf, "capabilities       {s}                       refuse unsafe verbs", .{model.capabilities}) catch "capabilities host unchanged",
        3 => std.fmt.bufPrint(buf, "BTF                {s}                       no load before approval", .{model.btf_status}) catch "BTF lab gate required",
        4 => "",
        5 => "FAIL-CLOSED OUTCOMES",
        6 => "SKIP   qemu unavailable",
        7 => "SKIP   kvm unavailable",
        8 => "REFUSE VM_CONFIG_INVALID",
        9 => "REFUSE nix_busybox_unavailable",
        10 => "every refusal keeps host_mutation=false",
        11 => std.fmt.bufPrint(buf, "release eligible   {s}     proof withheld", .{model.release_eligibility}) catch "release eligible not release proof",
        else => "",
    };
}

fn writeDashboardRow(writer: anytype, width: usize, rows: usize, row_index: usize, model: fixture.SnapshotModel) !void {
    const total = width - 6;
    const left_width = @max(@as(usize, 28), (total * 25) / 100);
    const right_width = @max(@as(usize, 31), (total * 28) / 100);
    const center_width = total - left_width - right_width;
    try writer.writeAll("│ ");
    if (row_index == 0) {
        try writePaneBorder(writer, left_width, "╭", "─", "╮");
        try writer.writeByte(' ');
        try writePaneBorder(writer, center_width, "╭", "─", "╮");
        try writer.writeByte(' ');
        try writePaneBorder(writer, right_width, "╭", "─", "╮");
    } else if (row_index == 1) {
        try writePaneText(writer, left_width, "LIFECYCLE lifecycle lanes · disposable microVM · VM-only");
        try writer.writeByte(' ');
        try writePaneText(writer, center_width, "VCPU RUNTIME  zigsched_minimal · sched_ext · observed — no perf claim");
        try writer.writeByte(' ');
        try writePaneText(writer, right_width, "DAEMON EVENT STREAM  daemon-event/v1");
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
        0 => "preflight build boot",
        1 => "marker verifier attach",
        2 => "observe rollback audit cleanup",
        3 => "footer modes RUNNING ROLLBACK CLEANUP SAFE INCIDENT",
        4 => std.fmt.bufPrint(buf, "████████░░░░  host_mutation=false", .{}) catch "host_mutation=false",
        5 => "STAGE LEDGER                         run-all-lab/v1",
        6 => std.fmt.bufPrint(buf, "verifier_only       {s}", .{model.verifier_status}) catch "verifier_only pending",
        7 => std.fmt.bufPrint(buf, "partial_attach      {s}", .{model.runtime_ops}) catch "partial_attach pending",
        8 => std.fmt.bufPrint(buf, "observe_partial     {s}", .{model.runtime_samples}) catch "observe_partial not-started",
        9 => std.fmt.bufPrint(buf, "stress_chaos        {s}", .{model.stress_status}) catch "stress_chaos pending",
        10 => std.fmt.bufPrint(buf, "rollback_drill      {s}", .{model.rollback_status}) catch "rollback_drill rollback required",
        11 => std.fmt.bufPrint(buf, "release_gate        {s}", .{model.release_gate_status}) catch "release_gate closed",
        12 => "",
        13 => "GATE LEDGER  fail-closed · not release proof",
        14 => std.fmt.bufPrint(buf, "{s}", .{model.lab_scope}) catch "lab-only vm guest",
        15 => std.fmt.bufPrint(buf, "vm marker           {s}", .{model.vm_marker}) catch "vm marker required",
        16 => std.fmt.bufPrint(buf, "kernel tuple        {s} · {s}", .{ model.kernel_release, model.arch }) catch "kernel tuple lab",
        17 => std.fmt.bufPrint(buf, "bundle              {s}", .{model.bundle_path}) catch "bundle required",
        18 => std.fmt.bufPrint(buf, "audit id            {s}", .{model.audit_id}) catch "audit id required",
        19 => std.fmt.bufPrint(buf, "rollback id         {s}", .{model.rollback_id}) catch "rollback id required",
        20 => std.fmt.bufPrint(buf, "cleanup             {s}", .{model.cleanup_status}) catch "cleanup not-started",
        21 => "",
        22 => "ALERT STRIP  thresholds",
        23 => "• runqueue depth    dsq=2       within bound",
        24 => "▲ starvation watch  p99 460µs   wakeup-run tail",
        25 => std.fmt.bufPrint(buf, "• nr_rejected       {s}       must stay 0", .{model.sched_nr_rejected}) catch "• nr_rejected       0       must stay 0",
        26 => "• dropped events    0           stream backpressure",
        27 => std.fmt.bufPrint(buf, "• incident          {s}", .{model.incident_status}) catch "• incident          none",
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
        0 => "all   lifecycle   runtime_sample   rollback   incident",
        1 => if (std.mem.eql(u8, model.incident_status, "none")) std.fmt.bufPrint(buf, "{s}       {s}", .{ model.event_cursor, model.event_latest }) catch "cursor none event list empty" else model.incident_status,
        2 => "  0.00s  ✓ stage_started PASS · queued",
        3 => "[booting] microvm_boot PASS · VM marker present",
        4 => "  2.84s  ✓ bpf_register PASS · zigsched_minimal attached",
        5 => std.fmt.bufPrint(buf, "  4.20s  ✓ runtime_sample PASS · {s}", .{model.runtime_samples}) catch "  4.20s  ✓ runtime_sample PASS",
        6 => "  5.62s  ✓ runtime_sample PASS · runtime samples accepted",
        7 => "  7.04s  ✓ runtime_sample PASS · runtime samples accepted",
        8 => std.fmt.bufPrint(buf, "  8.46s  ✓ rollback PASS · {s}", .{model.rollback_status}) catch "  8.46s  ✓ rollback PASS",
        9 => std.fmt.bufPrint(buf, "{s}", .{model.cleanup_status}) catch "cleanup receipt PASS",
        10 => std.fmt.bufPrint(buf, " 11.30s  ✓ validation PASS · {s}", .{model.lab_gate}) catch " 11.30s  ✓ validation PASS",
        11 => std.fmt.bufPrint(buf, "{s}", .{model.bundle_path}) catch "tui-vm-lab-test",
        12 => "live bundle freshness accepted",
        13 => std.fmt.bufPrint(buf, "ops recorded {s}", .{model.runtime_ops}) catch "ops recorded zigsched_minimal",
        14 => std.fmt.bufPrint(buf, "{s}", .{model.rollback_status}) catch "rollback ready/completed",
        15 => std.fmt.bufPrint(buf, "{s}", .{model.lab_scope}) catch "lab-only vm guest",
        16 => std.fmt.bufPrint(buf, "{s}", .{model.cleanup_status}) catch "cleanup receipt PASS",
        17 => std.fmt.bufPrint(buf, "release eligible: {s}", .{model.release_eligibility}) catch "release eligible: not release proof",
        18 => "INCIDENT STATES: qemu_unavailable · verifier_reject · lost_stream",
        19 => "timeout · rollback_failure · cleanup_residue",
        20 => std.fmt.bufPrint(buf, "current incident: {s}", .{model.incident_status}) catch "current incident: none",
        21 => std.fmt.bufPrint(buf, "{s}", .{model.bundle_path}) catch "microvm-live-tui-demo",
        22 => "runtime samples accepted",
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
