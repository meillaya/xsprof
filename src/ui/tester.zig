//! Headless UI tester: deterministic frame build/render/hash/snapshot.
//! Input scripting and focus land with the interactive app in P3.

const std = @import("std");
const draw = @import("draw.zig");
const frame_mod = @import("frame.zig");
const layout = @import("layout.zig");

pub const ViewFn = *const fn (user: ?*anyopaque, ui: *layout.Ui) anyerror!void;

pub const Tester = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    theme: draw.Theme,
    clock_ms: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        theme: draw.Theme,
    ) Tester {
        return .{ .allocator = allocator, .width = width, .height = height, .theme = theme };
    }

    pub fn advance(self: *Tester, ms: u64) void {
        self.clock_ms +%= ms;
    }

    pub fn renderHash(self: *Tester, user: ?*anyopaque, view: ViewFn) !u64 {
        var frame: frame_mod.Frame = undefined;
        try frame.init(self.allocator, self.width, self.height, self.theme);
        defer frame.deinit();
        var ui = layout.Ui.init(&frame);
        defer ui.deinit();
        try view(user, &ui);
        try ui.finish();
        const pixels = try frame.render();
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
        var ui = layout.Ui.init(&frame);
        defer ui.deinit();
        try view(user, &ui);
        try ui.finish();
        try frame.savePng(io, path);
    }
};

test "tester renders and advances the clock" {
    const view = struct {
        fn drawView(_: ?*anyopaque, ui: *layout.Ui) !void {
            var root = try ui.column(.{ .padding = layout.Edges.all(8), .bg = ui.theme.panel });
            try ui.text(.{ .text = "xsprof", .size = 14, .color = ui.theme.live, .weight = .bold });
            root.end();
        }
    }.drawView;
    var tester = Tester.init(std.testing.allocator, 160, 90, .{});
    tester.advance(16);
    const hash = try tester.renderHash(null, view);
    try std.testing.expect(hash != 0);
    try std.testing.expectEqual(@as(u64, 16), tester.clock_ms);
}
