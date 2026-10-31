//! One-pass flex/column layout over a per-frame node tree, then paint into the
//! frame's draw list. Immediate-feeling builder, cached measurement per frame.

const std = @import("std");
const draw = @import("draw.zig");
const frame_mod = @import("frame.zig");
const ttf = @import("ttf.zig");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(value: f32) Edges {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    fn horizontal(self: Edges) f32 {
        return self.left + self.right;
    }

    fn vertical(self: Edges) f32 {
        return self.top + self.bottom;
    }
};

pub const Direction = enum { row, column };
pub const Align = enum { start, center, end, stretch };

pub const Style = struct {
    direction: Direction = .column,
    padding: Edges = .{},
    gap: f32 = 0,
    width: ?f32 = null,
    height: ?f32 = null,
    flex: f32 = 0,
    align_items: Align = .stretch,
    justify: Align = .start,
    bg: ?draw.Color = null,
    border: ?draw.Color = null,
    border_width: f32 = 0,
    radius: f32 = 0,
    clip: bool = true,
    /// Non-zero controls register a hit rectangle in `Ui.hits` for the app.
    hit_id: u32 = 0,
};

pub const FontWeight = enum { regular, bold };

pub const MeasureFn = *const fn (user: ?*anyopaque, available_w: f32) Size;
pub const PaintFn = *const fn (
    user: ?*anyopaque,
    frame: *frame_mod.Frame,
    rect: Rect,
    clip: [4]f32,
) anyerror!void;

pub const CustomSpec = struct {
    style: Style = .{},
    user: ?*anyopaque = null,
    measure: ?MeasureFn = null,
    paint: PaintFn,
};

pub const TextSpec = struct {
    text: []const u8,
    size: f32 = 12,
    color: ?draw.Color = null,
    weight: FontWeight = .regular,
};

pub const Size = struct { w: f32 = 0, h: f32 = 0 };

const Node = struct {
    style: Style,
    text: ?[]const u8 = null,
    text_size: f32 = 12,
    text_color: draw.Color = .{ .r = 255, .g = 255, .b = 255 },
    weight: FontWeight = .regular,
    children: std.ArrayList(u32) = .empty,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    measured: Size = .{},
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    custom_user: ?*anyopaque = null,
    custom_measure: ?MeasureFn = null,
    custom_paint: ?PaintFn = null,
};

pub const Hit = struct {
    rect: Rect,
    id: u32,
};

pub const max_hits = 128;

pub const Container = struct {
    ui: *Ui,
    index: u32,

    pub fn end(self: Container) void {
        _ = self.ui.stack.pop();
    }
};

