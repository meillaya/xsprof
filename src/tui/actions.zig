const std = @import("std");
const dashboard = @import("dashboard_root");

pub const ActionId = enum {
    quit,
    help,
    back,
    home,
    move_up,
    move_down,
    next_focus,
    previous_focus,
    activate,
    scenario_details,
    timeline,
    observability,
    observability_comparison,
    performance,
    reports,
    play_pause,
    scrub_left,
    scrub_right,
    task_details,
    policy_compare,
    previous_policy,
    next_policy,
    theme,
};

pub const Action = struct {
    id: ActionId,
    screen: ?dashboard.Screen,
    keys: []const []const u8,
    label: []const u8,
    description: []const u8,
    visible: bool = true,
    hidden_reason: ?[]const u8 = null,
};

pub const all = [_]Action{
    .{ .id = .quit, .screen = null, .keys = &.{ "q", "ctrl-c" }, .label = "Quit", .description = "leave the terminal shell" },
    .{ .id = .help, .screen = null, .keys = &.{"?"}, .label = "Help", .description = "toggle keyboard help" },
    .{ .id = .back, .screen = null, .keys = &.{"esc"}, .label = "Back", .description = "close overlay, go back, or clear selection" },
    .{ .id = .home, .screen = null, .keys = &.{"h"}, .label = "Home", .description = "return to dashboard home" },
    .{ .id = .theme, .screen = null, .keys = &.{"w"}, .label = "Theme", .description = "toggle dark or light theme" },

    .{ .id = .move_up, .screen = .home, .keys = &.{ "up", "k" }, .label = "Select previous", .description = "move to the previous dashboard card" },
    .{ .id = .move_down, .screen = .home, .keys = &.{ "down", "j" }, .label = "Select next", .description = "move to the next dashboard card" },
    .{ .id = .activate, .screen = .home, .keys = &.{"enter"}, .label = "Open", .description = "activate selected scenario or dashboard card" },
    .{ .id = .scenario_details, .screen = .home, .keys = &.{"s"}, .label = "Scenario", .description = "open scenario/source details" },
    .{ .id = .timeline, .screen = .home, .keys = &.{"t"}, .label = "Timeline", .description = "open deterministic timeline replay" },
    .{ .id = .observability, .screen = .home, .keys = &.{"o"}, .label = "Observability", .description = "open offline observability summary" },
    .{ .id = .performance, .screen = .home, .keys = &.{"p"}, .label = "Performance", .description = "open performance status commands" },
    .{ .id = .reports, .screen = .home, .keys = &.{"r"}, .label = "Reports", .description = "open report artifact status commands" },
    .{ .id = .previous_policy, .screen = .home, .keys = &.{"["}, .label = "Previous policy", .description = "select previous policy preset for scenario cards" },
    .{ .id = .next_policy, .screen = .home, .keys = &.{"]"}, .label = "Next policy", .description = "select next policy preset for scenario cards" },

    .{ .id = .timeline, .screen = .scenario, .keys = &.{ "t", "enter" }, .label = "Timeline", .description = "open timeline for selected scenario" },
    .{ .id = .previous_policy, .screen = .scenario, .keys = &.{"["}, .label = "Previous policy", .description = "select previous policy preset" },
    .{ .id = .next_policy, .screen = .scenario, .keys = &.{"]"}, .label = "Next policy", .description = "select next policy preset" },

    .{ .id = .scrub_left, .screen = .timeline, .keys = &.{ "left", "home" }, .label = "Scrub back", .description = "move earlier in the trace" },
    .{ .id = .scrub_right, .screen = .timeline, .keys = &.{ "right", "end" }, .label = "Scrub forward", .description = "move later in the trace" },
    .{ .id = .move_up, .screen = .timeline, .keys = &.{ "up", "k" }, .label = "Previous task", .description = "select previous task" },
    .{ .id = .move_down, .screen = .timeline, .keys = &.{ "down", "j" }, .label = "Next task", .description = "select next task" },
    .{ .id = .next_focus, .screen = .timeline, .keys = &.{"tab"}, .label = "Next pane", .description = "cycle pane focus" },
    .{ .id = .previous_focus, .screen = .timeline, .keys = &.{"shift-tab"}, .label = "Previous pane", .description = "reverse pane focus" },
    .{ .id = .play_pause, .screen = .timeline, .keys = &.{"space"}, .label = "Play/Pause", .description = "toggle deterministic replay" },
    .{ .id = .task_details, .screen = .timeline, .keys = &.{"enter"}, .label = "Task/Core detail", .description = "open selected task/core details" },
    .{ .id = .policy_compare, .screen = .timeline, .keys = &.{"d"}, .label = "Policy compare", .description = "compare with paired policy run" },

    .{ .id = .timeline, .screen = .tasks_cores, .keys = &.{"t"}, .label = "Timeline", .description = "return to timeline" },
    .{ .id = .timeline, .screen = .policy_compare, .keys = &.{ "d", "t" }, .label = "Timeline", .description = "return to timeline" },
    .{ .id = .observability, .screen = .observability, .keys = &.{"o"}, .label = "Observability summary", .description = "show offline fixture summary" },
    .{ .id = .observability_comparison, .screen = .observability, .keys = &.{"c"}, .label = "Comparison", .description = "show simulator-to-fixture comparison" },
};

