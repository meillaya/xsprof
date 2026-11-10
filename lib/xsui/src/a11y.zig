//! Platform-neutral accessibility tree for xsui.
//!
//! The tree is built from the same `Canvas` semantic registration pass that
//! pointer input and focus use (`Canvas.node`, `Canvas.button`, `Canvas.choice`,
//! `Canvas.textField`, `Canvas.checkbox`, `Canvas.listItem`, `Canvas.tabItem`,
//! `Canvas.semanticText`). Roles, labels, values, state, and focus order are
//! therefore authored at paint time and cannot drift from what was drawn.
//!
//! This module is target-neutral: no OS, window, or profiler imports. Platform
//! bridges (macOS NSAccessibility, Linux JSON/DEGRADED) consume this one tree
//! type and copy whatever they need before the next frame.
//!
//! Canonical JSON (`xsprof/a11y-tree/v1`) is deterministic: keys strictly
//! ascending, compact separators, root `host_mutation=false`, nodes in draw
//! order, labels/values escaped. The wire role vocabulary is the stable
//! viewer-facing one used by snapshots and `ui --a11y`: `button`, `textbox`,
//! `list`, `listitem`, `tab`, `tabpanel`, `tablist`, `dialog`, `status`,
//! `heading`, `window`, `progressbar`-free (no progress nodes are registered).

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const layout = @import("layout.zig");

pub const Rect = layout.Rect;

/// Semantics of an accessible node. `.none` marks a legacy pointer-only hit
/// with no accessibility content (bridges and JSON hide it).
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

/// Stable wire role for `xsprof/a11y-tree/v1`. Returns null for roles that are
/// structural-only and never serialized. The mapping keeps the pre-existing
/// viewer contract (`textbox`/`heading`/`tabpanel`/`listitem`) while the richer
/// internal roles drive NSAccessibility.
pub fn wireRole(role: Role) ?[]const u8 {
    return switch (role) {
        .none, .scroll_area, .graphic => null,
        .window => "window",
        .group => "tabpanel",
        .tab_list => "tablist",
        .tab => "tab",
        .button => "button",
        .toggle, .radio => "button",
        .text_field => "textbox",
        .list => "list",
        .list_item, .row => "listitem",
        .static_text => "heading",
        .status => "status",
        .dialog => "dialog",
    };
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
    /// Tree-owned label/value/hint bytes for `buildOwned`; empty for `build`.
    strings: []u8 = &.{},
    focused: ?u32 = null,
    truncated: bool = false,

    pub fn empty(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator, .nodes = &.{} };
    }

    /// Builds a bounded tree from the canvas registration pass. Returned
    /// labels borrow the canvas strings, so the caller must consume or copy the
    /// tree before those strings die (snapshots, macOS bridge). Use
    /// `buildOwned` when the tree must outlive the frame.
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

    /// `build` plus a tree-owned copy of every label/value/hint, so the tree
    /// remains valid after the canvas is reset (used by the cached App tree
    /// that Linux serializes after the frame and that snapshots may hold).
    pub fn buildOwned(
        allocator: std.mem.Allocator,
        canvas: *const canvas_mod.Canvas,
        focused: ?u32,
    ) !Tree {
        var tree = try build(allocator, canvas, focused);
        errdefer tree.deinit();
        var string_bytes: usize = 0;
        for (tree.nodes) |node| {
            string_bytes += node.label.len + node.value.len + node.hint.len;
        }
        if (string_bytes == 0) return tree;
        const owned = try allocator.alloc(u8, string_bytes);
        errdefer allocator.free(owned);
        var cursor: usize = 0;
        for (tree.nodes) |*node| {
            node.label = copyInto(owned, &cursor, node.label);
            node.value = copyInto(owned, &cursor, node.value);
            node.hint = copyInto(owned, &cursor, node.hint);
        }
        tree.strings = owned;
        return tree;
    }

    pub fn deinit(self: *Tree) void {
        if (self.nodes.len != 0) self.allocator.free(self.nodes);
        if (self.strings.len != 0) self.allocator.free(self.strings);
        self.nodes = &.{};
        self.strings = &.{};
    }

    pub fn count(self: *const Tree) usize {
        return self.nodes.len;
    }

    pub fn focusableCount(self: *const Tree) usize {
        var focusables: usize = 0;
        for (self.nodes) |node| {
            if (!node.flags.focusable or node.flags.disabled) continue;
            focusables += 1;
        }
        return focusables;
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

    /// Writes canonical `xsprof/a11y-tree/v1` JSON to `w`. Node shape is the
    /// stable viewer contract: disabled/focusable/id/label/role/selected/value.
    pub fn writeJson(self: *const Tree, w: *std.Io.Writer) !void {
        try w.writeAll("{\"host_mutation\":false,\"nodes\":[");
        var first = true;
        for (self.nodes) |node| {
            if (node.label.len == 0) continue;
            const role = wireRole(node.role) orelse continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"disabled\":");
            try w.writeAll(if (node.flags.disabled) "true" else "false");
            try w.writeAll(",\"focusable\":");
            try w.writeAll(if (node.flags.focusable) "true" else "false");
            try w.print(",\"id\":{d},\"label\":", .{node.id});
            try writeString(w, node.label);
            try w.writeAll(",\"role\":");
            try writeString(w, role);
            try w.writeAll(",\"selected\":");
            try w.writeAll(if (node.flags.selected or node.flags.checked) "true" else "false");
            try w.writeAll(",\"value\":");
            try writeString(w, node.value);
            try w.writeByte('}');
        }
        try w.writeAll("],\"schema\":\"" ++ schema ++ "\",\"truncated\":");
        try w.writeAll(if (self.truncated) "true" else "false");
        try w.writeByte('}');
    }
};

