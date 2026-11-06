//! Shared console state. Screens only read this; the reducer in dispatch.zig
//! and the input/click adapters are the only writers.
//!
//! The five analysis screens keep their historical ids/keys; Home, Audit and
//! Settings are product-shell v2 extensions. Sub-state for source selection,
//! recorder management, the GPU picker, settings, audit, onboarding and text
//! entry lives in dedicated modules and is embedded here so the view signature
//! stays stable for every surface.

const std = @import("std");
const route = @import("route.zig");
const source = @import("source.zig");
const recorder = @import("recorder.zig");
const picker = @import("picker.zig");
const settings = @import("settings.zig");
const audit = @import("audit.zig");
const onboarding = @import("onboarding.zig");
const text_input = @import("text_input.zig");

/// Historical name kept for surfaces that enumerate analysis screens.
pub const Screen = route.Route;
/// Product-shell v2 route name.
pub const Route = route.Route;

pub const screenName = route.screenName;
pub const parseScreen = route.parse;

pub const Dialog = enum {
    none,
    palette,
    appearance,
    help,
    picker,
    confirm,
    onboarding,
};

pub const Confirm = enum {
    stop_capture,
    restart_capture,
    reset_settings,

    pub fn title(self: Confirm) []const u8 {
        return switch (self) {
            .stop_capture => "STOP CAPTURE",
            .restart_capture => "RESTART CAPTURE",
            .reset_settings => "RESET SETTINGS",
        };
    }

    pub fn body(self: Confirm) []const u8 {
        return switch (self) {
            .stop_capture => "Stop the read-only capture worker? The captured window remains in memory until replaced.",
            .restart_capture => "Stop the current capture and start a new one with the same options? A new session label is issued.",
            .reset_settings => "Reset appearance, recorder defaults, accessibility and recents to the built-in defaults?",
        };
    }

    pub fn confirmLabel(self: Confirm) []const u8 {
        return switch (self) {
            .stop_capture => "stop",
            .restart_capture => "restart",
            .reset_settings => "reset",
        };
    }
};

pub const AdvisorFilter = enum { all, warning, info, clear, skip };

pub const CapState = enum { ready, degraded, skip, refuse, busy };

pub const max_capabilities = 8;
pub const max_cap_name = 24;
pub const max_cap_reason = 96;

pub const Capability = struct {
    name: [max_cap_name]u8 = @splat(0),
    name_len: usize = 0,
    state: CapState = .skip,
    reason: [max_cap_reason]u8 = @splat(0),
    reason_len: usize = 0,

    pub fn nameSlice(self: *const Capability) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn reasonSlice(self: *const Capability) []const u8 {
        return self.reason[0..self.reason_len];
    }

    pub fn glyph(self: *const Capability) []const u8 {
        return switch (self.state) {
            .ready => "●",
            .degraded, .busy => "◐",
            .skip => "○",
            .refuse => "■",
        };
    }

    pub fn label(self: *const Capability) []const u8 {
        return switch (self.state) {
            .ready => "READY",
            .degraded => "DEGRADED",
            .skip => "SKIP",
            .refuse => "REFUSE",
            .busy => "BUSY",
        };
    }
};