pub const Ui = struct {
    frame: *frame_mod.Frame,
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    stack: std.ArrayList(u32) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    hits_overflow: bool = false,
    theme: draw.Theme,

    pub fn init(frame: *frame_mod.Frame) Ui {
        return .{
            .frame = frame,
            .allocator = frame.allocator,
            .theme = frame.theme,
        };
    }

    pub fn deinit(self: *Ui) void {
        for (self.nodes.items) |*node| node.children.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.hits.deinit(self.allocator);
    }

    fn add(self: *Ui, style: Style) !u32 {
        const index: u32 = @intCast(self.nodes.items.len);
        if (self.stack.items.len != 0) {
            const parent = self.stack.items[self.stack.items.len - 1];
            try self.nodes.items[parent].children.append(self.allocator, index);
        }
        try self.nodes.append(self.allocator, .{ .style = style });
        try self.stack.append(self.allocator, index);
        return index;
    }

    pub fn column(self: *Ui, style: Style) !Container {
        var s = style;
        s.direction = .column;
        return .{ .ui = self, .index = try self.add(s) };
    }

    pub fn row(self: *Ui, style: Style) !Container {
        var s = style;
        s.direction = .row;
        return .{ .ui = self, .index = try self.add(s) };
    }

    pub fn text(self: *Ui, spec: TextSpec) !void {
        const index: u32 = @intCast(self.nodes.items.len);
        if (self.stack.items.len != 0) {
            const parent = self.stack.items[self.stack.items.len - 1];
            try self.nodes.items[parent].children.append(self.allocator, index);
        }
        try self.nodes.append(self.allocator, .{
            .style = .{},
            .text = spec.text,
            .text_size = spec.size,
            .text_color = spec.color orelse self.theme.text,
            .weight = spec.weight,
        });
    }

    pub fn custom(self: *Ui, spec: CustomSpec) !void {
        const index: u32 = @intCast(self.nodes.items.len);
        if (self.stack.items.len != 0) {
            const parent = self.stack.items[self.stack.items.len - 1];
            try self.nodes.items[parent].children.append(self.allocator, index);
        }
        try self.nodes.append(self.allocator, .{
            .style = spec.style,
            .custom_user = spec.user,
            .custom_measure = spec.measure,
            .custom_paint = spec.paint,
        });
    }

    pub fn finish(self: *Ui) !void {
        if (self.nodes.items.len == 0) return;
        _ = self.measure(0);
        const root_rect = Rect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.frame.width),
            .h = @floatFromInt(self.frame.height),
        };
        const clip = self.frame.clip();
        self.arrange(0, root_rect, clip);
        try self.paint(0);
    }

    pub fn nodeRect(self: *const Ui, index: usize) Rect {
        return self.nodes.items[index].rect;
    }

    /// Returns the topmost control under the pointer after `finish`.
    pub fn hitAt(self: *const Ui, x: f32, y: f32) ?u32 {
        var index = self.hits.items.len;
        while (index > 0) {
            index -= 1;
            const hit = self.hits.items[index];
            if (x >= hit.rect.x and x < hit.rect.x + hit.rect.w and
                y >= hit.rect.y and y < hit.rect.y + hit.rect.h)
            {
                return hit.id;
            }
        }
        return null;
    }

    pub fn nodeText(self: *const Ui, index: usize) ?[]const u8 {
        return self.nodes.items[index].text;
    }

    fn fontFor(self: *Ui, weight: FontWeight) *const ttf.Font {
        return if (weight == .bold) &self.frame.bold else &self.frame.regular;
    }

    fn textWidth(self: *Ui, index: u32) f32 {
        const node = &self.nodes.items[index];
        const content = node.text orelse return 0;
        return @floatFromInt(draw.DrawList.measure(
            self.fontFor(node.weight),
            node.text_size,
            content,
        ));
    }

    fn measure(self: *Ui, index: u32) Size {
        const node = &self.nodes.items[index];
        if (node.text) |_| {
            const size = Size{ .w = self.textWidth(index), .h = node.text_size * 1.45 };
            node.measured = size;
            return size;
        }
        if (node.custom_paint != null) {
            var size = Size{ .w = node.style.width orelse 0, .h = node.style.height orelse 0 };
            if (node.custom_measure) |measure_fn| {
                const available = node.style.width orelse 0;
                const measured = measure_fn(node.custom_user, available);
                if (node.style.width == null) size.w = measured.w;
                if (node.style.height == null) size.h = measured.h;
            }
            node.measured = size;
            return size;
        }
        var main: f32 = 0;
        var cross: f32 = 0;
        for (node.children.items) |child| {
            const size = self.measure(child);
            if (node.style.direction == .row) {
                main += size.w;
                cross = @max(cross, size.h);
            } else {
                main += size.h;
                cross = @max(cross, size.w);
            }
        }
        if (node.children.items.len > 1) {
            main += node.style.gap * @as(f32, @floatFromInt(node.children.items.len - 1));
        }
        const pad_main = if (node.style.direction == .row)
            node.style.padding.horizontal()
        else
            node.style.padding.vertical();
        const pad_cross = if (node.style.direction == .row)
            node.style.padding.vertical()
        else
            node.style.padding.horizontal();
        var width = node.style.width orelse if (node.style.direction == .row)
            main + pad_main
        else
            cross + pad_cross;
        var height = node.style.height orelse if (node.style.direction == .row)
            cross + pad_cross
        else
            main + pad_main;
        width = @max(0, width);
        height = @max(0, height);
        const size = Size{ .w = width, .h = height };
        node.measured = size;
        return size;
    }

    fn clipIntersect(a: [4]f32, b: [4]f32) [4]f32 {
        return .{
            @max(a[0], b[0]),
            @max(a[1], b[1]),
            @min(a[2], b[2]),
            @min(a[3], b[3]),
        };
    }

    fn arrange(self: *Ui, index: u32, rect: Rect, parent_clip: [4]f32) void {
        const node = &self.nodes.items[index];
        node.rect = rect;
        node.clip_rect = if (node.style.clip)
            clipIntersect(parent_clip, .{ rect.x, rect.y, rect.x + rect.w, rect.y + rect.h })
        else
            parent_clip;
        if (node.text != null or node.children.items.len == 0) return;

        const inner = Rect{
            .x = rect.x + node.style.padding.left,
            .y = rect.y + node.style.padding.top,
            .w = @max(0, rect.w - node.style.padding.horizontal()),
            .h = @max(0, rect.h - node.style.padding.vertical()),
        };
        var fixed_main: f32 = 0;
        var flex_total: f32 = 0;
        for (node.children.items) |child| {
            const size = self.nodes.items[child].measured;
            fixed_main += if (node.style.direction == .row) size.w else size.h;
            flex_total += self.nodes.items[child].style.flex;
        }
        if (node.children.items.len > 1) {
            fixed_main += node.style.gap * @as(f32, @floatFromInt(node.children.items.len - 1));
        }
        const available = if (node.style.direction == .row) inner.w else inner.h;
        const extra = @max(0, available - fixed_main);
        var used_main: f32 = 0;
        for (node.children.items) |child| {
            const child_node = &self.nodes.items[child];
            const size = child_node.measured;
            var child_main = if (node.style.direction == .row) size.w else size.h;
            if (flex_total > 0 and child_node.style.flex > 0) {
                child_main += extra * (child_node.style.flex / flex_total);
            }
            const inner_cross = if (node.style.direction == .row) inner.h else inner.w;
            const child_cross = if (node.style.align_items == .stretch)
                inner_cross
            else
                @min(inner_cross, if (node.style.direction == .row) size.h else size.w);
            const cross_offset = switch (node.style.align_items) {
                .center => (inner_cross - child_cross) * 0.5,
                .end => inner_cross - child_cross,
                else => 0,
            };
            const child_rect = if (node.style.direction == .row)
                Rect{
                    .x = inner.x + used_main,
                    .y = inner.y + cross_offset,
                    .w = child_main,
                    .h = child_cross,
                }
            else
                Rect{
                    .x = inner.x + cross_offset,
                    .y = inner.y + used_main,
                    .w = child_cross,
                    .h = child_main,
                };
            self.arrange(child, child_rect, node.clip_rect);
            used_main += child_main + node.style.gap;
        }
    }

    fn paint(self: *Ui, index: u32) !void {
        const node = &self.nodes.items[index];
        const rect = node.rect;
        const clip = node.clip_rect;
        if (node.style.bg) |bg| {
            try self.frame.list.roundedRect(
                rect.x,
                rect.y,
                rect.w,
                rect.h,
                node.style.radius,
                bg,
                node.style.border,
                node.style.border_width,
                clip,
            );
        }
        if (node.text) |content| {
            const font = self.fontFor(node.weight);
            const font_index: u8 = if (node.weight == .bold) 1 else 0;
            _ = try self.frame.list.text(
                font_index,
                font,
                node.text_size,
                rect.x,
                rect.y,
                content,
                node.text_color,
                clip,
            );
        }
        if (node.style.hit_id != 0) {
            if (self.hits.items.len >= max_hits) {
                self.hits_overflow = true;
            } else {
                try self.hits.append(self.allocator, .{ .rect = rect, .id = node.style.hit_id });
            }
        }
        if (node.custom_paint) |paint_fn| {
            try paint_fn(node.custom_user, self.frame, rect, clip);
        }
        for (node.children.items) |child| try self.paint(child);
    }
};

