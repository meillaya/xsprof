//! Minimal TrueType reader + rasterizer for the bundled monospace font.
//! Supports simple glyphs, cmap formats 4/12, and horizontal metrics. Composite
//! glyphs render as tofu for v1 (ASCII/Latin-1 is the supported set).

const std = @import("std");

fn be16(data: []const u8, at: usize) u16 {
    return (@as(u16, data[at]) << 8) | data[at + 1];
}

fn f2dot14(value: i16) f32 {
    return @as(f32, @floatFromInt(value)) / 16384.0;
}

fn be32(data: []const u8, at: usize) u32 {
    return (@as(u32, data[at]) << 24) | (@as(u32, data[at + 1]) << 16) |
        (@as(u32, data[at + 2]) << 8) | data[at + 3];
}

fn tagEq(data: []const u8, at: usize, tag: *const [4]u8) bool {
    return data[at] == tag[0] and data[at + 1] == tag[1] and
        data[at + 2] == tag[2] and data[at + 3] == tag[3];
}

const Vec2 = struct { x: f32, y: f32 };
const Point = struct { x: f32, y: f32, on: bool };

pub const Glyph = struct {
    width: u32 = 0,
    height: u32 = 0,
    left: i32 = 0,
    top: i32 = 0,
    advance: u32 = 0,
    pixels: []u8 = &.{},

    pub fn deinit(self: Glyph, allocator: std.mem.Allocator) void {
        if (self.pixels.len != 0) allocator.free(self.pixels);
    }
};

const Cmap = union(enum) {
    format4: usize,
    format12: usize,
    none,
};

