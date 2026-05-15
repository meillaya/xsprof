const std = @import("std");
const list_writer = @import("list_writer");

pub const contract_name = "zig-scheduler/smart-dashboard-spine";
pub const contract_version: u32 = 1;
pub const ad_hoc_tui_modes_forbidden = true;

pub const Screen = enum {
    home,
    scenario,
    timeline,
    tasks_cores,
    policy_compare,
    observability,
    performance,
    reports,
    help,

    pub fn label(self: Screen) []const u8 {
        return switch (self) {
            .home => "Home",
            .scenario => "Scenario",
            .timeline => "Timeline",
            .tasks_cores => "Tasks/Cores",
            .policy_compare => "Policy Compare",
            .observability => "Observability",
            .performance => "Performance",
            .reports => "Reports",
            .help => "Help",
        };
    }
};

pub const ScreenSpec = struct {
    area: []const u8,
    screen: Screen,
    purpose: []const u8,
    primary_artifact: []const u8,
};

pub const screens = [_]ScreenSpec{
    .{ .area = "dashboard home", .screen = .home, .purpose = "one smart dashboard shell, scenario launcher, status summary", .primary_artifact = "src/dashboard/root.zig" },
    .{ .area = "dashboard scenario", .screen = .scenario, .purpose = "scenario metadata, parser mode, fixture provenance, drilldown entry", .primary_artifact = "src/sim/scenario.zig" },
    .{ .area = "dashboard timeline", .screen = .timeline, .purpose = "trace timeline, tick scrubber, deterministic snapshot replay", .primary_artifact = "src/tui/render.zig" },
    .{ .area = "dashboard tasks", .screen = .tasks_cores, .purpose = "task table, core lanes, runqueue and affinity drilldowns", .primary_artifact = "src/semantics/root.zig" },
    .{ .area = "policy compare", .screen = .policy_compare, .purpose = "side-by-side policy comparison and decision deltas", .primary_artifact = "src/tui/render.zig" },
    .{ .area = "observability screen", .screen = .observability, .purpose = "offline fixture calibration and simulator-to-observability caveats", .primary_artifact = "src/observability/root.zig" },
    .{ .area = "performance screen", .screen = .performance, .purpose = "performance lab budgets, benchmark status, reproducible perf gate", .primary_artifact = "src/perf/root.zig" },
    .{ .area = "reports/help", .screen = .reports, .purpose = "report artifact index, generated pack status, export contract links", .primary_artifact = "src/report_pipeline/root.zig" },
    .{ .area = "reports/help", .screen = .help, .purpose = "keyboard help, screen glossary, ADR guardrails", .primary_artifact = "docs/smart-dashboard-spine.md" },
};

pub const NavigationEdge = struct {
    from: Screen,
    to: Screen,
    key: []const u8,
    reason: []const u8,
};

pub const navigation = [_]NavigationEdge{
    .{ .from = .home, .to = .scenario, .key = "enter", .reason = "open selected scenario" },
    .{ .from = .scenario, .to = .timeline, .key = "t", .reason = "inspect trace timeline" },
    .{ .from = .timeline, .to = .tasks_cores, .key = "tab", .reason = "drill into task/core details" },
    .{ .from = .timeline, .to = .policy_compare, .key = "d", .reason = "compare active policy against paired run" },
    .{ .from = .home, .to = .observability, .key = "o", .reason = "open offline observability lane" },
    .{ .from = .home, .to = .performance, .key = "p", .reason = "open performance lab" },
    .{ .from = .home, .to = .reports, .key = "r", .reason = "open generated report pack status" },
    .{ .from = .home, .to = .help, .key = "?", .reason = "show dashboard help" },
};

pub fn containsScreen(screen: Screen) bool {
    for (screens) |spec| if (spec.screen == screen) return true;
    return false;
}

pub fn screenIndex(screen: Screen) ?usize {
    for (screens, 0..) |spec, index| if (spec.screen == screen) return index;
    return null;
}

pub fn renderMarkdown(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = list_writer.writer(&out, allocator);
    try writer.print("# smart dashboard spine v{d}\n\n", .{contract_version});
    try writer.print("Contract: `{s}`\n\n", .{contract_name});
    try writer.writeAll("ADR 0003 boundary: simulator-lab dashboard only; no daemon, service, agent, or production runtime. New ad hoc TUI modes are forbidden after dashboard home.\n\n");
    try writer.writeAll("| area | screen | purpose | artifact |\n| --- | --- | --- | --- |\n");
    for (screens) |spec| {
        try writer.print("| {s} | {s} | {s} | `{s}` |\n", .{ spec.area, spec.screen.label(), spec.purpose, spec.primary_artifact });
    }
    try writer.writeAll("\n## Navigation\n\n| from | key | to | reason |\n| --- | --- | --- | --- |\n");
    for (navigation) |edge| {
        try writer.print("| {s} | `{s}` | {s} | {s} |\n", .{ edge.from.label(), edge.key, edge.to.label(), edge.reason });
    }
    return try out.toOwnedSlice(allocator);
}

test "dashboard spine enumerates the one smart shell screens" {
    try std.testing.expect(ad_hoc_tui_modes_forbidden);
    inline for (.{ Screen.home, Screen.scenario, Screen.timeline, Screen.tasks_cores, Screen.policy_compare, Screen.observability, Screen.performance, Screen.reports, Screen.help }) |screen| {
        try std.testing.expect(containsScreen(screen));
        try std.testing.expect(screenIndex(screen) != null);
    }
}

test "dashboard markdown includes ADR guardrail and navigation" {
    const allocator = std.testing.allocator;
    const rendered = try renderMarkdown(allocator);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "smart dashboard spine") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "New ad hoc TUI modes are forbidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Performance") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Reports") != null);
}
