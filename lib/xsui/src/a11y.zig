//! Platform-neutral accessibility tree for xsui.
//!
//! The tree is built from the same `Canvas` draw/hit pass that pointer input
//! uses, so roles, labels, focus order, and hit testing cannot drift from the
//! drawn UI. This module is target-neutral: no OS, window, or profiler imports.
//! Platform bridges (macOS NSAccessibility, Linux JSON/DEGRADED) copy whatever
//! they need and must not hold borrowed slices past the next frame.
//!
//! Canonical JSON (`xsprof/a11y-tree/v1`) is deterministic: keys strictly
//! ascending, compact separators, rect/clip rounded to whole pixels, labels
//! escaped, nodes in draw order.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const layout = @import("layout.zig");

pub const Rect = layout.Rect;

/// Semantics of an accessible node. `.none` marks a legacy pointer-only hit
/// with no accessibility content (kept during migration; bridges hide it).
pub const Role = enum(u8) {
    none = 0,
    window,
    group,
    tab_list,
    tab,
    button,
    toggle,
    radio,
    text_field,
    list,
    list_item,
    row,
    static_text,
    status,
    dialog,
    scroll_area,
    graphic,
};

pub fn roleName(role: Role) []const u8 {
    return @tagName(role);
}

/// Static state carried by a node. Dynamic focus is resolved by `build`.
pub const Flags = packed struct(u8) {
    interactive: bool = false,
    focusable: bool = false,
    disabled: bool = false,
    selected: bool = false,
    checked: bool = false,
    modal: bool = false,
    live: bool = false,
    expanded: bool = false,
};

pub const max_nodes: usize = 512;
pub const schema = "xsprof/a11y-tree/v1";