pub const State = struct {
    screen: Screen = .overview,
    theme_index: usize = 0,
    dialog: Dialog = .none,
    confirm_pending: ?Confirm = null,
    scroll_y: f32 = 0,
    hover: ?u32 = null,
    focus: u32 = 0,
    focus_id: ?u32 = null,
    focus_visible: bool = false,
    focus_return: ?u32 = null,
    toast: ?[]const u8 = null,
    toast_error: bool = false,
    toast_until_ms: u64 = 0,
    now_ms: u64 = 0,

    timeline_start: f64 = 0,
    timeline_end: f64 = 0,
    timeline_playhead: f64 = 0,
    timeline_playing: bool = false,
    selected_slice: ?u32 = null,
    selected_event: ?usize = null,
    brush_from: ?f64 = null,
    brush_to: ?f64 = null,
    brush_dragging: bool = false,
    brush_start_x: f32 = 0,
    brush_start_ms: f64 = 0,
    hover_slice: ?u32 = null,
    hover_x: f32 = 0,
    hover_y: f32 = 0,
    advisor_filter: AdvisorFilter = .all,
    events_input: text_input.Input = .{},
    events_query: []const u8 = "",
    events_filter_focused: bool = false,
    events_type: []const u8 = "all",
    events_selected: ?usize = null,

    palette_input: text_input.Input = .{},
    palette_index: usize = 0,
    text_focus: ?text_input.Field = null,

    source: source.State = .{},
    recorder: recorder.State = .{},
    picker: picker.State = .{},
    settings: settings.Settings = .{},
    audit: audit.Ring = .{},
    onboarding: onboarding.State = .{},
    capabilities: [max_capabilities]Capability = @splat(Capability{}),
    capability_count: u8 = 0,
    /// Short deterministic status line for the footer/status strip.
    status: [96]u8 = @splat(0),
    status_len: usize = 0,

    pub fn viewStart(self: *const State, window_ms: f64) f64 {
        _ = window_ms;
        return if (self.timeline_end > self.timeline_start) self.timeline_start else 0;
    }

    pub fn viewEnd(self: *const State, window_ms: f64) f64 {
        return if (self.timeline_end > self.timeline_start) self.timeline_end else window_ms;
    }

    pub fn paletteQuery(self: *const State) []const u8 {
        return self.palette_input.slice();
    }

    pub fn eventsQuery(self: *const State) []const u8 {
        return self.events_query;
    }

    pub fn capabilitiesSlice(self: *const State) []const Capability {
        return self.capabilities[0..self.capability_count];
    }

    pub fn setCapability(self: *State, name: []const u8, cap_state: CapState, reason: []const u8) void {
        var index: usize = 0;
        while (index < self.capability_count) : (index += 1) {
            if (std.mem.eql(u8, self.capabilities[index].nameSlice(), name)) {
                self.writeCapability(index, cap_state, reason);
                return;
            }
        }
        if (self.capability_count >= max_capabilities) return;
        index = self.capability_count;
        self.capability_count += 1;
        self.capabilities[index].name_len = @min(name.len, self.capabilities[index].name.len);
        @memcpy(self.capabilities[index].name[0..self.capabilities[index].name_len], name[0..self.capabilities[index].name_len]);
        self.writeCapability(index, cap_state, reason);
    }

    fn writeCapability(self: *State, index: usize, cap_state: CapState, reason: []const u8) void {
        self.capabilities[index].state = cap_state;
        self.capabilities[index].reason_len = @min(reason.len, self.capabilities[index].reason.len);
        @memcpy(self.capabilities[index].reason[0..self.capabilities[index].reason_len], reason[0..self.capabilities[index].reason_len]);
    }

    pub fn capability(self: *const State, name: []const u8) ?*const Capability {
        for (self.capabilities[0..self.capability_count]) |*cap| {
            if (std.mem.eql(u8, cap.nameSlice(), name)) return cap;
        }
        return null;
    }

    pub fn setStatus(self: *State, text: []const u8) void {
        self.status_len = @min(text.len, self.status.len);
        @memcpy(self.status[0..self.status_len], text[0..self.status_len]);
    }

    pub fn statusSlice(self: *const State) []const u8 {
        return self.status[0..self.status_len];
    }

    pub fn closeDialogState(self: *State) void {
        if (self.dialog == .none) return;
        self.dialog = .none;
        self.focus_id = self.focus_return;
        self.focus_return = null;
        self.focus_visible = true;
        self.text_focus = null;
        self.picker.close();
        self.confirm_pending = null;
    }

    pub fn resetView(self: *State, window_ms: f64) void {
        self.timeline_start = 0;
        self.timeline_end = window_ms;
        self.timeline_playhead = 0;
        self.timeline_playing = false;
        self.scroll_y = 0;
        self.selected_slice = null;
        self.selected_event = null;
        self.events_selected = null;
        self.advisor_filter = .all;
        self.events_type = "all";
        self.events_filter_focused = false;
        self.events_input.clear();
        self.events_query = self.events_input.slice();
        self.palette_input.clear();
        self.palette_index = 0;
        self.text_focus = null;
    }
};

test "state capability strip is bounded and updates in place" {
    var state = State{};
    state.setCapability("perf", .ready, "");
    state.setCapability("tracefs", .refuse, "tracefs unreadable");
    state.setCapability("perf", .degraded, "perf partially available");
    try std.testing.expectEqual(@as(u8, 2), state.capability_count);
    const perf = state.capability("perf").?;
    try std.testing.expectEqual(CapState.degraded, perf.state);
    try std.testing.expectEqualStrings("◐", state.capability("perf").?.glyph());
    try std.testing.expectEqualStrings("■", state.capability("tracefs").?.glyph());
    try std.testing.expectEqualStrings("tracefs unreadable", state.capability("tracefs").?.reasonSlice());
}

test "dialog close restores focus and clears transient overlays" {
    var state = State{};
    state.dialog = .confirm;
    state.focus_return = 3201;
    state.confirm_pending = .stop_capture;
    state.closeDialogState();
    try std.testing.expectEqual(Dialog.none, state.dialog);
    try std.testing.expectEqual(@as(?u32, 3201), state.focus_id);
    try std.testing.expect(state.confirm_pending == null);
}

test "resetView clears analysis selection" {
    var state = State{};
    state.timeline_end = 100;
    state.timeline_playing = true;
    state.selected_slice = 3;
    state.events_input.reset("worker");
    state.events_query = state.events_input.slice();
    state.resetView(13970);
    try std.testing.expectEqual(@as(f64, 13970), state.timeline_end);
    try std.testing.expect(!state.timeline_playing);
    try std.testing.expect(state.selected_slice == null);
    try std.testing.expectEqualStrings("", state.eventsQuery());
}
