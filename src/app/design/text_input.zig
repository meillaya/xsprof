//! Reusable single-line text input model. Fixed buffers only: inputs are
//! bounded by construction and stay copyable without an allocator.

const std = @import("std");

pub const max_text = 256;

/// Which text control owns keyboard focus.
pub const Field = enum { palette, events_filter, picker_filter, recorder_dir };

pub const Input = struct {
    buf: [max_text]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub fn slice(self: *const Input) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn reset(self: *Input, text: []const u8) void {
        self.len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..self.len], text[0..self.len]);
        self.cursor = self.len;
    }

    pub fn clear(self: *Input) void {
        self.len = 0;
        self.cursor = 0;
    }

    pub fn insert(self: *Input, codepoint: u21) bool {
        if (codepoint < 32 or codepoint > 0x10ffff) return false;
        var encoded: [4]u8 = undefined;
        const n = utf8Encode(codepoint, &encoded) orelse return false;
        if (self.len + n > self.buf.len) return false;
        if (self.cursor < self.len) {
            std.mem.copyBackwards(u8, self.buf[self.cursor + n .. self.len + n], self.buf[self.cursor..self.len]);
        }
        @memcpy(self.buf[self.cursor .. self.cursor + n], encoded[0..n]);
        self.cursor += n;
        self.len += n;
        return true;
    }

    pub fn backspace(self: *Input) bool {
        if (self.cursor == 0) return false;
        const start = prevBoundary(self.buf[0..self.cursor]);
        std.mem.copyForwards(u8, self.buf[start .. self.len - (self.cursor - start)], self.buf[self.cursor..self.len]);
        self.len -= self.cursor - start;
        self.cursor = start;
        return true;
    }

    pub fn delete(self: *Input) bool {
        if (self.cursor >= self.len) return false;
        const end_index = nextBoundary(self.buf[self.cursor..self.len]) + self.cursor;
        std.mem.copyForwards(u8, self.buf[self.cursor .. self.len - (end_index - self.cursor)], self.buf[end_index..self.len]);
        self.len -= end_index - self.cursor;
        return true;
    }

    pub fn left(self: *Input) void {
        if (self.cursor > 0) self.cursor = prevBoundary(self.buf[0..self.cursor]);
    }

    pub fn right(self: *Input) void {
        if (self.cursor < self.len) self.cursor = nextBoundary(self.buf[self.cursor..self.len]) + self.cursor;
    }

    pub fn home(self: *Input) void {
        self.cursor = 0;
    }

    pub fn end(self: *Input) void {
        self.cursor = self.len;
    }

    /// Ctrl/Cmd+U: clear the whole line.
    pub fn killLine(self: *Input) void {
        self.clear();
    }

    /// Ctrl/Cmd+W: delete the previous word.
    pub fn killWord(self: *Input) void {
        while (self.cursor > 0 and self.buf[self.cursor - 1] == ' ') {
            _ = self.backspace();
        }
        while (self.cursor > 0 and self.buf[self.cursor - 1] != ' ') {
            _ = self.backspace();
        }
    }
};

fn utf8Encode(codepoint: u21, out: *[4]u8) ?usize {
    if (codepoint <= 0x7f) {
        out[0] = @intCast(codepoint);
        return 1;
    }
    if (codepoint <= 0x7ff) {
        out[0] = @intCast(0xc0 | (codepoint >> 6));
        out[1] = @intCast(0x80 | (codepoint & 0x3f));
        return 2;
    }
    if (codepoint <= 0xffff) {
        out[0] = @intCast(0xe0 | (codepoint >> 12));
        out[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        out[2] = @intCast(0x80 | (codepoint & 0x3f));
        return 3;
    }
    out[0] = @intCast(0xf0 | (codepoint >> 18));
    out[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3f));
    out[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
    out[3] = @intCast(0x80 | (codepoint & 0x3f));
    return 4;
}

fn prevBoundary(text: []const u8) usize {
    if (text.len == 0) return 0;
    var i = text.len - 1;
    while (i > 0 and (text[i] & 0xc0) == 0x80) i -= 1;
    return i;
}

fn nextBoundary(text: []const u8) usize {
    if (text.len == 0) return 0;
    var i: usize = 1;
    while (i < text.len and (text[i] & 0xc0) == 0x80) i += 1;
    return i;
}

test "text input edits in place" {
    var input = Input{};
    input.reset("abc");
    try std.testing.expectEqualStrings("abc", input.slice());
    input.left();
    _ = input.backspace();
    try std.testing.expectEqualStrings("ac", input.slice());
    try std.testing.expectEqual(@as(usize, 1), input.cursor);
    _ = input.insert('b');
    try std.testing.expectEqualStrings("abc", input.slice());
    input.end();
    _ = input.backspace();
    try std.testing.expectEqualStrings("ab", input.slice());
    input.home();
    _ = input.delete();
    try std.testing.expectEqualStrings("b", input.slice());
    input.reset("one two");
    input.home();
    input.end();
    input.killWord();
    try std.testing.expectEqualStrings("one ", input.slice());
    input.killLine();
    try std.testing.expectEqual(@as(usize, 0), input.len);
}

test "text input rejects control and overlong input" {
    var input = Input{};
    try std.testing.expect(!input.insert(0x1b));
    try std.testing.expect(!input.insert(0x0a));
    var i: usize = 0;
    while (i < max_text) : (i += 1) _ = input.insert('x');
    try std.testing.expectEqual(@as(usize, max_text), input.len);
    try std.testing.expect(!input.insert('y'));
}
