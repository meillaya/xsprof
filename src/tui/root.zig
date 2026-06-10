const std = @import("std");
const linux = @import("linux_scheduler");

pub const Screen = enum { preflight, sched_ext, controller, observer, help };
pub const Options = struct {
    snapshot: bool = false,
    screen: Screen = .preflight,
    width: u16 = 100,
    height: u16 = 30,
};

pub fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--snapshot")) {
            options.snapshot = true;
        } else if (std.mem.eql(u8, arg, "--screen")) {
            options.screen = try parseScreen(try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--width")) {
            options.width = try parseDimension(try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--height")) {
            options.height = try parseDimension(try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--help")) {
            return error.InvalidArguments;
        } else {
            return error.InvalidArguments;
        }
    }
    if (!options.snapshot) return error.InvalidArguments;
    if (options.width < 80 or options.height < 8) return error.InvalidArguments;
    return options;
}

pub fn renderSnapshot(allocator: std.mem.Allocator, options: Options) ![]u8 {
    var report = try linux.collectPreflight(allocator);
    defer report.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);

    const width = @max(options.width, 80);
    try line(&writer.writer, width, "╭", "─", "╮");
    try row(&writer.writer, width, "▚ Linux Scheduler Operator", screenTitle(options.screen), "SNAPSHOT read-only");
    try line(&writer.writer, width, "├", "─", "┤");
    switch (options.screen) {
        .preflight => try renderPreflight(&writer.writer, width, report),
        .sched_ext => try renderSchedExt(&writer.writer, width, report),
        .controller => try renderController(&writer.writer, width),
        .observer => try renderObserver(&writer.writer, width),
        .help => try renderHelp(&writer.writer, width),
    }
    while (countRows(writer.writer.buffered()) + 3 < options.height) {
        try row(&writer.writer, width, "", "", "");
    }
    try line(&writer.writer, width, "├", "─", "┤");
    try row(&writer.writer, width, "q quit  ? help  h home  w theme", "FAIL-CLOSED", "refuse mutation/load");
    try line(&writer.writer, width, "╰", "─", "╯");
    out = writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

pub fn writeUsage(writer: anytype, exe_name: []const u8) !void {
    try writer.print("usage: {s} --snapshot --screen preflight|sched-ext [--width <cols>] [--height <rows>]\n", .{exe_name});
}

fn renderPreflight(writer: anytype, width: usize, report: linux.PreflightReport) !void {
    try section(writer, width, "Host Preflight", "Safety Gate");
    try row(writer, width, "kernel tuple", report.kernel_release, "read-only opens only");
    try row(writer, width, "arch", report.arch, "no cgroup writes");
    try row(writer, width, "cgroup v2", @tagName(report.cgroup_v2.status), "no affinity/scheduler writes");
    try row(writer, width, "controllers", report.cgroup_v2.controllers, "no BPF load path");
    try row(writer, width, "capabilities", report.capabilities.effective_hex, "refuse unsafe verbs");
    try row(writer, width, "sched_ext", factText(report.sched_ext.state), "lab gate required later");
    try row(writer, width, "BTF", @tagName(report.btf.status), "lab gate required later");
    try section(writer, width, "Read-only Probe Matrix", "Mutation Refusals");
    try row(writer, width, "/sys/kernel/sched_ext/state", @tagName(report.sched_ext.state.status), "load: refused");
    try row(writer, width, "enable_seq", factText(report.sched_ext.enable_seq), "attach: refused");
    try row(writer, width, "switch_all", factText(report.sched_ext.switch_all), "enable: refused");
    try row(writer, width, "nr_rejected", factText(report.sched_ext.nr_rejected), "mutate: refused");
    try row(writer, width, "/sys/kernel/btf/vmlinux", @tagName(report.btf.status), "apply: refused");
    try section(writer, width, "Operator Checklist", "Evidence Channel");
    try row(writer, width, "lab tuple", "required later", "tmux transcript");
    try row(writer, width, "rollback id", "required before writes", "audit id required");
    try row(writer, width, "fallback drill", "required before load", "partial switch first");
    try row(writer, width, "toolchain", "informational", "no compile/load here");
    try row(writer, width, "kernel config", "unsafe_to_assume if hidden", "do not infer support");
    try row(writer, width, "observer", "preflight only", "no fidelity claim");
    try row(writer, width, "decision", "closed", "operator approval missing");
    try row(writer, width, "mode", "read-only", "FAIL-CLOSED");
}

fn renderSchedExt(writer: anytype, width: usize, report: linux.PreflightReport) !void {
    try section(writer, width, "sched_ext Readiness", "Fallback Drill");
    try row(writer, width, "state", factText(report.sched_ext.state), "partial switch first");
    try row(writer, width, "enable_seq", factText(report.sched_ext.enable_seq), "fallback command recorded");
    try row(writer, width, "switch_all", factText(report.sched_ext.switch_all), "verifier failure plan");
    try row(writer, width, "nr_rejected", factText(report.sched_ext.nr_rejected), "DSQ plan required");
    try row(writer, width, "BTF", @tagName(report.btf.status), "no load before approval");
    try row(writer, width, "gate", "closed", "fallback: refuse live mutation");
    try section(writer, width, "Gate Ledger", "No-load Contract");
    try row(writer, width, "approved lab", "missing", "load command absent");
    try row(writer, width, "kernel tuple", report.kernel_release, "attach command absent");
    try row(writer, width, "CONFIG_SCHED_CLASS_EXT", "not assumed", "enable command absent");
    try row(writer, width, "BPF support", "not assumed", "mutate command absent");
    try row(writer, width, "BTF support", @tagName(report.btf.status), "apply command absent");
    try section(writer, width, "Dispatch Queue Plan", "Verifier Plan");
    try row(writer, width, "DSQ mapping", "design gate pending", "capture verifier log");
    try row(writer, width, "partial switch", "required", "reject on verifier fail");
    try row(writer, width, "fallback", "drill required", "auto-unload documented");
    try row(writer, width, "scope", "disposable VM", "production refused");
    try row(writer, width, "operator", "explicit approval", "audit id required");
    try row(writer, width, "controller", "dry-run only", "rollback snapshot");
    try row(writer, width, "observer", "read-only", "no replay authority");
    try row(writer, width, "decision", "closed", "FAIL-CLOSED");
}

fn renderController(writer: anytype, width: usize) !void {
    try section(writer, width, "Controller Dry Run", "Refusal Reasons");
    try row(writer, width, "plan", "preview only", "lab gate missing");
    try row(writer, width, "audit id", "required", "rollback id missing");
    try row(writer, width, "allowlist", "required", "operator confirm missing");
}

fn renderObserver(writer: anytype, width: usize) !void {
    try section(writer, width, "Observer", "Caveats");
    try row(writer, width, "live observer", "preflight only", "no simulator fidelity claims");
    try row(writer, width, "offline fixtures", "descriptive", "no Linux performance claims");
}

fn renderHelp(writer: anytype, width: usize) !void {
    try section(writer, width, "Help", "Keys");
    try row(writer, width, "model", "fail-closed", "q/ctrl-c quit");
    try row(writer, width, "scope", "lab gated", "? help, h home, w theme");
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

fn section(writer: anytype, width: usize, left: []const u8, right: []const u8) !void {
    try row(writer, width, left, "", right);
}

fn row(writer: anytype, width: usize, left: []const u8, middle: []const u8, right: []const u8) !void {
    try writer.writeAll("│ ");
    try writeCell(writer, left, 34);
    try writer.writeAll(" │ ");
    try writeCell(writer, middle, 24);
    try writer.writeAll(" │ ");
    const used: usize = 2 + 34 + 3 + 24 + 3;
    const right_width = if (width > used + 2) width - used - 2 else 12;
    try writeCell(writer, right, right_width);
    try writer.writeAll(" │\n");
}

fn line(writer: anytype, width: usize, left: []const u8, fill: []const u8, right: []const u8) !void {
    try writer.writeAll(left);
    var col: usize = 2;
    while (col < width) : (col += 1) try writer.writeAll(fill);
    try writer.writeAll(right);
    try writer.writeByte('\n');
}
fn writeCell(writer: anytype, text: []const u8, width: usize) !void {
    const clipped = if (text.len > width) text[0..width] else text;
    try writer.writeAll(clipped);
    var cells = displayCells(clipped);
    while (cells < width) : (cells += 1) try writer.writeByte(' ');
}

fn displayCells(text: []const u8) usize {
    var cells: usize = 0;
    for (text) |byte| {
        if ((byte & 0b1100_0000) != 0b1000_0000) cells += 1;
    }
    return cells;
}

fn countRows(bytes: []const u8) usize {
    var rows: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') rows += 1;
    }
    return rows;
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
