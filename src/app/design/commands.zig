//! The command palette catalog. Kept separate from rendering/input so the
//! palette, key handling, and tests agree on one list. Every entry dispatches
//! through action.Action -> dispatch.zig (one code path for keys/clicks/palette).

const std = @import("std");
const action_mod = @import("action.zig");

pub const Action = action_mod.Action;

pub const Command = struct {
    group: []const u8,
    label: []const u8,
    key: []const u8 = "",
    action: Action,
};

pub const all = [_]Command{
    // Navigation (analysis ids/keys stay 1..5; 0/6/7 are v2 extensions).
    .{ .group = "go", .label = "Overview", .key = "1", .action = .{ .nav = .overview } },
    .{ .group = "go", .label = "Timeline", .key = "2", .action = .{ .nav = .timeline } },
    .{ .group = "go", .label = "Advisor", .key = "3", .action = .{ .nav = .advisor } },
    .{ .group = "go", .label = "Events", .key = "4", .action = .{ .nav = .events } },
    .{ .group = "go", .label = "Recorder", .key = "5", .action = .{ .nav = .capture } },
    .{ .group = "go", .label = "Home / sources", .key = "0", .action = .{ .nav = .home } },
    .{ .group = "go", .label = "Audit", .key = "6", .action = .{ .nav = .audit } },
    .{ .group = "go", .label = "Settings", .key = "7", .action = .{ .nav = .settings } },
    // Source selection.
    .{ .group = "source", .label = "Open replay journal…", .action = .{ .source_select = .replay } },
    .{ .group = "source", .label = "Open recorder window…", .action = .{ .source_select = .recorder_window } },
    .{ .group = "source", .label = "Load bundled capture", .action = .{ .source_select = .demo } },
    .{ .group = "source", .label = "Start live capture", .action = .{ .source_select = .live } },
    .{ .group = "source", .label = "Reload current source", .action = .reload_source },
    // Recorder management.
    .{ .group = "recorder", .label = "Start capture", .action = .{ .recorder = .start } },
    .{ .group = "recorder", .label = "Stop capture", .action = .{ .recorder = .stop } },
    .{ .group = "recorder", .label = "Restart capture", .action = .{ .recorder = .restart } },
    .{ .group = "recorder", .label = "Extract window", .action = .{ .recorder = .extract } },
    .{ .group = "recorder", .label = "Export journal", .action = .{ .export_file = .journal } },
    .{ .group = "recorder", .label = "Export Chrome trace", .action = .{ .export_file = .trace } },
    .{ .group = "recorder", .label = "Export report", .action = .{ .export_file = .report } },
    .{ .group = "recorder", .label = "Bundle incident", .action = .{ .export_file = .incident } },
    // Appearance / settings.
    .{ .group = "action", .label = "Open appearance menu", .key = "w", .action = .open_appearance },
    .{ .group = "action", .label = "Toggle reduced motion", .action = .{ .settings_toggle = .reduced_motion } },
    .{ .group = "action", .label = "Toggle capture controls", .action = .{ .settings_toggle = .capture_enabled } },
    .{ .group = "action", .label = "Fit timeline to excerpt", .key = "f", .action = .fit },
    .{ .group = "action", .label = "Filter events by task", .key = "/", .action = .filter_events },
    .{ .group = "action", .label = "Copy selection summary", .key = "c", .action = .copy_selection },
    .{ .group = "action", .label = "Keyboard help", .key = "?", .action = .open_help },
    .{ .group = "action", .label = "Show onboarding", .action = .onboarding_next },
    // Themes (exactly six, matching the token contract).
    .{ .group = "theme", .label = "Theme: Graphite (default)", .action = .{ .theme = 0 } },
    .{ .group = "theme", .label = "Theme: Paper", .action = .{ .theme = 1 } },
    .{ .group = "theme", .label = "Theme: Catppuccin Latte", .action = .{ .theme = 2 } },
    .{ .group = "theme", .label = "Theme: Catppuccin Frappe", .action = .{ .theme = 3 } },
    .{ .group = "theme", .label = "Theme: Catppuccin Macchiato", .action = .{ .theme = 4 } },
    .{ .group = "theme", .label = "Theme: Catppuccin Mocha", .action = .{ .theme = 5 } },
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
    try std.testing.expectEqual(@as(usize, 8), count("go"));
    try std.testing.expect(all.len <= 40);
}
