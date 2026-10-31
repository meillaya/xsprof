//! Browser-matched text masks generated from design/index.html by
//! tools/gen_chromium_text_atlas.cjs. This is an optional deterministic layer:
//! unknown glyphs/styles/phases fall back to the staged TTF rasterizer.

const std = @import("std");
const draw = @import("draw.zig");
const fonts = @import("fonts");

const magic = "XSTA";
const header_bytes = 28;
const record_bytes = 24;

pub const Placed = struct {
    entry: draw.GlyphEntry,
    x: f32,
    y: f32,
};

pub const Baked = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(u64, draw.GlyphEntry),

    pub fn init(allocator: std.mem.Allocator, atlas: *draw.Atlas) !Baked {
        var self = Baked{
            .allocator = allocator,
            .entries = std.AutoHashMap(u64, draw.GlyphEntry).init(allocator),
        };
        errdefer self.deinit();
        const data = fonts.chromium_text_atlas;
        if (data.len < header_bytes or !std.mem.eql(u8, data[0..4], magic)) return error.InvalidGlyphAtlas;
        const version = readU16(data, 4);
        if (version != 1) return error.InvalidGlyphAtlas;
        const count = readU32(data, 10);
        const records_at = readU32(data, 14);
        const pixels_at = readU32(data, 18);
        if (count > 200_000) return error.InvalidGlyphAtlas;
        if (records_at < header_bytes or pixels_at < records_at) return error.InvalidGlyphAtlas;
        if (@as(u64, records_at) + @as(u64, count) * record_bytes > data.len) return error.InvalidGlyphAtlas;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const at: usize = @as(usize, records_at) + @as(usize, i) * record_bytes;
            const cp = readU32(data, at);
            const size_q = readU16(data, at + 4);
            const bold = readU16(data, at + 6) != 0;
            const phase = data[at + 8];
            const left: i32 = @as(i16, @bitCast(readU16(data, at + 10)));
            const top: i32 = @as(i16, @bitCast(readU16(data, at + 12)));
            const w = readU16(data, at + 14);
            const h = readU16(data, at + 16);
            const offset = readU32(data, at + 18);
            if (w == 0 or h == 0 or w > 512 or h > 512) continue;
            if (phase > 7) continue;
            const mask_len = @as(usize, w) * @as(usize, h);
            if (@as(u64, offset) + mask_len > data.len) return error.InvalidGlyphAtlas;
            const pixels = data[pixels_at + offset .. pixels_at + offset + mask_len];
            const key = keyOf(cp, size_q, bold, phase);
            if (self.entries.contains(key)) continue;
            const entry = try atlas.addMask(pixels, w, h, left, top);
            try self.entries.put(key, entry);
        }
        return self;
    }

    pub fn deinit(self: *Baked) void {
        self.entries.deinit();
    }

    pub fn lookup(
        self: *const Baked,
        cp: u21,
        size: f32,
        bold: bool,
        pen_x: f32,
        baseline_y: f32,
    ) ?Placed {
        const size_q: u16 = @intFromFloat(@round(@max(1, size) * 16));
        const qx = @round(pen_x * 4) / 4;
        const base_x = @floor(qx);
        var px: u8 = @intFromFloat(@round((qx - base_x) * 4));
        var base_x_int = base_x;
        if (px == 4) {
            px = 0;
            base_x_int += 1;
        }
        const qy = @round(baseline_y * 2) / 2;
        var base_y = @floor(qy);
        var py: u8 = @intFromFloat(@round((qy - base_y) * 2));
        if (py == 2) {
            py = 0;
            base_y += 1;
        }
        const phase = px | (py << 2);
        const entry = self.entries.get(keyOf(cp, size_q, bold, phase)) orelse return null;
        return .{ .entry = entry, .x = base_x_int + @as(f32, @floatFromInt(entry.left)), .y = base_y + @as(f32, @floatFromInt(entry.top)) };
    }

    fn keyOf(cp: u32, size_q: u16, bold: bool, phase: u8) u64 {
        return @as(u64, cp) << 24 |
            @as(u64, size_q) << 8 |
            @as(u64, @intFromBool(bold)) << 7 |
            @as(u64, phase & 7);
    }
};

fn readU16(data: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, data[at..][0..2], .little);
}

fn readU32(data: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, data[at..][0..4], .little);
}

test "baked atlas parses and resolves a known glyph" {
    var atlas = try draw.Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var baked = try Baked.init(std.testing.allocator, &atlas);
    defer baked.deinit();
    const hit = baked.lookup('a', 10.5, false, 10.25, 30.0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit.entry.width > 0);
    try std.testing.expect(hit.entry.height > 0);
    try std.testing.expect(baked.lookup(0x10ffff, 10.5, false, 0, 0) == null);
}
