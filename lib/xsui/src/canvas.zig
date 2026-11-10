//! Absolute-pixel design canvas for the operator console.
//!
//! Unlike the immediate `Ui` layout builder, `Canvas` works in explicit logical
//! rectangles. The design tokens define geometry; screens compute rects from
//! them. It provides deterministic text layout, clipping, hit registration,
//! lines, rounded surfaces, and vector-mask icons on top of the same DrawList
//! the CPU, Metal, and GL backends consume.

const std = @import("std");
const a11y = @import("a11y.zig");
const draw = @import("draw.zig");
const frame_mod = @import("frame.zig");
const layout = @import("layout.zig");
const ttf = @import("ttf.zig");

pub const Rect = layout.Rect;
pub const Color = draw.Color;
pub const FontWeight = layout.FontWeight;

pub const HorizontalAlign = enum { left, center, right };
pub const VerticalAlign = enum { top, center, bottom };

pub const TextStyle = struct {
    size: f32 = 12,
    weight: FontWeight = .regular,
    color: Color = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    tracking: f32 = 0,
    line_height: f32 = 1.5,
    text_align: HorizontalAlign = .left,
    valign: VerticalAlign = .top,
    wrap: bool = false,
    ellipsis: bool = false,
    max_lines: usize = 0,
};

pub const Line = struct {
    text: []const u8,
    width: f32,
    ellipsis: bool = false,
};

pub const TextLayout = struct {
    lines: [64]Line = undefined,
    count: usize = 0,
    width: f32 = 0,
    line_height: f32 = 0,

    pub fn height(self: *const TextLayout) f32 {
        return @as(f32, @floatFromInt(self.count)) * self.line_height;
    }
};

/// One entry in the draw/hit pass. Pointer input, keyboard focus, and the
/// accessibility tree all derive from this single list, so they cannot drift.
pub const Hit = struct {
    rect: Rect,
    id: u32,
    /// Semantic role; `.none` is a legacy pointer-only hit with no AX content.
    role: a11y.Role = .none,
    label: []const u8 = "",
    value: []const u8 = "",
    /// Short usage hint, e.g. "⌘K" or "Enter to activate".
    hint: []const u8 = "",
    /// Opaque caller data (for example a row index); ids stay stable.
    data: u32 = 0,
    /// Static state; dynamic focus is resolved from `App.state.focus_id`.
    flags: a11y.Flags = .{},
    /// Clip region [x0,y0,x1,y1] captured when the node was registered.
    /// Pointer hit-testing and accessibility frames obey it.
    clip: [4]f32 = .{ 0, 0, 0, 0 },
    /// Immediate semantic parent id; 0 means the root.
    parent: u32 = 0,
};

/// Registers a semantic hit node in the current group.
pub const NodeSpec = struct {
    id: u32,
    rect: Rect,
    role: a11y.Role,
    label: []const u8 = "",
    value: []const u8 = "",
    hint: []const u8 = "",
    data: u32 = 0,
    flags: a11y.Flags = .{ .interactive = true, .focusable = true },
};

/// Registers a structural group so following nodes nest under `id`.
pub const GroupSpec = struct {
    id: u32,
    rect: Rect,
    role: a11y.Role = .group,
    label: []const u8 = "",
    hint: []const u8 = "",
    /// Structural groups are not pointer-hittable or focusable by default.
    flags: a11y.Flags = .{},
};

pub const Icon = struct {
    size: f32,
    draw: *const fn (canvas: *Canvas, rect: Rect, color: Color) anyerror!void,
};

fn nextCodepoint(text: []const u8, index: *usize) u21 {
    const b0 = text[index.*];
    if (b0 < 0x80) {
        index.* += 1;
        return b0;
    }
    const len: usize = if (b0 & 0xe0 == 0xc0) 2 else if (b0 & 0xf0 == 0xe0) 3 else if (b0 & 0xf8 == 0xf0) 4 else 1;
    if (index.* + len > text.len) {
        index.* += 1;
        return 0xfffd;
    }
    var cp: u21 = switch (len) {
        2 => b0 & 0x1f,
        3 => b0 & 0x0f,
        4 => b0 & 0x07,
        else => b0,
    };
    var i: usize = 1;
    while (i < len) : (i += 1) {
        cp = (cp << 6) | (text[index.* + i] & 0x3f);
    }
    index.* += len;
    return cp;
}