pub fn find(id: ActionId, screen: ?dashboard.Screen) ?Action {
    for (all) |action| {
        if (action.id == id and (action.screen == screen or action.screen == null)) return action;
    }
    return null;
}

pub fn actionForKey(screen: dashboard.Screen, key: []const u8) ?ActionId {
    for (all) |action| {
        if (action.screen != null and action.screen.? != screen) continue;
        for (action.keys) |candidate| {
            if (std.mem.eql(u8, candidate, key)) return action.id;
        }
    }
    for (all) |action| {
        if (action.screen != null) continue;
        for (action.keys) |candidate| {
            if (std.mem.eql(u8, candidate, key)) return action.id;
        }
    }
    return null;
}

pub fn statusHint(screen: dashboard.Screen, compact: bool) []const u8 {
    return switch (screen) {
        .home => if (compact) "↑↓ open  s/t/o/p/r  ? q" else "↑ ↓ select  ↵ open  s scenario  t timeline  o observability  p performance  r reports  [ ] policy  ? help  q quit",
        .scenario => "t/↵ timeline  [ ] policy  h home  ? help  q quit",
        .timeline => if (compact) "←→ tick  ↵ details  d compare  h home  ? q" else "← → scrub  ↑ ↓ task  tab pane  space play  ↵ detail  d compare  h home  ? help  q quit",
        .tasks_cores => "t timeline  esc back  h home  ? help  q quit",
        .policy_compare => "d/t timeline  h home  ? help  q quit",
        .observability => "o summary  c comparison  h home  ? help  q quit",
        .performance => "command status only  h home  ? help  q quit",
        .reports => "artifact status only  h home  ? help  q quit",
        .help => "? or esc close  h home  q quit",
    };
}

pub fn keySummary(action: Action, buffer: *[64]u8) []const u8 {
    var stream = std.Io.Writer.fixed(buffer);
    for (action.keys, 0..) |key, index| {
        if (index != 0) stream.writeAll(" / ") catch break;
        stream.writeAll(displayKey(key)) catch break;
    }
    return buffer[0..stream.end];
}

pub fn displayKey(key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "enter")) return "↵";
    if (std.mem.eql(u8, key, "esc")) return "esc";
    if (std.mem.eql(u8, key, "space")) return "space";
    if (std.mem.eql(u8, key, "left")) return "←";
    if (std.mem.eql(u8, key, "right")) return "→";
    if (std.mem.eql(u8, key, "up")) return "↑";
    if (std.mem.eql(u8, key, "down")) return "↓";
    if (std.mem.eql(u8, key, "ctrl-c")) return "ctrl-c";
    if (std.mem.eql(u8, key, "shift-tab")) return "shift-tab";
    return key;
}

pub fn hasDuplicateKeys() bool {
    for (all, 0..) |lhs, i| {
        for (all[i + 1 ..]) |rhs| {
            if (lhs.screen != rhs.screen) continue;
            for (lhs.keys) |lhs_key| {
                for (rhs.keys) |rhs_key| if (std.mem.eql(u8, lhs_key, rhs_key)) return true;
            }
        }
    }
    return false;
}

test "action registry has no duplicate active keys inside one screen scope" {
    try std.testing.expect(!hasDuplicateKeys());
}

test "dashboard navigation keys resolve through registry" {
    inline for (dashboard.navigation) |edge| {
        try std.testing.expect(actionForKey(edge.from, edge.key) != null);
    }
}

test "visible actions are registry-resolvable and display-ready" {
    for (all) |action| {
        if (!action.visible) continue;
        try std.testing.expect(action.keys.len != 0);
        try std.testing.expect(action.label.len != 0);
        try std.testing.expect(action.description.len != 0);
        for (action.keys) |key| {
            try std.testing.expect(key.len != 0);
            if (action.screen) |screen| {
                try std.testing.expectEqual(action.id, actionForKey(screen, key).?);
            } else {
                try std.testing.expectEqual(action.id, actionForKey(.home, key).?);
            }
        }
        var buffer: [64]u8 = undefined;
        try std.testing.expect(keySummary(action, &buffer).len != 0);
    }
}

test "every dashboard screen has a status hint and registered action path" {
    inline for (dashboard.screens) |screen_spec| {
        try std.testing.expect(statusHint(screen_spec.screen, false).len != 0);
        try std.testing.expect(statusHint(screen_spec.screen, true).len != 0);
        var has_action = actionForKey(screen_spec.screen, "q") != null;
        for (all) |action| {
            if (action.screen != null and action.screen.? == screen_spec.screen) has_action = true;
        }
        try std.testing.expect(has_action);
    }
}