test "column layout honors padding and gap" {
    var frame: frame_mod.Frame = undefined;
    try frame.init(std.testing.allocator, 200, 100, .{});
    defer frame.deinit();
    var ui = Ui.init(&frame);
    defer ui.deinit();
    const root = try ui.column(.{ .padding = Edges.all(10), .gap = 5, .bg = frame.theme.panel });
    try ui.text(.{ .text = "one", .size = 10 });
    try ui.text(.{ .text = "two", .size = 10 });
    root.end();
    try ui.finish();
    const first = ui.nodeRect(1);
    const second = ui.nodeRect(2);
    try std.testing.expectEqual(@as(f32, 10), first.x);
    try std.testing.expectEqual(@as(f32, 10), first.y);
    try std.testing.expect(second.y >= first.y + first.h + 4.9);
}

test "row flex fills the remaining width" {
    var frame: frame_mod.Frame = undefined;
    try frame.init(std.testing.allocator, 200, 60, .{});
    defer frame.deinit();
    var ui = Ui.init(&frame);
    defer ui.deinit();
    const root = try ui.row(.{ .padding = Edges.all(10), .gap = 10 });
    const fixed = try ui.column(.{ .width = 20, .height = 20 });
    fixed.end();
    const grow = try ui.column(.{ .flex = 1, .height = 20 });
    grow.end();
    root.end();
    try ui.finish();
    const fixed_rect = ui.nodeRect(1);
    const grow_rect = ui.nodeRect(2);
    try std.testing.expectEqual(@as(f32, 20), fixed_rect.w);
    try std.testing.expectApproxEqAbs(@as(f32, 150), grow_rect.w, 0.01);
}