pub const Font = struct {
    data: []const u8,
    units_per_em: u16 = 1000,
    num_glyphs: u16 = 0,
    index_to_loc: i16 = 0,
    num_hmetrics: u16 = 1,
    ascender: i16 = 0,
    descender: i16 = 0,
    loca_offset: u32 = 0,
    glyf_offset: u32 = 0,
    hmtx_offset: u32 = 0,
    cmap: Cmap = .none,

    pub fn init(data: []const u8) !Font {
        if (data.len < 12) return error.BadFont;
        const num_tables = be16(data, 4);
        var font: Font = .{ .data = data };
        var cmap_offset: ?u32 = null;
        var head_offset: ?u32 = null;
        var maxp_offset: ?u32 = null;
        var hhea_offset: ?u32 = null;
        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const record = 12 + i * 16;
            if (record + 16 > data.len) return error.BadFont;
            const offset = be32(data, record + 8);
            const length = be32(data, record + 12);
            if (@as(u64, offset) + length > data.len) return error.BadFont;
            if (tagEq(data, record, "cmap")) cmap_offset = offset;
            if (tagEq(data, record, "head")) head_offset = offset;
            if (tagEq(data, record, "maxp")) maxp_offset = offset;
            if (tagEq(data, record, "hhea")) hhea_offset = offset;
            if (tagEq(data, record, "hmtx")) font.hmtx_offset = offset;
            if (tagEq(data, record, "loca")) font.loca_offset = offset;
            if (tagEq(data, record, "glyf")) font.glyf_offset = offset;
        }
        const head = head_offset orelse return error.BadFont;
        const maxp = maxp_offset orelse return error.BadFont;
        const hhea = hhea_offset orelse return error.BadFont;
        if (head + 54 > data.len or maxp + 6 > data.len or hhea + 36 > data.len) {
            return error.BadFont;
        }
        font.units_per_em = be16(data, head + 18);
        font.index_to_loc = @bitCast(be16(data, head + 50));
        font.num_glyphs = be16(data, maxp + 4);
        font.ascender = @bitCast(be16(data, hhea + 4));
        font.descender = @bitCast(be16(data, hhea + 6));
        font.num_hmetrics = be16(data, hhea + 34);
        font.cmap = findCmap(data, cmap_offset orelse return error.BadFont) catch .none;
        return font;
    }

    pub fn glyphIndex(self: Font, codepoint: u21) u16 {
        return switch (self.cmap) {
            .format4 => |at| self.cmap4(at, codepoint),
            .format12 => |at| self.cmap12(at, codepoint),
            .none => 0,
        };
    }

    fn cmap4(self: Font, at: usize, cp: u21) u16 {
        const c = self.data[at..];
        if (c.len < 16) return 0;
        const seg_count_x2 = be16(c, 6);
        const seg_count = seg_count_x2 / 2;
        const end_base = 14;
        const start_base = 16 + seg_count_x2;
        const delta_base = 16 + 2 * seg_count_x2;
        const range_base = 16 + 3 * seg_count_x2;
        if (range_base + seg_count_x2 > c.len) return 0;
        const value: u16 = @intCast(@min(cp, 0xffff));
        var i: usize = 0;
        while (i < seg_count) : (i += 1) {
            const end = be16(c, end_base + i * 2);
            if (value > end) continue;
            const start = be16(c, start_base + i * 2);
            if (value < start) return 0;
            const delta = be16(c, delta_base + i * 2);
            const range = be16(c, range_base + i * 2);
            if (range == 0) return (value +% delta);
            const address = range_base + i * 2 + range + (value - start) * 2;
            if (address + 2 > c.len) return 0;
            const gid = be16(c, address);
            if (gid == 0) return 0;
            return gid +% delta;
        }
        return 0;
    }

    fn cmap12(self: Font, at: usize, cp: u21) u16 {
        const c = self.data[at..];
        if (c.len < 16) return 0;
        const groups = be32(c, 12);
        if (groups > 0x10000) return 0;
        var i: usize = 0;
        while (i < groups) : (i += 1) {
            const base = 16 + i * 12;
            if (base + 12 > c.len) return 0;
            const start = be32(c, base);
            const end = be32(c, base + 4);
            if (cp < start or cp > end) continue;
            const gid = be32(c, base + 8) + (cp - start);
            if (gid > 0xffff) return 0;
            return @intCast(gid);
        }
        return 0;
    }

    pub fn advance(self: Font, gid: u16) u16 {
        if (gid >= self.num_glyphs or self.hmtx_offset == 0) return 0;
        const index = @min(gid, self.num_hmetrics - 1);
        const at = self.hmtx_offset + @as(u32, index) * 4;
        if (at + 2 > self.data.len) return 0;
        return be16(self.data, at);
    }

    fn glyphData(self: Font, gid: u16) ?[]const u8 {
        if (gid >= self.num_glyphs) return null;
        const loca = self.loca_offset;
        var start: u32 = 0;
        var end: u32 = 0;
        if (self.index_to_loc == 0) {
            const at = loca + @as(u32, gid) * 2;
            if (at + 4 > self.data.len) return null;
            start = @as(u32, be16(self.data, at)) * 2;
            end = @as(u32, be16(self.data, at + 2)) * 2;
        } else {
            const at = loca + @as(u32, gid) * 4;
            if (at + 8 > self.data.len) return null;
            start = be32(self.data, at);
            end = be32(self.data, at + 4);
        }
        if (end <= start) return null;
        const base = self.glyf_offset;
        if (@as(u64, base) + end > self.data.len) return null;
        return self.data[base + start .. base + end];
    }

    pub fn rasterize(
        self: Font,
        allocator: std.mem.Allocator,
        gid: u16,
        pixel_size: f32,
    ) !Glyph {
        const advance_units = self.advance(gid);
        const advance_px: u32 = @as(u32, @intFromFloat(@round(
            @as(f32, @floatFromInt(advance_units)) * pixel_size /
                @as(f32, @floatFromInt(self.units_per_em)),
        )));
        const glyph = self.glyphData(gid) orelse return .{ .advance = advance_px };
        if (glyph.len < 10) return .{ .advance = advance_px };
        const contours_i = @as(i16, @bitCast(be16(glyph, 0)));
        if (contours_i == 0) return .{ .advance = advance_px };
        const x_min = @as(i16, @bitCast(be16(glyph, 2)));
        const y_min = @as(i16, @bitCast(be16(glyph, 4)));
        const x_max = @as(i16, @bitCast(be16(glyph, 6)));
        const y_max = @as(i16, @bitCast(be16(glyph, 8)));
        if (x_max <= x_min or y_max <= y_min) return .{ .advance = advance_px };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const points = try collectGlyph(self, a, gid, 0);
        const scale = pixel_size / @as(f32, @floatFromInt(self.units_per_em));
        const width: u32 = @as(u32, @intFromFloat(@ceil(
            @as(f32, @floatFromInt(@as(i32, x_max) - @as(i32, x_min))) * scale,
        ))) + 2;
        const height: u32 = @as(u32, @intFromFloat(@ceil(
            @as(f32, @floatFromInt(@as(i32, y_max) - @as(i32, y_min))) * scale,
        ))) + 2;
        if (width == 0 or height == 0) return .{ .advance = advance_px };

        const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
        @memset(pixels, 0);
        const left: i32 = @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(x_min)) * scale))) - 1;
        const top: i32 = @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(y_max)) * scale))) + 1;
        try self.rasterizePoints(a, points, x_min, y_max, scale, width, height, pixels);
        return .{
            .width = width,
            .height = height,
            .left = left,
            .top = top,
            .advance = advance_px,
            .pixels = pixels,
        };
    }

    fn rasterizePoints(
        self: Font,
        allocator: std.mem.Allocator,
        contours: []const []const Point,
        x_min: i16,
        y_max: i16,
        scale: f32,
        width: u32,
        height: u32,
        pixels: []u8,
    ) !void {
        _ = self;
        const ss = 4;
        var edges: std.ArrayList(struct { x0: f32, y0: f32, x1: f32, y1: f32 }) = .empty;
        for (contours) |contour| {
            if (contour.len < 2) continue;
            const poly = try flatten(allocator, contour, x_min, y_max, scale, ss);
            var i: usize = 0;
            while (i < poly.len) : (i += 1) {
                const a = poly[i];
                const b = poly[(i + 1) % poly.len];
                if (a.y == b.y) continue;
                try edges.append(allocator, .{ .x0 = a.x, .y0 = a.y, .x1 = b.x, .y1 = b.y });
            }
        }
        const inv_samples: f32 = 1.0 / @as(f32, @floatFromInt(ss * ss));
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                var inside_count: u32 = 0;
                var sy: usize = 0;
                while (sy < ss) : (sy += 1) {
                    var sx: usize = 0;
                    while (sx < ss) : (sx += 1) {
                        const px = @as(f32, @floatFromInt(x * ss + sx)) + 0.5;
                        const py = @as(f32, @floatFromInt(y * ss + sy)) + 0.5;
                        var inside = false;
                        for (edges.items) |e| {
                            if ((e.y0 > py) == (e.y1 > py)) continue;
                            const xint = e.x0 + (py - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0);
                            if (xint > px) inside = !inside;
                        }
                        if (inside) inside_count += 1;
                    }
                }
                const coverage = @as(f32, @floatFromInt(inside_count)) * inv_samples;
                pixels[y * width + x] = @intFromFloat(@sqrt(coverage) * 255.0);
            }
        }
    }
};
fn flatten(
    allocator: std.mem.Allocator,
    contour: []const Point,
    x_min: i16,
    y_max: i16,
    scale: f32,
    ss: usize,
) ![]Vec2 {
    const n = contour.len;
    var poly: std.ArrayList(Vec2) = .empty;
    const Transform = struct {
        fn px(p: Point, xm: i16, ym: i16, s: f32, sub: usize) Vec2 {
            return .{
                .x = (p.x - @as(f32, @floatFromInt(xm)) + 1) * s * @as(f32, @floatFromInt(sub)),
                .y = (@as(f32, @floatFromInt(ym)) - p.y + 1) * s * @as(f32, @floatFromInt(sub)),
            };
        }
    };
    var start_idx: ?usize = null;
    for (contour, 0..) |p, i| {
        if (p.on) {
            start_idx = i;
            break;
        }
    }

    var start: Vec2 = undefined;
    var current: Vec2 = undefined;
    if (start_idx) |si| {
        start = Transform.px(contour[si], x_min, y_max, scale, ss);
        current = start;
        try poly.append(allocator, current);
        var i = (si + 1) % n;
        var guard: usize = 0;
        while (i != si and guard < n + 4) : (guard += 1) {
            const p = contour[i];
            if (p.on) {
                current = Transform.px(p, x_min, y_max, scale, ss);
                try poly.append(allocator, current);
                i = (i + 1) % n;
            } else {
                const next = contour[(i + 1) % n];
                const control = Transform.px(p, x_min, y_max, scale, ss);
                if (next.on) {
                    const end = Transform.px(next, x_min, y_max, scale, ss);
                    try appendQuad(allocator, &poly, current, control, end);
                    current = end;
                    if ((i + 1) % n == si) break;
                    i = (i + 2) % n;
                } else {
                    const mid = Vec2{
                        .x = (p.x + next.x) / 2,
                        .y = (p.y + next.y) / 2,
                    };
                    const end = Transform.px(.{ .x = mid.x, .y = mid.y, .on = true }, x_min, y_max, scale, ss);
                    try appendQuad(allocator, &poly, current, control, end);
                    current = end;
                    i = (i + 1) % n;
                }
            }
        }
        if (current.x != start.x or current.y != start.y) {
            try poly.append(allocator, start);
        }
    } else {
        const first = contour[0];
        const last = contour[n - 1];
        start = Transform.px(.{
            .x = (first.x + last.x) / 2,
            .y = (first.y + last.y) / 2,
            .on = true,
        }, x_min, y_max, scale, ss);
        current = start;
        try poly.append(allocator, current);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = contour[i];
            const next = contour[(i + 1) % n];
            const control = Transform.px(p, x_min, y_max, scale, ss);
            const mid = Vec2{ .x = (p.x + next.x) / 2, .y = (p.y + next.y) / 2 };
            const end = Transform.px(.{ .x = mid.x, .y = mid.y, .on = true }, x_min, y_max, scale, ss);
            try appendQuad(allocator, &poly, current, control, end);
            current = end;
        }
    }
    return poly.toOwnedSlice(allocator);
}