pub const Node = struct {
    id: u32,
    role: Role,
    label: []const u8 = "",
    value: []const u8 = "",
    hint: []const u8 = "",
    rect: Rect,
    /// Clip [x0,y0,x1,y1] captured at registration; AX frames and hit tests
    /// obey it so scrolled-away content is not reachable.
    clip: [4]f32 = .{ 0, 0, 0, 0 },
    /// Immediate semantic parent id; 0 means the root.
    parent: u32 = 0,
    flags: Flags = .{},
    focused: bool = false,
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    focused: ?u32 = null,
    truncated: bool = false,

    /// Builds a bounded tree from the canvas hit pass. Returned labels borrow
    /// the caller's strings; the tree itself is owned by `allocator`.
    /// Builds a bounded tree from the canvas hit pass. Legacy pointer-only hits
    /// (`.none` role) and unlabeled nodes are omitted so native AX never exposes
    /// unlabeled controls; the canvas still hit-tests them for pointer input.
    pub fn build(
        allocator: std.mem.Allocator,
        canvas: *const canvas_mod.Canvas,
        focused: ?u32,
    ) !Tree {
        var list: std.ArrayList(Node) = .empty;
        errdefer list.deinit(allocator);
        var truncated = canvas.truncated;
        for (canvas.hits.items) |hit| {
            if (hit.role == .none) continue;
            if (hit.label.len == 0) continue;
            if (list.items.len >= max_nodes) {
                truncated = true;
                break;
            }
            try list.append(allocator, .{
                .id = hit.id,
                .role = hit.role,
                .label = hit.label,
                .value = hit.value,
                .hint = hit.hint,
                .rect = hit.rect,
                .clip = hit.clip,
                .parent = if (findHitIndex(canvas.hits.items, hit.parent)) |_| hit.parent else 0,
                .flags = hit.flags,
                .focused = focused != null and hit.id == focused.?,
            });
        }
        return .{
            .allocator = allocator,
            .nodes = try list.toOwnedSlice(allocator),
            .focused = focused,
            .truncated = truncated,
        };
    }

    pub fn deinit(self: *Tree) void {
        self.allocator.free(self.nodes);
        self.nodes = &.{};
    }

    pub fn count(self: *const Tree) usize {
        return self.nodes.len;
    }

    pub fn findIndex(self: *const Tree, id: u32) ?usize {
        return findNodeIndex(self.nodes, id);
    }

    pub fn find(self: *const Tree, id: u32) ?*const Node {
        const index = self.findIndex(id) orelse return null;
        return &self.nodes[index];
    }

    /// Keyboard/AX focus order: draw order filtered to enabled focusables, the
    /// same order `focus.step` traverses.
    pub fn focusOrder(self: *const Tree, allocator: std.mem.Allocator) ![]u32 {
        var order: std.ArrayList(u32) = .empty;
        errdefer order.deinit(allocator);
        for (self.nodes) |node| {
            if (!node.flags.focusable or node.flags.disabled) continue;
            try order.append(allocator, node.id);
        }
        return order.toOwnedSlice(allocator);
    }

    /// Inverse of the pointer hit pass: last drawn wins, clipped/disabled/
    /// structural nodes are skipped. Invariant: equals `Canvas.hitAt`.
    pub fn hitTest(self: *const Tree, x: f32, y: f32) ?u32 {
        var index = self.nodes.len;
        while (index > 0) {
            index -= 1;
            const node = self.nodes[index];
            if (!node.flags.interactive or node.flags.disabled) continue;
            if (x < node.rect.x or y < node.rect.y) continue;
            if (x >= node.rect.x + node.rect.w or y >= node.rect.y + node.rect.h) continue;
            if (x < node.clip[0] or y < node.clip[1]) continue;
            if (x > node.clip[2] or y > node.clip[3]) continue;
            return node.id;
        }
        return null;
    }

    /// Writes canonical `xsprof/a11y-tree/v1` JSON to `w`.
    pub fn writeJson(self: *const Tree, w: *std.Io.Writer) !void {
        try w.writeAll("{\"focused\":");
        if (self.focused) |id| try w.print("{d}", .{id}) else try w.writeAll("null");
        try w.writeAll(",\"nodes\":[");
        for (self.nodes, 0..) |node, index| {
            if (index != 0) try w.writeByte(',');
            try writeNode(w, self, node);
        }
        try w.writeAll("],\"schema\":\"" ++ schema ++ "\",\"truncated\":");
        try w.writeAll(if (self.truncated) "true" else "false");
        try w.writeByte('}');
    }
};

fn findNodeIndex(nodes: []const Node, id: u32) ?usize {
    if (id == 0) return null;
    for (nodes, 0..) |node, index| {
        if (node.id == id) return index;
    }
    return null;
}

fn findHitIndex(hits: []const canvas_mod.Hit, id: u32) ?usize {
    if (id == 0) return null;
    for (hits, 0..) |hit, index| {
        if (hit.id == id) return index;
    }
    return null;
}

fn writeNode(w: *std.Io.Writer, tree: *const Tree, node: Node) !void {
    try w.writeAll("{\"children\":[");
    var first = true;
    for (tree.nodes) |child| {
        if (child.parent != node.id or child.id == node.id) continue;
        if (!first) try w.writeByte(',');
        try w.print("{d}", .{child.id});
        first = false;
    }
    try w.writeAll("],\"clip\":[");
    try writeRect(w, node.clip);
    try w.writeAll("],\"flags\":[");
    try writeFlags(w, node.flags);
    try w.writeAll("],\"focused\":");
    try w.writeAll(if (node.focused) "true" else "false");
    try w.writeAll(",\"hint\":");
    try writeString(w, node.hint);
    try w.print(",\"id\":{d},\"label\":", .{node.id});
    try writeString(w, node.label);
    try w.print(",\"parent\":{d},\"rect\":[", .{node.parent});
    try writeRect(w, .{ node.rect.x, node.rect.y, node.rect.w, node.rect.h });
    try w.writeAll("],\"role\":");
    try writeString(w, roleName(node.role));
    try w.writeAll(",\"value\":");
    try writeString(w, node.value);
    try w.writeByte('}');
}

