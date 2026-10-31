//! Shared console state. Screens only read this; input handling updates it.

const std = @import("std");

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

pub const Dialog = enum { none, palette, appearance, help };

pub const AdvisorFilter = enum { all, warning, info, clear, skip };

pub const State = struct {
    screen: Screen = .overview,
    theme_index: usize = 0,
    dialog: Dialog = .none,
    scroll_y: f32 = 0,
    hover: ?u32 = null,
    focus: u32 = 0,
    toast: ?[]const u8 = null,
    toast_error: bool = false,
    now_ms: u64 = 0,

    timeline_start: f64 = 0,
    timeline_end: f64 = 0,
    timeline_playhead: f64 = 0,
    timeline_playing: bool = false,
    selected_slice: ?u32 = null,
    selected_event: ?usize = null,
    advisor_filter: AdvisorFilter = .all,
    events_query: []const u8 = "",
    events_query_buf: [128]u8 = undefined,
    events_query_len: usize = 0,
    events_filter_focused: bool = false,
    events_type: []const u8 = "all",
    events_selected: ?usize = null,

    palette_query_buf: [64]u8 = undefined,
    palette_query_len: usize = 0,
    palette_index: usize = 0,
    toast_until_ms: u64 = 0,

    pub fn viewStart(self: *const State, window_ms: f64) f64 {
        _ = window_ms;
        return if (self.timeline_end > self.timeline_start) self.timeline_start else 0;
    }

    pub fn viewEnd(self: *const State, window_ms: f64) f64 {
        return if (self.timeline_end > self.timeline_start) self.timeline_end else window_ms;
    }

    pub fn paletteQuery(self: *const State) []const u8 {
        return self.palette_query_buf[0..self.palette_query_len];
    }
};