fn appendQuad(
    allocator: std.mem.Allocator,
    poly: *std.ArrayList(Vec2),
    from: Vec2,
    control: Vec2,
    to: Vec2,
) !void {
    const steps = 8;
    var step: usize = 1;
    while (step <= steps) : (step += 1) {
        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
        const mt = 1.0 - t;
        try poly.append(allocator, .{
            .x = mt * mt * from.x + 2 * mt * t * control.x + t * t * to.x,
            .y = mt * mt * from.y + 2 * mt * t * control.y + t * t * to.y,
        });
    }
}

fn collectGlyph(
    self: Font,
    allocator: std.mem.Allocator,
    gid: u16,
    depth: u8,
) ![]const []const Point {
    if (depth > 8) return &.{};
    const glyph = self.glyphData(gid) orelse return &.{};
    if (glyph.len < 10) return &.{};
    const contours = @as(i16, @bitCast(be16(glyph, 0)));
    if (contours > 0) return parseSimple(glyph, allocator, @intCast(contours));
    if (contours == 0) return &.{};

    var at: usize = 10;
    var result: std.ArrayList([]const Point) = .empty;
    var more = true;
    while (more) {
        if (at + 4 > glyph.len) break;
        const flags = be16(glyph, at);
        const child_gid = be16(glyph, at + 2);
        at += 4;
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (flags & 0x0001 != 0) {
            if (at + 4 > glyph.len) break;
            dx = @floatFromInt(@as(i16, @bitCast(be16(glyph, at))));
            dy = @floatFromInt(@as(i16, @bitCast(be16(glyph, at + 2))));
            at += 4;
        } else {
            if (at + 2 > glyph.len) break;
            dx = @floatFromInt(@as(i8, @bitCast(glyph[at])));
            dy = @floatFromInt(@as(i8, @bitCast(glyph[at + 1])));
            at += 2;
        }
        var xx: f32 = 1;
        var yy: f32 = 1;
        var xy: f32 = 0;
        var yx: f32 = 0;
        if (flags & 0x0008 != 0) {
            if (at + 2 > glyph.len) break;
            const scale = f2dot14(@as(i16, @bitCast(be16(glyph, at))));
            xx = scale;
            yy = scale;
            at += 2;
        } else if (flags & 0x0040 != 0) {
            if (at + 4 > glyph.len) break;
            xx = f2dot14(@as(i16, @bitCast(be16(glyph, at))));
            yy = f2dot14(@as(i16, @bitCast(be16(glyph, at + 2))));
            at += 4;
        } else if (flags & 0x0080 != 0) {
            if (at + 8 > glyph.len) break;
            xx = f2dot14(@as(i16, @bitCast(be16(glyph, at))));
            xy = f2dot14(@as(i16, @bitCast(be16(glyph, at + 2))));
            yx = f2dot14(@as(i16, @bitCast(be16(glyph, at + 4))));
            yy = f2dot14(@as(i16, @bitCast(be16(glyph, at + 6))));
            at += 8;
        }
        const children = try collectGlyph(self, allocator, child_gid, depth + 1);
        for (children) |contour| {
            const moved = try allocator.alloc(Point, contour.len);
            for (contour, 0..) |point, index| {
                moved[index] = .{
                    .x = point.x * xx + point.y * xy + dx,
                    .y = point.x * yx + point.y * yy + dy,
                    .on = point.on,
                };
            }
            try result.append(allocator, moved);
        }
        more = flags & 0x0020 != 0;
    }
    return result.toOwnedSlice(allocator);
}