fn copyInto(buffer: []u8, cursor: *usize, text: []const u8) []const u8 {
    if (text.len == 0) return "";
    const start = cursor.*;
    @memcpy(buffer[start .. start + text.len], text);
    cursor.* = start + text.len;
    return buffer[start .. start + text.len];
}

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

test "tree mirrors canvas semantics with roles, parents, and focus" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 100, 80, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();

    _ = canvas.button(10, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, "Go");
    canvas.pushGroup(.{ .id = 5, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 80 }, .role = .group, .label = "Main" });
    _ = canvas.tabItem(11, .{ .x = 20, .y = 20, .w = 30, .h = 10 }, "Timeline", true);
    canvas.popGroup();
    _ = canvas.textField(12, .{ .x = 0, .y = 60, .w = 40, .h = 10 }, "Filter events", "worker");
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
    try std.testing.expectEqualStrings("worker", tree.find(12).?.value);
    try std.testing.expectEqual(@as(usize, 3), tree.focusableCount());

    const order = try tree.focusOrder(std.testing.allocator);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqualSlices(u32, &.{ 10, 11, 12 }, order);
}

test "buildOwned copies labels so the tree outlives the frame" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 64, 48, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();
    var label_buffer = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    _ = canvas.button(7, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, label_buffer[0..]);
    var tree = try Tree.buildOwned(std.testing.allocator, &canvas, null);
    defer tree.deinit();
    @memset(&label_buffer, 'x');
    try std.testing.expectEqualStrings("hello", tree.find(7).?.label);
}

test "hitTest matches canvas.hitAt and honors clip and disabled" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 100, 80, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();

    canvas.pushClip(.{ .x = 0, .y = 0, .w = 50, .h = 50 });
    _ = canvas.button(22, .{ .x = 10, .y = 60, .w = 20, .h = 10 }, "offscreen");
    canvas.popClip();
    _ = canvas.button(20, .{ .x = 10, .y = 10, .w = 20, .h = 20 }, "on");
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

test "canonical a11y JSON golden keeps the stable node shape" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 100, 80, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();
    _ = canvas.button(10, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, "Go");
    canvas.pushGroup(.{ .id = 5, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 80 }, .role = .group, .label = "Main \"q\"" });
    _ = canvas.tabItem(11, .{ .x = 20, .y = 20, .w = 30, .h = 10 }, "Timeline", true);
    canvas.popGroup();
    var tree = try Tree.build(std.testing.allocator, &canvas, 11);
    defer tree.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try tree.writeJson(&writer);
    const expected =
        "{\"host_mutation\":false,\"nodes\":[" ++
        "{\"disabled\":false,\"focusable\":true,\"id\":10,\"label\":\"Go\",\"role\":\"button\",\"selected\":false,\"value\":\"\"}," ++
        "{\"disabled\":false,\"focusable\":false,\"id\":5,\"label\":\"Main \\\"q\\\"\",\"role\":\"tabpanel\",\"selected\":false,\"value\":\"\"}," ++
        "{\"disabled\":false,\"focusable\":true,\"id\":11,\"label\":\"Timeline\",\"role\":\"tab\",\"selected\":true,\"value\":\"\"}]," ++
        "\"schema\":\"xsprof/a11y-tree/v1\",\"truncated\":false}";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "a11y JSON is deterministic across repeated writes" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 100, 80, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();
    _ = canvas.button(10, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, "Go");
    var tree = try Tree.build(std.testing.allocator, &canvas, 10);
    defer tree.deinit();
    var first: [1024]u8 = undefined;
    var first_writer = std.Io.Writer.fixed(&first);
    try tree.writeJson(&first_writer);
    var second: [1024]u8 = undefined;
    var second_writer = std.Io.Writer.fixed(&second);
    try tree.writeJson(&second_writer);
    try std.testing.expectEqualStrings(first_writer.buffered(), second_writer.buffered());
}

test "tree truncates at the bounded node cap" {
    var frame: @import("frame.zig").Frame = undefined;
    try frame.init(std.testing.allocator, 64, 48, .{});
    defer frame.deinit();
    var canvas = testCanvas(&frame);
    defer canvas.deinit();
    var index: u32 = 0;
    while (index < 600) : (index += 1) {
        _ = canvas.button(1000 + index, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, "bounded");
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
    _ = canvas.button(7, .{ .x = 0, .y = 0, .w = 5, .h = 5 }, "a");
    try std.testing.expectEqual(@as(u32, 100), frame.width);
    frame.resize(200, 150);
    try std.testing.expectEqual(@as(u32, 200), frame.width);
    try std.testing.expectEqual(@as(u32, 150), frame.height);
    canvas.resetViewport();
    try std.testing.expectEqual(@as(f32, 200), canvas.clip_rect.w);
    _ = canvas.button(8, .{ .x = 150, .y = 120, .w = 5, .h = 5 }, "b");
    try std.testing.expectEqual(@as(?u32, 8), canvas.hitAt(151, 121));
    frame.resize(0, 0);
    try std.testing.expectEqual(@as(u32, 200), frame.width);
}
