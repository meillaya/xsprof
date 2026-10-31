//! Flat UI draw list + glyph atlas. The same instances feed the CPU, Metal,
//! and WebGL2 backends; this file has no OS or profiler dependency.

const std = @import("std");
const ttf = @import("ttf.zig");
const fonts = @import("fonts");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn toU32(self: Color) u32 {
        return (@as(u32, self.r) << 24) | (@as(u32, self.g) << 16) |
            (@as(u32, self.b) << 8) | self.a;
    }

    pub fn fromU32(value: u32) Color {
        return .{
            .r = @intCast(value >> 24),
            .g = @intCast((value >> 16) & 0xff),
            .b = @intCast((value >> 8) & 0xff),
            .a = @intCast(value & 0xff),
        };
    }
};

pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

/// One design-system palette. The first block is the original xsui theme
/// surface; the rest are the prototype's richer token roles. `hairline` is
/// kept as an alias for `line` so older widgets continue to work.
pub const Theme = struct {
    bg: Color = .{ .r = 0x05, .g = 0x05, .b = 0x05 },
    panel: Color = .{ .r = 0x10, .g = 0x10, .b = 0x0e },
    raised: Color = .{ .r = 0x17, .g = 0x15, .b = 0x12 },
    text: Color = .{ .r = 0xf5, .g = 0xef, .b = 0xe4 },
    muted: Color = .{ .r = 0xa7, .g = 0x9b, .b = 0x8c },
    hairline: Color = .{ .r = 0x26, .g = 0x23, .b = 0x20 },
    live: Color = .{ .r = 0x58, .g = 0xd7, .b = 0xe8 },
    pass: Color = .{ .r = 0x72, .g = 0xd4, .b = 0x87 },
    skip: Color = .{ .r = 0xe3, .g = 0xb4, .b = 0x5c },
    refuse: Color = .{ .r = 0xff, .g = 0x6b, .b = 0x9a },
    pending: Color = .{ .r = 0xde, .g = 0xd6, .b = 0xc9 },
    vm: Color = .{ .r = 0xb4, .g = 0x8c, .b = 0xff },

    raised2: Color = .{ .r = 0x1e, .g = 0x1b, .b = 0x17 },
    field: Color = .{ .r = 0x0b, .g = 0x0b, .b = 0x0a },
    dim: Color = .{ .r = 0x9a, .g = 0x8d, .b = 0x7b },
    faint: Color = .{ .r = 0x8a, .g = 0x7e, .b = 0x6f },
    line: Color = .{ .r = 0x26, .g = 0x23, .b = 0x20 },
    line_strong: Color = .{ .r = 0x3a, .g = 0x33, .b = 0x2b },
    tint_live: Color = .{ .r = 0x58, .g = 0xd7, .b = 0xe8, .a = 26 },
    tint_refuse: Color = .{ .r = 0xff, .g = 0x6b, .b = 0x9a, .a = 23 },
    tint_skip: Color = .{ .r = 0xe3, .g = 0xb4, .b = 0x5c, .a = 23 },
    tint_pass: Color = .{ .r = 0x72, .g = 0xd4, .b = 0x87, .a = 20 },
    lanes: [9]Color = .{
        .{ .r = 0x58, .g = 0xd7, .b = 0xe8 }, .{ .r = 0x72, .g = 0xd4, .b = 0x87 },
        .{ .r = 0xe3, .g = 0xb4, .b = 0x5c }, .{ .r = 0xff, .g = 0x6b, .b = 0x9a },
        .{ .r = 0xb4, .g = 0x8c, .b = 0xff }, .{ .r = 0x9d, .g = 0xb4, .b = 0xc0 },
        .{ .r = 0xc8, .g = 0xb4, .b = 0x8a }, .{ .r = 0x4f, .g = 0xb3, .b = 0xa3 },
        .{ .r = 0xd7, .g = 0x9c, .b = 0xc4 },
    },
    lane_idle: Color = .{ .r = 0x1c, .g = 0x1a, .b = 0x17 },
    lane_grid: Color = .{ .r = 0x20, .g = 0x1d, .b = 0x19 },
    focus: Color = .{ .r = 0x58, .g = 0xd7, .b = 0xe8 },
    focus_offset: f32 = 2,

    chip_source_border: Color = .{ .r = 0x3a, .g = 0x6b, .b = 0x70 },
    chip_journal_border: Color = .{ .r = 0x46, .g = 0x6d, .b = 0x4b },
    chip_loss_border: Color = .{ .r = 0x7d, .g = 0x40, .b = 0x51 },
    control_pressed_border: Color = .{ .r = 0x3c, .g = 0x74, .b = 0x7a },
    button_hover_border: Color = .{ .r = 0x72, .g = 0x6b, .b = 0x62 },
    segment_loss_border: Color = .{ .r = 0x88, .g = 0x43, .b = 0x57 },
    refuse_chip_border: Color = .{ .r = 0x78, .g = 0x3e, .b = 0x4e },
    theme_option_active_border: Color = .{ .r = 0x42, .g = 0x86, .b = 0x8e },
    ledger_loss_hover: Color = .{ .r = 0x31, .g = 0x1d, .b = 0x22 },

    pub fn lane(self: Theme, index: usize) Color {
        return self.lanes[index % self.lanes.len];
    }
};

