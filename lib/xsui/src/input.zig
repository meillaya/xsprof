//! Platform-neutral pointer, wheel, and key state for one frame.

const std = @import("std");

pub const Key = enum(u8) {
    none = 0,
    zero = 1,
    escape = 2,
    left = 3,
    right = 4,
    filter = 5,
    clear = 6,
    kind = 7,
    loss = 8,
    pid = 9,
    lab = 10,
    palette = 11,
    backspace = 12,
    enter = 13,
};

pub const Mods = packed struct(u4) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const max_text_bytes = 8;
pub const max_key_events = 16;

pub const KeyEvent = struct {
    key: Key = .none,
    mods: Mods = .{},
    text: [max_text_bytes]u8 = @splat(0),
    text_len: u8 = 0,

    pub fn textSlice(self: *const KeyEvent) []const u8 {
        return self.text[0..self.text_len];
    }
};

/// Stable JS ABI: the browser shim sends these integer codes.
pub fn fromWebCode(code: u32) Key {
    return switch (code) {
        0 => .zero,
        1 => .escape,
        2 => .left,
        3 => .right,
        4 => .filter,
        5 => .clear,
        6 => .kind,
        7 => .loss,
        8 => .pid,
        9 => .lab,
        10 => .palette,
        11 => .backspace,
        12 => .enter,
        else => .none,
    };
}

pub const Input = struct {
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    pointer_down: bool = false,
    clicked: bool = false,
    scroll_y: f32 = 0,
    key: Key = .none,
    key_events: [max_key_events]KeyEvent = @splat(.{}),
    key_event_count: u8 = 0,
    key_event_overflow: bool = false,

    pub fn clearTransient(self: *Input) void {
        self.clicked = false;
        self.scroll_y = 0;
        self.key = .none;
        self.key_event_count = 0;
        self.key_event_overflow = false;
    }

    /// Queues a key or text event. Returns false when the bounded queue is
    /// full; the frame still keeps the most recent `Input.key` shim.
    pub fn pushKey(self: *Input, event: KeyEvent) bool {
        if (self.key_event_count >= max_key_events) {
            self.key_event_overflow = true;
            return false;
        }
        self.key_events[self.key_event_count] = event;
        self.key_event_count += 1;
        self.key = event.key;
        return true;
    }

    pub fn pushText(self: *Input, text: []const u8) bool {
        var event = KeyEvent{};
        const len = @min(text.len, max_text_bytes);
        event.text_len = @intCast(len);
        @memcpy(event.text[0..len], text[0..len]);
        return self.pushKey(event);
    }

    pub fn keyEvents(self: *const Input) []const KeyEvent {
        return self.key_events[0..self.key_event_count];
    }

    pub fn inside(self: *const Input, x: f32, y: f32, w: f32, h: f32) bool {
        return self.pointer_x >= x and self.pointer_y >= y and
            self.pointer_x < x + w and self.pointer_y < y + h;
    }
};

test "web key codes stay stable" {
    try std.testing.expectEqual(Key.filter, fromWebCode(4));
    try std.testing.expectEqual(Key.kind, fromWebCode(6));
    try std.testing.expectEqual(Key.loss, fromWebCode(7));
    try std.testing.expectEqual(Key.pid, fromWebCode(8));
    try std.testing.expectEqual(Key.lab, fromWebCode(9));
    try std.testing.expectEqual(Key.palette, fromWebCode(10));
    try std.testing.expectEqual(Key.none, fromWebCode(99));
}

test "input queues bounded key and text events" {
    var input = Input{};
    try std.testing.expect(input.pushText("a"));
    try std.testing.expectEqual(@as(u8, 1), input.key_event_count);
    try std.testing.expectEqualStrings("a", input.key_events[0].textSlice());
    try std.testing.expect(input.pushKey(.{ .key = .escape, .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(Key.escape, input.key);
    try std.testing.expect(input.key_events[1].mods.ctrl);
    var index: usize = 2;
    while (index < max_key_events) : (index += 1) {
        try std.testing.expect(input.pushText("x"));
    }
    try std.testing.expect(!input.pushText("x"));
    try std.testing.expect(input.key_event_overflow);
    input.clearTransient();
    try std.testing.expectEqual(@as(u8, 0), input.key_event_count);
    try std.testing.expect(!input.key_event_overflow);
}
