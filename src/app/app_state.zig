//! Shared app state and the event-ledger view geometry. Kept separate from
//! `app.zig` so the ledger painter and filter logic can grow without pushing
//! the main view over the repository line limit.

const std = @import("std");
const layout = @import("../ui/layout.zig");
const session_mod = @import("../stream/session.zig");
const filter_mod = @import("filter.zig");

pub const Screen = enum { overview, timeline, advisor, events, capture };

pub fn screenName(screen: Screen) []const u8 {
    return switch (screen) {
        .overview => "Overview",
        .timeline => "Timeline",
        .advisor => "Advisor",
        .events => "Events",
        .capture => "Capture",
    };
}

pub fn parseScreen(name: []const u8) ?Screen {
    inline for (@typeInfo(Screen).@"enum".field_names) |field| {
        if (std.ascii.eqlIgnoreCase(name, field)) return @field(Screen, field);
    }
    return null;
}

pub const Window = struct {
    start_us: u64,
    end_us: u64,
};

pub const Selection = struct {
    pid: i32,
    comm: []const u8,
};

pub const TimelineGeometry = struct {
    plot: layout.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    start_us: u64 = 0,
    end_us: u64 = 0,
    lane_h: f32 = 0,
    cpu_count: u8 = 0,
    valid: bool = false,
};

pub const max_visible_events = 256;

pub const EventsState = struct {
    session: *const session_mod.Session = undefined,
    filter: *const filter_mod.Filter = undefined,
    scroll: usize = 0,
    rect: layout.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    visible: usize = 0,
    start: usize = 0,
    match_total: usize = 0,
    visible_indices: [max_visible_events]usize = @splat(0),
    visible_count: usize = 0,

    pub fn clickedIndex(self: *const EventsState, row: usize) ?usize {
        if (row >= self.visible_count) return null;
        return self.visible_indices[row];
    }
};

pub const State = struct {
    session: *const session_mod.Session,
    screen: Screen = .overview,
    window: ?Window = null,
    selection: ?Selection = null,
    filter: filter_mod.Filter = .{},
    timeline: TimelineGeometry = .{},
    live_paused: bool = false,
    live_follow: bool = true,
    events: EventsState = .{},
};