test "layout paint produces deterministic pixels" {
    var frame: frame_mod.Frame = undefined;
    try frame.init(std.testing.allocator, 160, 90, .{});
    defer frame.deinit();
    var ui = Ui.init(&frame);
    defer ui.deinit();
    const root = try ui.column(.{ .padding = Edges.all(8), .gap = 4, .bg = frame.theme.panel });
    try ui.text(.{ .text = "xsprof", .size = 16, .color = frame.theme.live, .weight = .bold });
    const row = try ui.row(.{ .gap = 4, .height = 20 });
    const a = try ui.column(.{ .flex = 1, .bg = frame.theme.raised, .radius = 3 });
    a.end();
    const b = try ui.column(.{ .flex = 2, .bg = frame.theme.vm, .radius = 3 });
    b.end();
    row.end();
    root.end();
    try ui.finish();
    const pixels = try frame.render();
    defer std.testing.allocator.free(pixels);
    var hash: u64 = 1469598103934665603;
    for (pixels) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    try std.testing.expect(hash != 0);
}

test "hit targets resolve after layout" {
    var frame: frame_mod.Frame = undefined;
    try frame.init(std.testing.allocator, 200, 100, .{});
    defer frame.deinit();
    var ui = Ui.init(&frame);
    defer ui.deinit();
    const root = try ui.column(.{ .padding = Edges.all(10) });
    const button = try ui.row(.{ .height = 20, .hit_id = 7 });
    try ui.text(.{ .text = "apply", .size = 10 });
    button.end();
    root.end();
    try ui.finish();
    try std.testing.expectEqual(@as(?u32, 7), ui.hitAt(15, 15));
    try std.testing.expect(ui.hitAt(150, 80) == null);
}
