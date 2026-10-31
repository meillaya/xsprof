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

    pub fn clearTransient(self: *Input) void {
        self.clicked = false;
        self.scroll_y = 0;
        self.key = .none;
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
    try std.testing.expectEqual(Key.none, fromWebCode(99));
}
