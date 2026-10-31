//! Theme presets and token overrides. The default dark palette is the
//! `xsprof` console palette; `light` preserves the exact paper colors the
//! native surfaces and the snapshot CLI already used. `high_contrast` is an
//! accessibility preset with stronger foreground separation.
//!
//! Extension: `Overrides` and `derive` let a host rebrand a preset without
//! copying the full token set.

const std = @import("std");
const draw = @import("draw.zig");

pub const Theme = draw.Theme;
pub const Color = draw.Color;

pub const dark: Theme = .{};

pub const light: Theme = .{
    .bg = .{ .r = 0xf3, .g = 0xea, .b = 0xd7 },
    .panel = .{ .r = 0xff, .g = 0xf8, .b = 0xeb },
    .raised = .{ .r = 0xe9, .g = 0xdf, .b = 0xcb },
    .text = .{ .r = 0x1a, .g = 0x17, .b = 0x12 },
    .muted = .{ .r = 0x6b, .g = 0x5f, .b = 0x51 },
    .hairline = .{ .r = 0xc9, .g = 0xba, .b = 0xa2 },
};

pub const high_contrast: Theme = .{
    .bg = .{ .r = 0x00, .g = 0x00, .b = 0x00 },
    .panel = .{ .r = 0x0a, .g = 0x0a, .b = 0x0a },
    .raised = .{ .r = 0x1a, .g = 0x1a, .b = 0x1a },
    .text = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    .muted = .{ .r = 0xc8, .g = 0xc8, .b = 0xc8 },
    .hairline = .{ .r = 0x66, .g = 0x66, .b = 0x66 },
    .live = .{ .r = 0x00, .g = 0xe5, .b = 0xff },
    .pass = .{ .r = 0x00, .g = 0xff, .b = 0x7f },
    .skip = .{ .r = 0xff, .g = 0xd4, .b = 0x00 },
    .refuse = .{ .r = 0xff, .g = 0x4d, .b = 0x6d },
    .pending = .{ .r = 0xf2, .g = 0xf2, .b = 0xf2 },
    .vm = .{ .r = 0xc9, .g = 0xa7, .b = 0xff },
};

/// Resolves the CLI/surface theme names. Unknown names return `null` so the
/// caller can keep its historical default instead of failing a snapshot.
pub fn named(name: []const u8) ?Theme {
    if (std.mem.eql(u8, name, "dark") or std.mem.eql(u8, name, "warm-dark")) return dark;
    if (std.mem.eql(u8, name, "light") or std.mem.eql(u8, name, "paper")) return light;
    if (std.mem.eql(u8, name, "high-contrast") or std.mem.eql(u8, name, "contrast")) {
        return high_contrast;
    }
    return null;
}

pub const Overrides = struct {
    bg: ?Color = null,
    panel: ?Color = null,
    raised: ?Color = null,
    text: ?Color = null,
    muted: ?Color = null,
    hairline: ?Color = null,
    live: ?Color = null,
    pass: ?Color = null,
    skip: ?Color = null,
    refuse: ?Color = null,
    pending: ?Color = null,
    vm: ?Color = null,
};

/// Applies only the non-null tokens, leaving every other role untouched.
pub fn derive(base: Theme, overrides: Overrides) Theme {
    var theme = base;
    if (overrides.bg) |value| theme.bg = value;
    if (overrides.panel) |value| theme.panel = value;
    if (overrides.raised) |value| theme.raised = value;
    if (overrides.text) |value| theme.text = value;
    if (overrides.muted) |value| theme.muted = value;
    if (overrides.hairline) |value| theme.hairline = value;
    if (overrides.live) |value| theme.live = value;
    if (overrides.pass) |value| theme.pass = value;
    if (overrides.skip) |value| theme.skip = value;
    if (overrides.refuse) |value| theme.refuse = value;
    if (overrides.pending) |value| theme.pending = value;
    if (overrides.vm) |value| theme.vm = value;
    return theme;
}

test "named presets resolve and stay distinct" {
    try std.testing.expectEqualDeep(dark, named("dark").?);
    try std.testing.expectEqualDeep(light, named("light").?);
    try std.testing.expectEqualDeep(high_contrast, named("high-contrast").?);
    try std.testing.expect(named("nope") == null);
    try std.testing.expect(light.bg.r != dark.bg.r);
    try std.testing.expect(high_contrast.text.r == 0xff);
    try std.testing.expect(high_contrast.bg.r == 0x00);
}

test "derive overrides only the requested tokens" {
    const custom = derive(light, .{
        .bg = .{ .r = 1, .g = 2, .b = 3 },
        .live = .{ .r = 9, .g = 8, .b = 7 },
    });
    try std.testing.expectEqual(@as(u8, 1), custom.bg.r);
    try std.testing.expectEqual(@as(u8, 9), custom.live.r);
    try std.testing.expectEqualDeep(light.panel, custom.panel);
    try std.testing.expectEqualDeep(light.text, custom.text);
}
