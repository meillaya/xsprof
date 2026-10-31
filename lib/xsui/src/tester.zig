//! Headless UI tester: deterministic frame build, render, hash, snapshot, and
//! scripted input. No window and no platform code is involved.

const std = @import("std");
const draw = @import("draw.zig");
const frame_mod = @import("frame.zig");
const input_mod = @import("input.zig");
const layout = @import("layout.zig");

pub const ViewFn = *const fn (user: ?*anyopaque, ui: *layout.Ui) anyerror!void;

pub const Tester = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    theme: draw.Theme,
    clock_ms: u64 = 0,
    /// Scripted input copied into each rendered frame. Pointer position
    /// persists; transient click/wheel/key events are consumed per render.
    input: input_mod.Input = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        theme: draw.Theme,
    ) Tester {
        return .{ .allocator = allocator, .width = width, .height = height, .theme = theme };
    }

    pub fn resize(self: *Tester, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
    }

    pub fn setTheme(self: *Tester, theme: draw.Theme) void {
        self.theme = theme;
    }

    pub fn advance(self: *Tester, ms: u64) void {
        self.clock_ms +%= ms;
    }

    pub fn pointer(self: *Tester, x: f32, y: f32) void {
        self.input.pointer_x = x;
        self.input.pointer_y = y;
    }

    pub fn click(self: *Tester, x: f32, y: f32) void {
        self.pointer(x, y);
        self.input.clicked = true;
    }

    pub fn wheel(self: *Tester, delta: f32) void {
        self.input.scroll_y += delta;
    }

    pub fn key(self: *Tester, event: input_mod.KeyEvent) bool {
        return self.input.pushKey(event);
    }

    pub fn text(self: *Tester, bytes: []const u8) bool {
        return self.input.pushText(bytes);
    }

    pub fn clearInput(self: *Tester) void {
        self.input.clearTransient();
    }

    /// Builds and paints a frame. Pixels are allocated with the tester's
    /// allocator; the caller frees them with `tester.allocator`.
    pub fn renderPixels(self: *Tester, user: ?*anyopaque, view: ViewFn) ![]u8 {
        var frame: frame_mod.Frame = undefined;
        try frame.init(self.allocator, self.width, self.height, self.theme);
        defer frame.deinit();
        try self.run(user, view, &frame);
        return frame.render();
    }

    pub fn renderHash(self: *Tester, user: ?*anyopaque, view: ViewFn) !u64 {
        const pixels = try self.renderPixels(user, view);
        defer self.allocator.free(pixels);
        var hash: u64 = 1469598103934665603;
        for (pixels) |byte| {
            hash ^= byte;
            hash *%= 1099511628211;
        }
        return hash;
    }

    pub fn snapshot(
        self: *Tester,
        io: std.Io,
        path: []const u8,
        user: ?*anyopaque,
        view: ViewFn,
    ) !void {
        var frame: frame_mod.Frame = undefined;
        try frame.init(self.allocator, self.width, self.height, self.theme);
        defer frame.deinit();
        try self.run(user, view, &frame);
        try frame.savePng(io, path);
    }

    fn run(self: *Tester, user: ?*anyopaque, view: ViewFn, frame: *frame_mod.Frame) !void {
        frame.input = self.input;
        var ui = layout.Ui.init(frame);
        defer ui.deinit();
        try view(user, &ui);
        try ui.finish();
        // Keep pointer state and any mutations the view made, then consume the
        // transient events so the next render starts from a quiet frame.
        self.input = frame.input;
        self.input.clearTransient();
    }
};

const Probe = struct {
    clicked: bool = false,
    key: input_mod.Key = .none,
    pointer: [2]f32 = .{ 0, 0 },
    scroll: f32 = 0,
    text_len: usize = 0,
    key_events: usize = 0,
};

fn probeView(user: ?*anyopaque, ui: *layout.Ui) !void {
    if (user) |ptr| {
        const probe: *Probe = @ptrCast(@alignCast(ptr));
        probe.clicked = ui.frame.input.clicked;
        probe.key = ui.frame.input.key;
        probe.pointer = .{ ui.frame.input.pointer_x, ui.frame.input.pointer_y };
        probe.scroll = ui.frame.input.scroll_y;
        probe.key_events = ui.frame.input.keyEvents().len;
        if (probe.key_events != 0) probe.text_len = ui.frame.input.keyEvents()[0].textSlice().len;
    }
    var root = try ui.column(.{ .padding = layout.Edges.all(8), .bg = ui.theme.panel });
    try ui.text(.{ .text = "xsui", .size = 14, .color = ui.theme.live, .weight = .bold });
    root.end();
}

test "tester renders and advances the clock" {
    var tester = Tester.init(std.testing.allocator, 160, 90, .{});
    tester.advance(16);
    const hash = try tester.renderHash(null, probeView);
    try std.testing.expect(hash != 0);
    try std.testing.expectEqual(@as(u64, 16), tester.clock_ms);
}

test "tester scripts pointer, click, wheel, key, and text" {
    var tester = Tester.init(std.testing.allocator, 160, 90, .{});
    tester.click(12, 34);
    tester.wheel(3);
    try std.testing.expect(tester.text("a"));
    try std.testing.expect(tester.key(.{ .key = .escape }));
    var probe = Probe{};
    const hash = try tester.renderHash(&probe, probeView);
    try std.testing.expect(hash != 0);
    try std.testing.expect(probe.clicked);
    try std.testing.expectEqual(input_mod.Key.escape, probe.key);
    try std.testing.expectEqual(@as(f32, 12), probe.pointer[0]);
    try std.testing.expectEqual(@as(f32, 34), probe.pointer[1]);
    try std.testing.expectEqual(@as(f32, 3), probe.scroll);
    try std.testing.expectEqual(@as(usize, 2), probe.key_events);
    try std.testing.expectEqual(@as(usize, 1), probe.text_len);
    // Transient events are consumed; the pointer survives into the next frame.
    try std.testing.expect(!tester.input.clicked);
    try std.testing.expectEqual(input_mod.Key.none, tester.input.key);
    probe.clicked = false;
    _ = try tester.renderHash(&probe, probeView);
    try std.testing.expect(!probe.clicked);
    try std.testing.expectEqual(@as(f32, 12), probe.pointer[0]);
}

test "tester exposes rendered pixels" {
    var tester = Tester.init(std.testing.allocator, 32, 24, .{});
    const pixels = try tester.renderPixels(null, probeView);
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(usize, 32 * 24 * 4), pixels.len);
}