pub fn measureText(font: *const ttf.Font, size: f32, tracking: f32, text_value: []const u8) f32 {
    var width: f32 = 0;
    var index: usize = 0;
    while (index < text_value.len) {
        const cp = nextCodepoint(text_value, &index);
        const gid = font.glyphIndex(cp);
        width += @as(f32, @floatFromInt(font.advance(gid))) * size /
            @as(f32, @floatFromInt(font.units_per_em));
        if (index < text_value.len) width += tracking;
    }
    return width;
}

/// Bounded semantic string lengths copied into the per-frame arena.
pub const max_label_bytes: usize = 160;
pub const max_value_bytes: usize = 160;
pub const max_hint_bytes: usize = 64;

/// Copies at most `limit` bytes, backing off to a UTF-8 code-point boundary so
/// canonical JSON never receives a split sequence.
fn copyBounded(allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]const u8 {
    if (text.len == 0) return "";
    var len = @min(text.len, limit);
    if (len < text.len) {
        while (len > 0 and (text[len] & 0xc0) == 0x80) len -= 1;
    }
    const owned = try allocator.alloc(u8, len);
    @memcpy(owned, text[0..len]);
    return owned;
}

pub const Canvas = struct {
    frame: *frame_mod.Frame,
    allocator: std.mem.Allocator,
    clip_rect: Rect,
    clip_stack: [16]Rect = undefined,
    clip_depth: usize = 0,
    hits: std.ArrayList(Hit) = .empty,
    max_hits: usize = 512,
    /// Per-frame copies of semantic labels/values. Hits are registered during
    /// paint with caller-owned (often stack) strings; copying here keeps the
    /// draw/hit/AX pass self-contained for snapshots and native bridges that
    /// read the hit list after the painting functions return.
    semantic_arena: std.heap.ArenaAllocator,
    /// Semantic nesting for the current frame (region -> control groups).
    group_stack: [16]u32 = undefined,
    group_depth: usize = 0,
    /// Set when the bounded hit list overflowed; surfaced as DEGRADED.
    truncated: bool = false,

    pub fn init(frame: *frame_mod.Frame) Canvas {
        return .{
            .frame = frame,
            .allocator = frame.allocator,
            .semantic_arena = std.heap.ArenaAllocator.init(frame.allocator),
            .clip_rect = .{
                .x = 0,
                .y = 0,
                .w = @floatFromInt(frame.width),
                .h = @floatFromInt(frame.height),
            },
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.hits.deinit(self.allocator);
        self.semantic_arena.deinit();
    }

    pub fn resetHits(self: *Canvas) void {
        self.hits.clearRetainingCapacity();
        _ = self.semantic_arena.reset(.retain_capacity);
        self.group_depth = 0;
        self.truncated = false;
    }

    /// Recomputes the base clip from the frame after a resize.
    pub fn resetViewport(self: *Canvas) void {
        self.clip_rect = .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.frame.width),
            .h = @floatFromInt(self.frame.height),
        };
        self.clip_depth = 0;
    }

    fn clipArray(self: *const Canvas) [4]f32 {
        return .{
            self.clip_rect.x,
            self.clip_rect.y,
            self.clip_rect.x + self.clip_rect.w,
            self.clip_rect.y + self.clip_rect.h,
        };
    }

    pub fn pushClip(self: *Canvas, rect: Rect) void {
        if (self.clip_depth >= self.clip_stack.len) return;
        self.clip_stack[self.clip_depth] = self.clip_rect;
        self.clip_depth += 1;
        self.clip_rect = intersect(self.clip_rect, rect);
    }

    pub fn popClip(self: *Canvas) void {
        if (self.clip_depth == 0) return;
        self.clip_depth -= 1;
        self.clip_rect = self.clip_stack[self.clip_depth];
    }

    pub fn fill(self: *Canvas, rect: Rect, color: Color) !void {
        if (rect.w <= 0 or rect.h <= 0) return;
        try self.frame.list.rect(rect.x, rect.y, rect.w, rect.h, color, self.clipArray());
    }

    pub fn rounded(self: *Canvas, rect: Rect, radius: f32, color: Color, border: ?Color, border_width: f32) !void {
        if (rect.w <= 0 or rect.h <= 0) return;
        try self.frame.list.roundedRect(
            rect.x,
            rect.y,
            rect.w,
            rect.h,
            radius,
            color,
            border,
            border_width,
            self.clipArray(),
        );
    }

    pub fn stroke(self: *Canvas, rect: Rect, radius: f32, color: Color, width: f32) !void {
        try self.rounded(rect, radius, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, color, width);
    }

    pub fn line(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: Color) !void {
        if (width <= 0) return;
        const dx = x1 - x0;
        const dy = y1 - y0;
        if (@abs(dx) < 0.5 and @abs(dy) < 0.5) return;
        if (@abs(dy) < 0.5) {
            try self.fill(.{ .x = @min(x0, x1), .y = y0 - width * 0.5, .w = @abs(dx), .h = width }, color);
            return;
        }
        if (@abs(dx) < 0.5) {
            try self.fill(.{ .x = x0 - width * 0.5, .y = @min(y0, y1), .w = width, .h = @abs(dy) }, color);
            return;
        }
        const steps: usize = @intFromFloat(@ceil(@max(@abs(dx), @abs(dy))));
        var step: usize = 0;
        while (step <= steps) : (step += 1) {
            const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(@max(1, steps)));
            const px = x0 + dx * t;
            const py = y0 + dy * t;
            try self.fill(.{ .x = px - width * 0.5, .y = py - width * 0.5, .w = width, .h = width }, color);
        }
    }

    pub fn dashedLine(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, dash: f32, gap: f32, color: Color) !void {
        const horizontal = @abs(x1 - x0) >= @abs(y1 - y0);
        const length = if (horizontal) @abs(x1 - x0) else @abs(y1 - y0);
        const step = dash + gap;
        if (step <= 0) return self.line(x0, y0, x1, y1, width, color);
        var offset: f32 = 0;
        while (offset < length) : (offset += step) {
            const end = @min(length, offset + dash);
            if (horizontal) {
                const start_x = if (x0 <= x1) x0 + offset else x0 - offset;
                const end_x = if (x0 <= x1) x0 + end else x0 - end;
                try self.fill(.{ .x = @min(start_x, end_x), .y = y0 - width * 0.5, .w = end - offset, .h = width }, color);
            } else {
                const start_y = if (y0 <= y1) y0 + offset else y0 - offset;
                const end_y = if (y0 <= y1) y0 + end else y0 - end;
                try self.fill(.{ .x = x0 - width * 0.5, .y = @min(start_y, end_y), .w = width, .h = end - offset }, color);
            }
        }
    }

    pub fn circle(self: *Canvas, cx: f32, cy: f32, radius: f32, color: Color) !void {
        try self.rounded(.{ .x = cx - radius, .y = cy - radius, .w = radius * 2, .h = radius * 2 }, radius, color, null, 0);
    }

    fn fontFor(self: *Canvas, weight: FontWeight) *const ttf.Font {
        return if (weight == .bold) &self.frame.bold else &self.frame.regular;
    }

    pub fn layoutText(self: *Canvas, style: TextStyle, text_value: []const u8, max_width: f32, out: *TextLayout) !void {
        const font = self.fontFor(style.weight);
        out.* = .{ .line_height = style.size * style.line_height };
        var line_start: usize = 0;
        var line_width: f32 = 0;
        var last_space: ?usize = null;
        var line_index: usize = 0;
        const limit = if (style.max_lines == 0) out.lines.len else @min(out.lines.len, style.max_lines + 1);
        var index: usize = 0;
        while (index < text_value.len) {
            const byte_index = index;
            const cp = nextCodepoint(text_value, &index);
            if (cp == '\n') {
                try self.emitLine(out, &line_index, text_value[line_start..byte_index], line_width, false);
                line_start = index;
                line_width = 0;
                last_space = null;
                if (line_index >= limit) break;
                continue;
            }
            const glyph_width = @as(f32, @floatFromInt(font.advance(font.glyphIndex(cp)))) *
                style.size / @as(f32, @floatFromInt(font.units_per_em));
            const tracking = if (index < text_value.len) style.tracking else 0;
            if (style.wrap and max_width > 0 and line_width + glyph_width + tracking > max_width and byte_index > line_start) {
                var break_at = byte_index;
                if (last_space) |space| break_at = space;
                try self.emitLine(out, &line_index, text_value[line_start..break_at], line_width, false);
                if (line_index >= limit) break;
                line_start = break_at;
                if (line_start < text_value.len and text_value[line_start] == ' ') line_start += 1;
                line_width = 0;
                last_space = null;
                index = line_start;
                continue;
            }
            if (cp == ' ') last_space = byte_index;
            line_width += glyph_width + tracking;
        }
        if (line_index < out.lines.len and line_start <= text_value.len) {
            try self.emitLine(out, &line_index, text_value[line_start..], line_width, false);
        }
        out.count = @min(line_index, out.lines.len);
        if (style.max_lines != 0 and out.count > style.max_lines) {
            out.count = style.max_lines;
            if (out.count > 0) out.lines[out.count - 1].ellipsis = style.ellipsis;
        }
        if (!style.wrap and out.count == 1 and max_width > 0 and out.lines[0].width > max_width and style.ellipsis) {
            out.lines[0].ellipsis = true;
        }
        var widest: f32 = 0;
        for (out.lines[0..out.count]) |line_item| widest = @max(widest, line_item.width);
        out.width = widest;
    }

    fn emitLine(_: *Canvas, out: *TextLayout, index: *usize, text_value: []const u8, width: f32, ellipsis: bool) !void {
        if (index.* >= out.lines.len) return;
        out.lines[index.*] = .{ .text = text_value, .width = width, .ellipsis = ellipsis };
        index.* += 1;
    }

    pub fn measure(self: *Canvas, style: TextStyle, text_value: []const u8, max_width: f32, out: *TextLayout) !layout.Size {
        try self.layoutText(style, text_value, max_width, out);
        return .{ .w = out.width, .h = out.height() };
    }

    pub fn textIn(self: *Canvas, rect: Rect, style: TextStyle, text_value: []const u8) !f32 {
        var text_layout: TextLayout = .{};
        try self.layoutText(style, text_value, rect.w, &text_layout);
        const block_h = text_layout.height();
        const top = switch (style.valign) {
            .top => rect.y,
            .center => rect.y + (rect.h - block_h) * 0.5,
            .bottom => rect.y + rect.h - block_h,
        };
        const font = self.fontFor(style.weight);
        const ascender = @as(f32, @floatFromInt(font.ascender)) * style.size /
            @as(f32, @floatFromInt(font.units_per_em));
        const descender = @as(f32, @floatFromInt(-font.descender)) * style.size /
            @as(f32, @floatFromInt(font.units_per_em));
        const half_leading = (text_layout.line_height - (ascender + descender)) * 0.5;
        for (text_layout.lines[0..text_layout.count], 0..) |line_item, line_index| {
            const line_x = switch (style.text_align) {
                .left => rect.x,
                .center => rect.x + (rect.w - line_item.width) * 0.5,
                .right => rect.x + rect.w - line_item.width,
            };
            const baseline = top + @as(f32, @floatFromInt(line_index)) * text_layout.line_height + half_leading + ascender;
            var pen = line_x;
            var index: usize = 0;
            while (index < line_item.text.len) {
                const cp = nextCodepoint(line_item.text, &index);
                if (cp < 32) continue;
                const gid = font.glyphIndex(cp);
                var entry: draw.GlyphEntry = undefined;
                var glyph_x: f32 = 0;
                var glyph_y: f32 = 0;
                var baked_hit = false;
                if (self.frame.baked.lookup(cp, style.size, style.weight == .bold, pen, baseline)) |placed| {
                    entry = placed.entry;
                    glyph_x = placed.x;
                    glyph_y = placed.y;
                    baked_hit = true;
                } else {
                    entry = try self.frame.list.atlas.glyphF(
                        if (style.weight == .bold) 1 else 0,
                        font,
                        gid,
                        style.size,
                    );
                    glyph_x = pen + @as(f32, @floatFromInt(entry.left));
                    glyph_y = baseline - @as(f32, @floatFromInt(entry.top));
                }
                if (entry.width != 0 and entry.height != 0) {
                    try self.frame.list.items.append(self.frame.list.allocator, .{
                        .rect = .{
                            glyph_x,
                            glyph_y,
                            @floatFromInt(entry.width),
                            @floatFromInt(entry.height),
                        },
                        .clip = self.clipArray(),
                        .uv = entry.uv,
                        .color = style.color.toU32(),
                        .mode = @backingInt(draw.Mode.glyph),
                    });
                }
                const advance = @as(f32, @floatFromInt(font.advance(gid))) * style.size /
                    @as(f32, @floatFromInt(font.units_per_em));
                pen += advance + style.tracking;
            }
            if (line_item.ellipsis) {
                const entry = try self.frame.list.atlas.glyphF(
                    if (style.weight == .bold) 1 else 0,
                    font,
                    font.glyphIndex(0x2026),
                    style.size,
                );
                if (entry.width != 0) {
                    try self.frame.list.items.append(self.frame.list.allocator, .{
                        .rect = .{
                            pen,
                            baseline - @as(f32, @floatFromInt(entry.top)),
                            @floatFromInt(entry.width),
                            @floatFromInt(entry.height),
                        },
                        .clip = self.clipArray(),
                        .uv = entry.uv,
                        .color = style.color.toU32(),
                        .mode = @backingInt(draw.Mode.glyph),
                    });
                }
            }
        }
        return block_h;
    }

    /// Registers one semantic hit node in the current group. Returns its id,
    /// or 0 when the bounded hit list is full (`truncated` is set).
    ///
    /// Label/value/hint are copied into a per-frame arena (bounded lengths) so
    /// the hit pass owns its semantic strings: paint functions may pass stack
    /// buffers, and readers of `hits` after the frame stay valid until the
    /// next `resetHits`.
    pub fn node(self: *Canvas, spec: NodeSpec) u32 {
        if (self.hits.items.len >= self.max_hits) {
            self.truncated = true;
            return 0;
        }
        const arena_alloc = self.semantic_arena.allocator();
        const label = copyBounded(arena_alloc, spec.label, max_label_bytes) catch {
            self.truncated = true;
            return 0;
        };
        const value = copyBounded(arena_alloc, spec.value, max_value_bytes) catch {
            self.truncated = true;
            return 0;
        };
        const hint = copyBounded(arena_alloc, spec.hint, max_hint_bytes) catch {
            self.truncated = true;
            return 0;
        };
        const parent = if (self.group_depth > 0) self.group_stack[self.group_depth - 1] else 0;
        self.hits.append(self.allocator, .{
            .rect = spec.rect,
            .id = spec.id,
            .role = spec.role,
            .label = label,
            .value = value,
            .hint = hint,
            .data = spec.data,
            .flags = spec.flags,
            .clip = self.clipArray(),
            .parent = parent,
        }) catch {
            self.truncated = true;
            return 0;
        };
        return spec.id;
    }

    /// Legacy pointer-only hit. Prefer `node` so accessibility content is kept.
    pub fn hit(self: *Canvas, id: u32, rect: Rect) void {
        _ = self.node(.{ .id = id, .rect = rect, .role = .none });
    }

    /// Registers an accessible button (interactive + focusable).
    pub fn button(self: *Canvas, id: u32, rect: Rect, name: []const u8) u32 {
        return self.node(.{ .id = id, .rect = rect, .role = .button, .label = name });
    }

    /// Registers a selectable button (menu row, filter chip, source card,
    /// theme option) and carries its selected state to AX.
    pub fn choice(self: *Canvas, id: u32, rect: Rect, name: []const u8, selected: bool) u32 {
        return self.node(.{
            .id = id,
            .rect = rect,
            .role = .button,
            .label = name,
            .flags = .{ .interactive = true, .focusable = true, .selected = selected },
        });
    }

    /// Registers a switch/toggle and carries its checked state to AX.
    pub fn checkbox(self: *Canvas, id: u32, rect: Rect, name: []const u8, checked: bool) u32 {
        return self.node(.{
            .id = id,
            .rect = rect,
            .role = .toggle,
            .label = name,
            .flags = .{ .interactive = true, .focusable = true, .checked = checked },
        });
    }

    /// Registers a text input with its current (bounded) value.
    pub fn textField(self: *Canvas, id: u32, rect: Rect, name: []const u8, value: []const u8) u32 {
        return self.node(.{ .id = id, .rect = rect, .role = .text_field, .label = name, .value = value });
    }

    /// Registers a selectable list row (ledger row, picker entry, slice).
    pub fn listItem(self: *Canvas, id: u32, rect: Rect, name: []const u8, selected: bool) u32 {
        return self.node(.{
            .id = id,
            .rect = rect,
            .role = .list_item,
            .label = name,
            .flags = .{ .interactive = true, .focusable = true, .selected = selected },
        });
    }

    /// Registers a navigation tab (rail item) with its selected state.
    pub fn tabItem(self: *Canvas, id: u32, rect: Rect, name: []const u8, selected: bool) u32 {
        return self.node(.{
            .id = id,
            .rect = rect,
            .role = .tab,
            .label = name,
            .flags = .{ .interactive = true, .focusable = true, .selected = selected },
        });
    }

    /// Registers non-interactive semantic text (`static_text`, `status`, ...)
    /// so AX exposes headings and live status without making them hittable.
    pub fn semanticText(
        self: *Canvas,
        id: u32,
        rect: Rect,
        role: a11y.Role,
        name: []const u8,
        value: []const u8,
    ) u32 {
        return self.node(.{
            .id = id,
            .rect = rect,
            .role = role,
            .label = name,
            .value = value,
            .flags = .{},
        });
    }

    /// Starts a semantic group; following `node` calls nest under `spec.id`.
    pub fn pushGroup(self: *Canvas, spec: GroupSpec) void {
        _ = self.node(.{
            .id = spec.id,
            .rect = spec.rect,
            .role = spec.role,
            .label = spec.label,
            .hint = spec.hint,
            .flags = spec.flags,
        });
        if (self.group_depth < self.group_stack.len) {
            self.group_stack[self.group_depth] = spec.id;
            self.group_depth += 1;
        }
    }

    pub fn popGroup(self: *Canvas) void {
        if (self.group_depth > 0) self.group_depth -= 1;
    }

    pub fn hitIndex(self: *const Canvas, id: u32) ?usize {
        for (self.hits.items, 0..) |item, index| {
            if (item.id == id) return index;
        }
        return null;
    }

    pub fn hitData(self: *const Canvas, id: u32) ?u32 {
        const index = self.hitIndex(id) orelse return null;
        return self.hits.items[index].data;
    }

    pub fn hitRect(self: *const Canvas, id: u32) ?Rect {
        var index = self.hits.items.len;
        while (index > 0) {
            index -= 1;
            const item = self.hits.items[index];
            if (item.id == id) return item.rect;
        }
        return null;
    }

    /// Pointer hit test: last drawn wins; clipped, structural (non-interactive)
    /// and disabled nodes are skipped. Invariant: equals `a11y.Tree.hitTest`.
    pub fn hitAt(self: *const Canvas, x: f32, y: f32) ?u32 {
        var index = self.hits.items.len;
        while (index > 0) {
            index -= 1;
            const item = self.hits.items[index];
            if (!item.flags.interactive or item.flags.disabled) continue;
            if (x < item.rect.x or y < item.rect.y) continue;
            if (x >= item.rect.x + item.rect.w or y >= item.rect.y + item.rect.h) continue;
            if (x < item.clip[0] or y < item.clip[1]) continue;
            if (x > item.clip[2] or y > item.clip[3]) continue;
            return item.id;
        }
        return null;
    }
};

fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

test "text measures fractional sizes and wraps" {
    var frame: frame_mod.Frame = undefined;
    try frame.init(std.testing.allocator, 200, 100, .{});
    defer frame.deinit();
    var canvas = Canvas.init(&frame);
    defer canvas.deinit();
    const style: TextStyle = .{ .size = 10.5, .line_height = 1.5, .wrap = true };
    var layout_data: TextLayout = .{};
    const size = try canvas.measure(style, "hello world from xsui", 60, &layout_data);
    try std.testing.expect(size.w <= 60.0);
    try std.testing.expect(size.h > 10.0);
    try std.testing.expect(layout_data.count > 1);
}

test "canvas registers hits and clips" {
    var frame: frame_mod.Frame = undefined;
    try frame.init(std.testing.allocator, 100, 80, .{});
    defer frame.deinit();
    var canvas = Canvas.init(&frame);
    defer canvas.deinit();
    canvas.pushClip(.{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try canvas.fill(.{ .x = 40, .y = 40, .w = 40, .h = 40 }, frame.theme.live);
    canvas.popClip();
    canvas.hit(7, .{ .x = 10, .y = 10, .w = 20, .h = 20 });
    try std.testing.expectEqual(@as(?u32, 7), canvas.hitAt(15, 15));
}
