//! One offscreen UI frame: fonts, glyph atlas, draw list, CPU raster, PNG.

const std = @import("std");
const draw = @import("draw.zig");
const fonts = @import("fonts");
const input_mod = @import("input.zig");
const raster = @import("raster.zig");
const png = @import("png.zig");
const ttf = @import("ttf.zig");

/// Host-supplied TrueType bytes. The slices must outlive the frame that parses
/// them. `bundled` selects the embedded JetBrains Mono pair.
pub const FontSet = struct {
    regular: []const u8 = fonts.regular,
    bold: []const u8 = fonts.bold,

    pub const bundled: FontSet = .{};
};

pub const FrameOptions = struct {
    theme: draw.Theme = .{},
    fonts: FontSet = .bundled,
};

pub const Frame = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    theme: draw.Theme,
    atlas: draw.Atlas,
    list: draw.DrawList,
    regular: ttf.Font,
    bold: ttf.Font,
    input: input_mod.Input = .{},

    /// Initialize in place: the draw list points at this frame's atlas, so the
    /// frame address must be stable before this call.
    pub fn init(
        self: *Frame,
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        theme: draw.Theme,
    ) !void {
        return self.initWithOptions(allocator, width, height, .{ .theme = theme });
    }

    /// Initializes with an explicit theme and font source. Invalid TrueType
    /// bytes return `error.BadFont`.
    pub fn initWithOptions(
        self: *Frame,
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        options: FrameOptions,
    ) !void {
        var atlas = try draw.Atlas.init(allocator);
        errdefer atlas.deinit();
        const regular = ttf.Font.init(options.fonts.regular) catch return error.BadFont;
        const bold = ttf.Font.init(options.fonts.bold) catch return error.BadFont;
        self.* = .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .theme = options.theme,
            .atlas = atlas,
            .list = undefined,
            .regular = regular,
            .bold = bold,
        };
        self.list = draw.DrawList.init(allocator, &self.atlas);
    }

    pub fn deinit(self: *Frame) void {
        self.list.deinit();
        self.atlas.deinit();
    }

    pub fn clip(self: *const Frame) [4]f32 {
        return .{ 0, 0, @floatFromInt(self.width), @floatFromInt(self.height) };
    }

    pub fn render(self: *Frame) ![]u8 {
        return raster.render(self.allocator, self.width, self.height, &self.list, self.theme.bg);
    }

    pub fn savePng(self: *Frame, io: std.Io, path: []const u8) !void {
        const pixels = try self.render();
        defer self.allocator.free(pixels);
        const file = if (path.len != 0 and path[0] == '/')
            try std.Io.Dir.createFileAbsolute(io, path, .{})
        else
            try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try png.write(&writer.interface, self.width, self.height, pixels);
        try writer.interface.flush();
    }
};

test "frame renders a non-empty snapshot" {
    var frame: Frame = undefined;
    try frame.init(std.testing.allocator, 64, 48, .{});
    defer frame.deinit();
    try frame.list.rect(0, 0, 64, 48, frame.theme.panel, frame.clip());
    _ = try frame.list.text(1, &frame.bold, 12, 4, 4, "xsui", frame.theme.live, frame.clip());
    const pixels = try frame.render();
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(usize, 64 * 48 * 4), pixels.len);
    var non_bg: usize = 0;
    var i: usize = 0;
    while (i < 64 * 48) : (i += 1) {
        if (pixels[i * 4] != frame.theme.panel.r or pixels[i * 4 + 1] != frame.theme.panel.g) {
            non_bg += 1;
        }
    }
    try std.testing.expect(non_bg > 0);
}

test "frame options accept the bundled font set and reject bad bytes" {
    var frame: Frame = undefined;
    try frame.initWithOptions(std.testing.allocator, 32, 24, .{
        .theme = draw.Theme{ .bg = .{ .r = 1, .g = 2, .b = 3 } },
        .fonts = FontSet.bundled,
    });
    defer frame.deinit();
    try std.testing.expectEqual(@as(u8, 1), frame.theme.bg.r);
    try std.testing.expectEqual(@as(u16, 737), frame.regular.glyphIndex('0'));

    var bad: Frame = undefined;
    try std.testing.expectError(error.BadFont, bad.initWithOptions(std.testing.allocator, 8, 8, .{
        .fonts = .{ .regular = "not-a-font", .bold = "not-a-font" },
    }));
}