pub const Mode = enum(u32) { rect = 0, glyph = 1 };

pub const Instance = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    color: u32,
    border_color: u32 = 0,
    radius: f32 = 0,
    border_width: f32 = 0,
    mode: u32 = 0,
    pad: u32 = 0,
};

fn atlasKey(font: u8, size_q: u32, gid: u16) u64 {
    return (@as(u64, font) << 48) | (@as(u64, size_q) << 16) | gid;
}

pub const GlyphEntry = struct {
    uv: [4]f32,
    width: u32,
    height: u32,
    left: i32,
    top: i32,
    advance: u32,
    advance_f: f32 = 0,
};

/// Fixed atlas dimensions shared by the CPU, Metal, GL, and WebGL2 backends.
pub const atlas_width: usize = 4096;
pub const atlas_height: usize = 4096;

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    width: usize = atlas_width,
    height: usize = atlas_height,
    pixels: []u8,
    shelf_x: usize = 0,
    shelf_y: usize = 0,
    shelf_h: usize = 0,
    version: u32 = 0,
    entries: std.AutoHashMap(u64, GlyphEntry),

    pub fn init(allocator: std.mem.Allocator) !Atlas {
        const pixels = try allocator.alloc(u8, atlas_width * atlas_height);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .pixels = pixels,
            .entries = std.AutoHashMap(u64, GlyphEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Atlas) void {
        self.entries.deinit();
        self.allocator.free(self.pixels);
    }

    /// Insert a pre-rasterized alpha mask (used by the browser-matched text
    /// asset). The atlas is the single texture consumed by every backend.
    pub fn addMask(self: *Atlas, pixels: []const u8, w: usize, h: usize, left: i32, top: i32) !GlyphEntry {
        if (w == 0 or h == 0 or w > self.width or h > self.height) return error.AtlasFull;
        if (pixels.len < w * h) return error.BadMask;
        if (self.shelf_x + w + 1 > self.width and self.shelf_x != 0) {
            self.shelf_x = 0;
            self.shelf_y += self.shelf_h + 1;
            self.shelf_h = 0;
        }
        if (self.shelf_x + w + 1 > self.width) return error.AtlasFull;
        if (self.shelf_y + h + 1 > self.height) return error.AtlasFull;
        const x = self.shelf_x;
        const y = self.shelf_y;
        var row: usize = 0;
        while (row < h) : (row += 1) {
            const src = pixels[row * w .. row * w + w];
            const dst = (y + row) * self.width + x;
            @memcpy(self.pixels[dst .. dst + w], src);
        }
        self.shelf_x += w + 1;
        self.shelf_h = @max(self.shelf_h, h);
        const entry = GlyphEntry{
            .uv = .{
                @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(self.width)),
                @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(self.height)),
                @as(f32, @floatFromInt(x + w)) / @as(f32, @floatFromInt(self.width)),
                @as(f32, @floatFromInt(y + h)) / @as(f32, @floatFromInt(self.height)),
            },
            .width = @intCast(w),
            .height = @intCast(h),
            .left = left,
            .top = top,
            .advance = 0,
            .advance_f = 0,
        };
        self.version +%= 1;
        return entry;
    }

    pub fn glyph(
        self: *Atlas,
        font_index: u8,
        font: *const ttf.Font,
        gid: u16,
        size_px: u16,
    ) !GlyphEntry {
        return self.glyphF(font_index, font, gid, @floatFromInt(size_px));
    }

    /// Fractional glyph sizes are quantized to 1/16 px for atlas identity. The
    /// bitmap itself is rasterized at the exact requested size.
    pub fn glyphF(
        self: *Atlas,
        font_index: u8,
        font: *const ttf.Font,
        gid: u16,
        size_px: f32,
    ) !GlyphEntry {
        const size_q: u32 = @intFromFloat(@round(@max(1, size_px) * 16));
        const key = atlasKey(font_index, size_q, gid);
        if (self.entries.get(key)) |entry| return entry;
        const bitmap = try font.rasterize(self.allocator, gid, size_px);
        defer if (bitmap.pixels.len != 0) self.allocator.free(bitmap.pixels);
        const w: usize = bitmap.width;
        const h: usize = bitmap.height;
        if (w == 0 or h == 0) {
            const entry = GlyphEntry{
                .uv = .{ 0, 0, 0, 0 },
                .width = 0,
                .height = 0,
                .left = 0,
                .top = 0,
                .advance = bitmap.advance,
                .advance_f = @as(f32, @floatFromInt(font.advance(gid))) * size_px /
                    @as(f32, @floatFromInt(font.units_per_em)),
            };
            try self.entries.put(key, entry);
            self.version +%= 1;
            return entry;
        }
        if (self.shelf_x + w + 1 > self.width) {
            self.shelf_y += self.shelf_h + 1;
            self.shelf_x = 0;
            self.shelf_h = 0;
        }
        // Shelves must wrap before writing past the atlas width. Without this
        // check later glyphs get UVs > 1 and sample clamped edge texels.
        if (self.shelf_x + w + 1 > self.width and self.shelf_x != 0) {
            self.shelf_x = 0;
            self.shelf_y += self.shelf_h + 1;
            self.shelf_h = 0;
        }
        if (self.shelf_x + w + 1 > self.width) return error.AtlasFull;
        if (self.shelf_y + h + 1 > self.height) return error.AtlasFull;
        const x = self.shelf_x;
        const y = self.shelf_y;
        var row: usize = 0;
        while (row < h) : (row += 1) {
            const src = bitmap.pixels[row * w .. row * w + w];
            const dst = (y + row) * self.width + x;
            @memcpy(self.pixels[dst .. dst + w], src);
        }
        self.shelf_x += w + 1;
        self.shelf_h = @max(self.shelf_h, h);
        const entry = GlyphEntry{
            .uv = .{
                @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(self.width)),
                @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(self.height)),
                @as(f32, @floatFromInt(x + w)) / @as(f32, @floatFromInt(self.width)),
                @as(f32, @floatFromInt(y + h)) / @as(f32, @floatFromInt(self.height)),
            },
            .width = bitmap.width,
            .height = bitmap.height,
            .left = bitmap.left,
            .top = bitmap.top,
            .advance = bitmap.advance,
            .advance_f = @as(f32, @floatFromInt(font.advance(gid))) * size_px /
                @as(f32, @floatFromInt(font.units_per_em)),
        };
        try self.entries.put(key, entry);
        self.version +%= 1;
        return entry;
    }
};