fn parseSimple(glyph: []const u8, allocator: std.mem.Allocator, contour_count: usize) ![]const []const Point {
    if (glyph.len < 10 + contour_count * 2 + 2) return error.BadFont;
    const end_pts = try allocator.alloc(u16, contour_count);
    var i: usize = 0;
    while (i < contour_count) : (i += 1) end_pts[i] = be16(glyph, 10 + i * 2);
    const instruction_len = be16(glyph, 10 + contour_count * 2);
    var at = 12 + contour_count * 2 + instruction_len;
    if (at > glyph.len) return error.BadFont;
    const point_count: usize = @as(usize, end_pts[contour_count - 1]) + 1;
    if (point_count == 0 or point_count > 0x10000) return error.BadFont;

    const flags = try allocator.alloc(u8, point_count);
    i = 0;
    while (i < point_count) {
        if (at >= glyph.len) return error.BadFont;
        const f = glyph[at];
        at += 1;
        flags[i] = f;
        i += 1;
        if (f & 0x08 != 0) {
            if (at >= glyph.len) return error.BadFont;
            const repeat = glyph[at];
            at += 1;
            var r: usize = 0;
            while (r < repeat and i < point_count) : (r += 1) {
                flags[i] = f;
                i += 1;
            }
        }
    }

    var xs = try allocator.alloc(f32, point_count);
    var ys = try allocator.alloc(f32, point_count);
    var x: f32 = 0;
    var y: f32 = 0;
    i = 0;
    while (i < point_count) : (i += 1) {
        const f = flags[i];
        if (f & 0x02 != 0) {
            if (at >= glyph.len) return error.BadFont;
            const delta = glyph[at];
            at += 1;
            x += if (f & 0x10 != 0) @as(f32, @floatFromInt(delta)) else -@as(f32, @floatFromInt(delta));
        } else if (f & 0x10 == 0) {
            if (at + 2 > glyph.len) return error.BadFont;
            x += @as(f32, @floatFromInt(@as(i16, @bitCast(be16(glyph, at)))));
            at += 2;
        }
        xs[i] = x;
    }
    i = 0;
    while (i < point_count) : (i += 1) {
        const f = flags[i];
        if (f & 0x04 != 0) {
            if (at >= glyph.len) return error.BadFont;
            const delta = glyph[at];
            at += 1;
            y += if (f & 0x20 != 0) @as(f32, @floatFromInt(delta)) else -@as(f32, @floatFromInt(delta));
        } else if (f & 0x20 == 0) {
            if (at + 2 > glyph.len) return error.BadFont;
            y += @as(f32, @floatFromInt(@as(i16, @bitCast(be16(glyph, at)))));
            at += 2;
        }
        ys[i] = y;
    }

    var points = try allocator.alloc(Point, point_count);
    for (points, 0..) |*p, index| p.* = .{
        .x = xs[index],
        .y = ys[index],
        .on = flags[index] & 1 != 0,
    };
    var result = try allocator.alloc([]const Point, contour_count);
    var start: usize = 0;
    for (end_pts, 0..) |end, index| {
        const stop: usize = @as(usize, end) + 1;
        result[index] = points[start..stop];
        start = stop;
    }
    return result;
}