fn writeRect(w: *std.Io.Writer, values: [4]f32) !void {
    for (values, 0..) |value, index| {
        if (index != 0) try w.writeByte(',');
        const rounded: i64 = @intFromFloat(@round(value));
        try w.print("{d}", .{rounded});
    }
}

fn writeFlags(w: *std.Io.Writer, flags: Flags) !void {
    var first = true;
    const flag_order = [_][]const u8{
        "interactive", "focusable", "disabled", "selected",
        "checked",     "modal",     "live",     "expanded",
    };
    inline for (flag_order) |name| {
        if (@field(flags, name)) {
            if (!first) try w.writeByte(',');
            try writeString(w, name);
            first = false;
        }
    }
}

fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    const hex = "0123456789abcdef";
    try w.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try w.writeAll("\\u00");
                    try w.writeByte(hex[byte >> 4]);
                    try w.writeByte(hex[byte & 0x0f]);
                } else {
                    try w.writeByte(byte);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn testCanvas(frame: *@import("frame.zig").Frame) canvas_mod.Canvas {
    return canvas_mod.Canvas.init(frame);
}

test "tree mirrors hits with roles, parents, focus order, and focus" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 100, 80, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();

    _ = canvas.node(.{ .id = 10, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .role = .button, .label = "Go" });
    canvas.pushGroup(.{ .id = 5, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 80 }, .role = .group, .label = "Main" });
    _ = canvas.node(.{
        .id = 11,
        .rect = .{ .x = 20, .y = 20, .w = 30, .h = 10 },
        .role = .tab,
        .label = "Timeline",
        .value = "selected",
        .flags = .{ .interactive = true, .focusable = true, .selected = true },
    });
    canvas.popGroup();
    _ = canvas.node(.{
        .id = 12,
        .rect = .{ .x = 0, .y = 60, .w = 10, .h = 10 },
        .role = .static_text,
        .label = "caption",
        .flags = .{},
    });
    _ = canvas.node(.{
        .id = 13,
        .rect = .{ .x = 40, .y = 0, .w = 10, .h = 10 },
        .role = .button,
        .label = "disabled",
        .flags = .{ .interactive = true, .focusable = true, .disabled = true },
    });

    var tree = try Tree.build(std.testing.allocator, &canvas, 11);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 5), tree.count());
    const go = tree.find(10).?;
    try std.testing.expectEqual(Role.button, go.role);
    try std.testing.expectEqual(@as(u32, 0), go.parent);
    const group = tree.find(5).?;
    try std.testing.expectEqual(Role.group, group.role);
    const tab = tree.find(11).?;
    try std.testing.expectEqual(@as(u32, 5), tab.parent);
    try std.testing.expect(tab.focused);
    try std.testing.expect(!go.focused);
    try std.testing.expectEqual(Role.static_text, tree.find(12).?.role);

    const order = try tree.focusOrder(std.testing.allocator);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqualSlices(u32, &.{ 10, 11 }, order);
}

test "hitTest matches canvas.hitAt and honors clip and disabled" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 100, 80, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();

    canvas.pushClip(.{ .x = 0, .y = 0, .w = 50, .h = 50 });
    _ = canvas.node(.{ .id = 22, .rect = .{ .x = 10, .y = 60, .w = 20, .h = 10 }, .role = .button, .label = "offscreen" });
    canvas.popClip();
    _ = canvas.node(.{ .id = 20, .rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 }, .role = .button, .label = "on" });
    _ = canvas.node(.{
        .id = 21,
        .rect = .{ .x = 40, .y = 10, .w = 20, .h = 20 },
        .role = .button,
        .label = "off",
        .flags = .{ .interactive = true, .focusable = true, .disabled = true },
    });
    var tree = try Tree.build(std.testing.allocator, &canvas, null);
    defer tree.deinit();

    var y: f32 = 0;
    while (y <= 80) : (y += 10) {
        var x: f32 = 0;
        while (x <= 100) : (x += 10) {
            try std.testing.expectEqual(canvas.hitAt(x, y), tree.hitTest(x, y));
        }
    }
    try std.testing.expectEqual(@as(?u32, 20), tree.hitTest(15, 15));
    try std.testing.expectEqual(@as(?u32, null), tree.hitTest(15, 65));
    try std.testing.expectEqual(@as(?u32, null), tree.hitTest(45, 15));
}

