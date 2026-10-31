//! Platform-neutral pointer, wheel, and key state for one frame.

pub const Key = enum(u8) {
    none = 0,
    zero = 1,
    escape = 2,
    left = 3,
    right = 4,
    filter = 5,
    clear = 6,
};

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