pub const DrawList = struct {
    allocator: std.mem.Allocator,
    atlas: *Atlas,
    items: std.ArrayList(Instance) = .empty,

    pub fn init(allocator: std.mem.Allocator, atlas: *Atlas) DrawList {
        return .{ .allocator = allocator, .atlas = atlas };
    }

    pub fn deinit(self: *DrawList) void {
        self.items.deinit(self.allocator);
    }

    pub fn clear(self: *DrawList) void {
        self.items.clearRetainingCapacity();
    }

    pub fn rect(
        self: *DrawList,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        clip: [4]f32,
    ) !void {
        try self.items.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .clip = clip,
            .color = color.toU32(),
            .mode = @backingInt(Mode.rect),
        });
    }

    pub fn roundedRect(
        self: *DrawList,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        radius: f32,
        color: Color,
        border: ?Color,
        border_width: f32,
        clip: [4]f32,
    ) !void {
        try self.items.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .clip = clip,
            .color = color.toU32(),
            .border_color = if (border) |b| b.toU32() else 0,
            .radius = radius,
            .border_width = border_width,
            .mode = @backingInt(Mode.rect),
        });
    }

    pub fn measure(
        font: *const ttf.Font,
        size: f32,
        text_value: []const u8,
    ) u32 {
        const size_px: u16 = @intFromFloat(@round(size));
        _ = size_px;
        var width: f32 = 0;
        for (text_value) |byte| {
            if (byte < 32) continue;
            const gid = font.glyphIndex(byte);
            width += @round(@as(f32, @floatFromInt(font.advance(gid))) * size /
                @as(f32, @floatFromInt(font.units_per_em)));
        }
        return @intFromFloat(@ceil(width));
    }

    pub fn text(
        self: *DrawList,
        font_index: u8,
        font: *const ttf.Font,
        size: f32,
        x: f32,
        y: f32,
        text_value: []const u8,
        color: Color,
        clip: [4]f32,
    ) !f32 {
        const baseline = y + @as(f32, @floatFromInt(font.ascender)) * size /
            @as(f32, @floatFromInt(font.units_per_em));
        var pen = x;
        for (text_value) |byte| {
            if (byte < 32) continue;
            const gid = font.glyphIndex(byte);
            const entry = try self.atlas.glyphF(font_index, font, gid, size);
            if (entry.width != 0 and entry.height != 0) {
                try self.items.append(self.allocator, .{
                    .rect = .{
                        pen + @as(f32, @floatFromInt(entry.left)),
                        baseline - @as(f32, @floatFromInt(entry.top)),
                        @floatFromInt(entry.width),
                        @floatFromInt(entry.height),
                    },
                    .clip = clip,
                    .uv = entry.uv,
                    .color = color.toU32(),
                    .mode = @backingInt(Mode.glyph),
                });
            }
            pen += entry.advance_f;
        }
        return pen - x;
    }
};

pub fn regularFont() !ttf.Font {
    return ttf.Font.init(fonts.regular);
}

pub fn boldFont() !ttf.Font {
    return ttf.Font.init(fonts.bold);
}

test "glyph atlas rasterizes and packs ASCII" {
    var font = try regularFont();
    var atlas = try Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    const entry = try atlas.glyph(0, &font, font.glyphIndex('A'), 14);
    try std.testing.expect(entry.width > 0);
    try std.testing.expect(entry.advance > 0);
    var ink: u32 = 0;
    for (atlas.pixels) |p| ink += p;
    try std.testing.expect(ink > 0);
}