test "canonical a11y JSON golden" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 100, 80, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();
    _ = canvas.node(.{ .id = 10, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .role = .button, .label = "Go" });
    canvas.pushGroup(.{ .id = 5, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 80 }, .role = .group, .label = "Main \"q\"" });
    _ = canvas.node(.{
        .id = 11,
        .rect = .{ .x = 20, .y = 20, .w = 30, .h = 10 },
        .role = .tab,
        .label = "Timeline",
        .value = "selected",
        .flags = .{ .interactive = true, .focusable = true, .selected = true },
    });
    canvas.popGroup();
    var tree = try Tree.build(std.testing.allocator, &canvas, 11);
    defer tree.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try tree.writeJson(&writer);
    const expected =
        "{\"focused\":11,\"nodes\":[" ++
        "{\"children\":[],\"clip\":[0,0,100,80],\"flags\":[\"interactive\",\"focusable\"],\"focused\":false," ++
        "\"hint\":\"\",\"id\":10,\"label\":\"Go\",\"parent\":0,\"rect\":[0,0,10,10],\"role\":\"button\",\"value\":\"\"}," ++
        "{\"children\":[11],\"clip\":[0,0,100,80],\"flags\":[],\"focused\":false," ++
        "\"hint\":\"\",\"id\":5,\"label\":\"Main \\\"q\\\"\",\"parent\":0,\"rect\":[0,0,100,80],\"role\":\"group\",\"value\":\"\"}," ++
        "{\"children\":[],\"clip\":[0,0,100,80],\"flags\":[\"interactive\",\"focusable\",\"selected\"],\"focused\":true," ++
        "\"hint\":\"\",\"id\":11,\"label\":\"Timeline\",\"parent\":5,\"rect\":[20,20,30,10],\"role\":\"tab\",\"value\":\"selected\"}]," ++
        "\"schema\":\"xsprof/a11y-tree/v1\",\"truncated\":false}";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "tree truncates at the bounded node cap" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 64, 48, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();
    var index: u32 = 0;
    while (index < 600) : (index += 1) {
        _ = canvas.node(.{
            .id = 1000 + index,
            .rect = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
            .role = .button,
            .label = "bounded",
        });
    }
    try std.testing.expect(canvas.truncated);
    var tree = try Tree.build(std.testing.allocator, &canvas, null);
    defer tree.deinit();
    try std.testing.expectEqual(max_nodes, tree.count());
    try std.testing.expect(tree.truncated);
}

test "frame resize and canvas resetViewport track new dimensions" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 100, 80, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();
    _ = canvas.node(.{ .id = 7, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 5 }, .role = .button, .label = "a" });
    try std.testing.expectEqual(@as(u32, 100), frame.width);
    frame.resize(200, 150);
    try std.testing.expectEqual(@as(u32, 200), frame.width);
    try std.testing.expectEqual(@as(u32, 150), frame.height);
    canvas.resetViewport();
    try std.testing.expectEqual(@as(f32, 200), canvas.clip_rect.w);
    _ = canvas.node(.{ .id = 8, .rect = .{ .x = 150, .y = 120, .w = 5, .h = 5 }, .role = .button, .label = "b" });
    try std.testing.expectEqual(@as(?u32, 8), canvas.hitAt(151, 121));
    frame.resize(0, 0);
    try std.testing.expectEqual(@as(u32, 200), frame.width);
}