fn findCmap(data: []const u8, offset: u32) !Cmap {
    const c = data[offset..];
    if (c.len < 4) return .none;
    const count = be16(c, 2);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const record = 4 + i * 8;
        if (record + 8 > c.len) break;
        const sub = be16(c, record + 6);
        if (sub + 2 > c.len) continue;
        const format = be16(c, sub);
        if (format == 12) return .{ .format12 = offset + sub };
        if (format == 4) return .{ .format4 = offset + sub };
    }
    return .none;
}

test "bundled font loads and rasterizes A" {
    const fonts = @import("fonts");
    var font = try Font.init(fonts.regular);
    try std.testing.expect(font.units_per_em > 0);
    const gid = font.glyphIndex('A');
    try std.testing.expect(gid != 0);
    try std.testing.expectEqual(@as(u16, 737), font.glyphIndex('0'));
    try std.testing.expectEqual(@as(u16, 740), font.glyphIndex('3'));
    try std.testing.expect(font.advance(gid) > 0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const glyph = try font.rasterize(arena.allocator(), gid, 14);
    try std.testing.expect(glyph.width > 0 and glyph.height > 0);
    var ink: u32 = 0;
    for (glyph.pixels) |p| ink += p;
    try std.testing.expect(ink > 0);

    const lower_i = font.glyphIndex('i');
    const lower_glyph = try font.rasterize(arena.allocator(), lower_i, 14);
    var lower_ink: u32 = 0;
    for (lower_glyph.pixels) |p| lower_ink += p;
    try std.testing.expect(lower_glyph.width > 0);
    try std.testing.expect(lower_ink > 0);
}
