//! Top-level routes for the product shell. The five analysis screens keep
//! their historical enum backing (0..4) so existing surfaces, snapshot
//! selectors, and rail ids 100..104 are unchanged. Home/Audit/Settings are
//! appended as 5..7 -> rail ids 105..107.

const std = @import("std");

pub const Route = enum {
    overview,
    timeline,
    advisor,
    events,
    capture,
    home,
    audit,
    settings,

    pub fn name(self: Route) []const u8 {
        return switch (self) {
            .overview => "Overview",
            .timeline => "Timeline",
            .advisor => "Advisor",
            .events => "Events",
            .capture => "Recorder",
            .home => "Home",
            .audit => "Audit",
            .settings => "Settings",
        };
    }

    pub fn railId(self: Route) u32 {
        return 100 + @as(u32, @backingInt(self));
    }

    pub fn key(self: Route) []const u8 {
        return switch (self) {
            .home => "0",
            .overview => "1",
            .timeline => "2",
            .advisor => "3",
            .events => "4",
            .capture => "5",
            .audit => "6",
            .settings => "7",
        };
    }

    pub fn isAnalysis(self: Route) bool {
        return @as(u32, @backingInt(self)) <= 4;
    }

    /// True when the route exists only in the product-shell v2 contract.
    pub fn isExtension(self: Route) bool {
        return !self.isAnalysis();
    }
};

/// Display order in the rail: Home first, analysis screens in their historical
/// order, then Audit and Settings.
pub const order = [_]Route{
    .home,
    .overview,
    .timeline,
    .advisor,
    .events,
    .capture,
    .audit,
    .settings,
};

pub const analysis = [_]Route{ .overview, .timeline, .advisor, .events, .capture };

pub fn screenName(route: Route) []const u8 {
    return route.name();
}

pub fn parse(name: []const u8) ?Route {
    inline for (@typeInfo(Route).@"enum".field_names) |field| {
        if (std.ascii.eqlIgnoreCase(name, field)) return @field(Route, field);
    }
    if (std.ascii.eqlIgnoreCase(name, "recorder")) return .capture;
    return null;
}

pub fn fromRailId(id: u32) ?Route {
    if (id < 100 or id > 107) return null;
    return @fromBackingInt(@intCast(id - 100));
}

pub fn fromKey(codepoint: u21) ?Route {
    return switch (codepoint) {
        '0' => .home,
        '1' => .overview,
        '2' => .timeline,
        '3' => .advisor,
        '4' => .events,
        '5' => .capture,
        '6' => .audit,
        '7' => .settings,
        else => null,
    };
}

pub fn indexInOrder(route: Route) usize {
    for (order, 0..) |item, i| {
        if (item == route) return i;
    }
    return 0;
}

test "analysis backing ints stay stable" {
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @backingInt(Route.overview)));
    try std.testing.expectEqual(@as(u32, 4), @as(u32, @backingInt(Route.capture)));
    try std.testing.expectEqual(@as(u32, 5), @as(u32, @backingInt(Route.home)));
    try std.testing.expectEqual(@as(u32, 105), Route.home.railId());
    try std.testing.expectEqual(@as(u32, 106), Route.audit.railId());
    try std.testing.expectEqual(@as(u32, 107), Route.settings.railId());
    try std.testing.expectEqual(@as(?Route, .home), fromRailId(105));
    try std.testing.expectEqual(@as(?Route, .events), fromRailId(103));
    try std.testing.expect(fromRailId(108) == null);
}

test "route parsing keeps legacy names" {
    try std.testing.expectEqual(@as(?Route, .overview), parse("overview"));
    try std.testing.expectEqual(@as(?Route, .capture), parse("Recorder"));
    try std.testing.expectEqual(@as(?Route, .settings), parse("SETTINGS"));
    try std.testing.expect(parse("nope") == null);
    try std.testing.expectEqual(@as(?Route, .home), fromKey('0'));
    try std.testing.expect(fromKey('8') == null);
}
