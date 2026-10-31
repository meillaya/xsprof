//! The command palette catalog. Kept separate from rendering/input so the
//! palette, key handling, and tests agree on one list.

const std = @import("std");
const state_mod = @import("state.zig");

pub const Action = union(enum) {
    screen: state_mod.Screen,
    open_journal,
    reload,
    fit,
    appearance,
    theme: usize,
    filter_events,
    help,
};

pub const Command = struct {
    group: []const u8,
    label: []const u8,
    key: []const u8 = "",
    action: Action,
};

pub const all = [_]Command{
    .{ .group = "screen", .label = "Overview", .key = "1", .action = .{ .screen = .overview } },
    .{ .group = "screen", .label = "Timeline", .key = "2", .action = .{ .screen = .timeline } },
    .{ .group = "screen", .label = "Advisor", .key = "3", .action = .{ .screen = .advisor } },
    .{ .group = "screen", .label = "Events", .key = "4", .action = .{ .screen = .events } },
    .{ .group = "screen", .label = "Capture status", .key = "5", .action = .{ .screen = .capture } },
    .{ .group = "action", .label = "Open journal…", .action = .open_journal },
    .{ .group = "action", .label = "Reload healthy fixture", .action = .reload },
    .{ .group = "action", .label = "Fit timeline to excerpt", .key = "f", .action = .fit },
    .{ .group = "action", .label = "Open appearance menu", .key = "w", .action = .appearance },
    .{ .group = "theme", .label = "Theme: Graphite (default)", .action = .{ .theme = 0 } },
    .{ .group = "theme", .label = "Theme: Paper", .action = .{ .theme = 1 } },
    .{ .group = "theme", .label = "Theme: Catppuccin Latte", .action = .{ .theme = 2 } },
    .{ .group = "theme", .label = "Theme: Catppuccin Frappe", .action = .{ .theme = 3 } },
    .{ .group = "theme", .label = "Theme: Catppuccin Macchiato", .action = .{ .theme = 4 } },
    .{ .group = "theme", .label = "Theme: Catppuccin Mocha", .action = .{ .theme = 5 } },
    .{ .group = "action", .label = "Filter events by task", .key = "/", .action = .filter_events },
    .{ .group = "action", .label = "Keyboard help", .key = "?", .action = .help },
};

pub fn matches(command: Command, query: []const u8) bool {
    if (query.len == 0) return true;
    var lower: [128]u8 = undefined;
    const n = @min(query.len, lower.len);
    for (query[0..n], 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const q = lower[0..n];
    var label_lower: [128]u8 = undefined;
    const ln = @min(command.label.len, label_lower.len);
    for (command.label[0..ln], 0..) |c, i| label_lower[i] = std.ascii.toLower(c);
    if (std.mem.indexOf(u8, label_lower[0..ln], q) != null) return true;
    var group_lower: [16]u8 = undefined;
    const gn = @min(command.group.len, group_lower.len);
    for (command.group[0..gn], 0..) |c, i| group_lower[i] = std.ascii.toLower(c);
    return std.mem.indexOf(u8, group_lower[0..gn], q) != null;
}

pub fn count(query: []const u8) usize {
    var n: usize = 0;
    for (all) |command| {
        if (matches(command, query)) n += 1;
    }
    return n;
}

pub fn nth(query: []const u8, wanted: usize) ?Command {
    var n: usize = 0;
    for (all) |command| {
        if (!matches(command, query)) continue;
        if (n == wanted) return command;
        n += 1;
    }
    return null;
}

test "palette filters and selects deterministically" {
    try std.testing.expectEqual(all.len, count(""));
    try std.testing.expect(count("theme") == 6);
    try std.testing.expectEqualStrings("Overview", nth("", 0).?.label);
    try std.testing.expectEqualStrings("Keyboard help", nth("keyb", 0).?.label);
}
