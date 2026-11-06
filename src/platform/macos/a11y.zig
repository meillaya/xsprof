//! macOS NSAccessibility bridge for the platform-neutral xsui a11y tree.
//!
//! The view exposes itself as an AX group; one dynamically defined
//! `XsprofAXNode` (subclass of `NSAccessibilityElement`) mirrors each node in
//! the bounded tree. No C shims: classes, selectors, and objects come from the
//! Objective-C runtime (see `lib/xsui/src/native/objc.zig`).
//!
//! Failure is explicit: a missing `NSAccessibilityElement` class returns
//! `error.NoAccessibilityElement` and the surface reports DEGRADED instead of
//! pretending the tree is exposed.

const std = @import("std");
const xsui = @import("xsui");
const objc = @import("xsui-objc");

pub const max_nodes = xsui.a11y.max_nodes;
const max_label = 96;
const max_value = 64;

extern "c" fn NSAccessibilityPostNotification(element: objc.Object, notification: objc.Object) void;

/// Per-proxy payload stored in the proxy's single Zig ivar.
const Handle = struct {
    bridge: *Bridge,
    id: u32,
};

const Entry = struct {
    id: u32 = 0,
    role: xsui.Role = .none,
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip: [4]f32 = .{ 0, 0, 0, 0 },
    flags: xsui.NodeFlags = .{},
    focused: bool = false,
    label: [max_label]u8 = @splat(0),
    label_len: u8 = 0,
    value: [max_value]u8 = @splat(0),
    value_len: u8 = 0,
    proxy: ?objc.Object = null,
    handle: ?*Handle = null,
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    view: objc.Object,
    window: objc.Object,
    proxy_class: objc.Class,
    entries: [max_nodes]Entry = @splat(.{}),
    entry_count: usize = 0,
    focused: ?u32 = null,
    on_press: ?*const fn (ctx: ?*anyopaque, id: u32) void = null,
    press_ctx: ?*anyopaque = null,
    last_count: usize = 0,
    last_focused: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, view: objc.Object, window: objc.Object) !Bridge {
        if (objc.findClass("NSAccessibilityElement") == null) return error.NoAccessibilityElement;
        const proxy_class = objc.defineClass(.{
            .name = "XsprofAXNode",
            .superclass = "NSAccessibilityElement",
            .methods = &proxy_methods,
        });
        return .{
            .allocator = allocator,
            .view = view,
            .window = window,
            .proxy_class = proxy_class,
        };
    }

    pub fn deinit(self: *Bridge) void {
        for (self.entries[0..self.entry_count]) |entry| {
            if (entry.proxy) |proxy| objc.release(proxy);
            if (entry.handle) |handle| self.allocator.destroy(handle);
        }
        self.entry_count = 0;
    }

    pub fn setPressHandler(
        self: *Bridge,
        ctx: ?*anyopaque,
        handler: *const fn (ctx: ?*anyopaque, id: u32) void,
    ) void {
        self.press_ctx = ctx;
        self.on_press = handler;
    }

    /// Copies the tree into bridge-owned storage. Labels are bounded copies, so
    /// a live arena swap after this call cannot dangle a proxy.
    pub fn update(self: *Bridge, tree: *const xsui.A11yTree) void {
        var seen: [max_nodes]bool = @splat(false);
        for (tree.nodes) |node| {
            if (node.role == .none or node.label.len == 0) continue;
            var slot: ?usize = null;
            for (self.entries[0..self.entry_count], 0..) |entry, index| {
                if (entry.id == node.id) {
                    slot = index;
                    break;
                }
            }
            if (slot == null) {
                if (self.entry_count >= max_nodes) continue;
                slot = self.entry_count;
                self.entry_count += 1;
            }
            const slot_index = slot.?;
            seen[slot_index] = true;
            const entry = &self.entries[slot_index];
            if (entry.proxy == null) {
                const handle = self.allocator.create(Handle) catch continue;
                handle.* = .{ .bridge = self, .id = node.id };
                const proxy = objc.msg(objc.Object, objc.msg(objc.Object, self.proxy_class, "alloc", .{}), "init", .{});
                objc.setZig(proxy, handle);
                entry.handle = handle;
                entry.proxy = proxy;
            }
            entry.id = node.id;
            entry.role = node.role;
            entry.rect = .{ node.rect.x, node.rect.y, node.rect.w, node.rect.h };
            entry.clip = node.clip;
            entry.flags = node.flags;
            entry.focused = node.focused;
            const label_len: usize = @min(node.label.len, max_label);
            @memcpy(entry.label[0..label_len], node.label[0..label_len]);
            entry.label_len = @intCast(label_len);
            const value_len: usize = @min(node.value.len, max_value);
            @memcpy(entry.value[0..value_len], node.value[0..value_len]);
            entry.value_len = @intCast(value_len);
        }
        // Drop entries whose node disappeared, then compact in draw order.
        var write: usize = 0;
        var read: usize = 0;
        while (read < self.entry_count) : (read += 1) {
            const entry = &self.entries[read];
            if (read >= max_nodes) break;
            if (!seen[read]) {
                if (entry.proxy) |proxy| objc.release(proxy);
                if (entry.handle) |handle| self.allocator.destroy(handle);
                entry.* = .{};
                continue;
            }
            if (write != read) self.entries[write] = entry.*;
            write += 1;
        }
        self.entry_count = write;
        self.focused = tree.focused;
        if (write != self.last_count or tree.focused != self.last_focused) {
            const name = if (tree.focused != self.last_focused) "AXFocusedUIElementChanged" else "AXLayoutChanged";
            self.postNotification(name);
        }
        self.last_count = write;
        self.last_focused = tree.focused;
    }

    pub fn count(self: *const Bridge) usize {
        return self.entry_count;
    }

    /// Fills `buffer` with live proxies and returns the count.
    pub fn fillChildren(self: *const Bridge, buffer: []objc.Object) usize {
        var index: usize = 0;
        for (self.entries[0..self.entry_count]) |entry| {
            const proxy = entry.proxy orelse continue;
            if (index >= buffer.len) break;
            buffer[index] = proxy;
            index += 1;
        }
        return index;
    }

    pub fn childrenArray(self: *const Bridge, buffer: []objc.Object) objc.Object {
        const child_count = self.fillChildren(buffer);
        return objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObjects:count:", .{
            @as([*]const objc.Object, @ptrCast(buffer.ptr)),
            @as(objc.NSUInteger, child_count),
        });
    }

    pub fn focusedProxy(self: *const Bridge) ?objc.Object {
        const id = self.focused orelse return null;
        for (self.entries[0..self.entry_count]) |entry| {
            if (entry.id == id) return entry.proxy;
        }
        return null;
    }

    /// Point is in view coordinates (the window wrapper converts from screen).
    pub fn proxyAt(self: *const Bridge, x: f32, y: f32) ?objc.Object {
        var index = self.entry_count;
        while (index > 0) {
            index -= 1;
            const entry = self.entries[index];
            if (entry.flags.disabled) continue;
            if (x < entry.rect[0] or y < entry.rect[1]) continue;
            if (x >= entry.rect[0] + entry.rect[2] or y >= entry.rect[1] + entry.rect[3]) continue;
            if (x < entry.clip[0] or y < entry.clip[1]) continue;
            if (x > entry.clip[2] or y > entry.clip[3]) continue;
            return entry.proxy;
        }
        return null;
    }

    pub fn findEntry(self: *const Bridge, id: u32) ?*const Entry {
        for (self.entries[0..self.entry_count]) |*entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    fn press(self: *Bridge, id: u32) void {
        const handler = self.on_press orelse return;
        handler(self.press_ctx, id);
    }

    fn postNotification(self: *Bridge, name: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        NSAccessibilityPostNotification(self.view, objc.nsString(name));
    }

    fn visibleRect(entry: *const Entry) [4]f32 {
        const x0 = @max(entry.rect[0], entry.clip[0]);
        const y0 = @max(entry.rect[1], entry.clip[1]);
        const x1 = @min(entry.rect[0] + entry.rect[2], entry.clip[2]);
        const y1 = @min(entry.rect[1] + entry.rect[3], entry.clip[3]);
        return .{ x0, y0, @max(0, x1 - x0), @max(0, y1 - y0) };
    }

    /// Converts a view-space rect (flipped, y down) to AX screen coordinates.
    fn screenRect(self: *const Bridge, rect: [4]f32) objc.CGRect {
        const pool = objc.Pool.push();
        defer pool.pop();
        const cg = objc.CGRect{
            .origin = .{ .x = rect[0], .y = rect[1] },
            .size = .{ .width = rect[2], .height = rect[3] },
        };
        const in_window = objc.msg(objc.CGRect, self.view, "convertRect:toView:", .{
            cg,
            @as(?objc.Object, null),
        });
        return objc.msg(objc.CGRect, self.window, "convertRectToScreen:", .{in_window});
    }
};

fn axRole(role: xsui.Role) []const u8 {
    return switch (role) {
        .none, .group, .window, .dialog, .scroll_area, .graphic => "AXGroup",
        .button, .toggle => "AXButton",
        .radio, .tab => "AXRadioButton",
        .tab_list => "AXTabGroup",
        .text_field => "AXTextField",
        .list => "AXList",
        .list_item, .row => "AXRow",
        .status => "AXStaticText",
        .static_text => "AXStaticText",
    };
}

fn entryOf(target: objc.Object) ?*const Entry {
    const handle = objc.getZig(Handle, target) orelse return null;
    return handle.bridge.findEntry(handle.id);
}

const proxy_methods = [_]objc.Method{
    .{ .name = "isAccessibilityElement", .imp = &proxyIsElement, .types = "c@:" },
    .{ .name = "accessibilityRole", .imp = &proxyRole, .types = "@@:" },
    .{ .name = "accessibilityRoleDescription", .imp = &proxyRoleDescription, .types = "@@:" },
    .{ .name = "accessibilityLabel", .imp = &proxyLabel, .types = "@@:" },
    .{ .name = "accessibilityValue", .imp = &proxyValue, .types = "@@:" },
    .{ .name = "accessibilityIdentifier", .imp = &proxyIdentifier, .types = "@@:" },
    .{ .name = "accessibilityFrame", .imp = &proxyFrame, .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:" },
    .{ .name = "accessibilityParent", .imp = &proxyParent, .types = "@@:" },
    .{ .name = "accessibilityFocused", .imp = &proxyFocused, .types = "c@:" },
    .{ .name = "accessibilityPerformPress", .imp = &proxyPerformPress, .types = "v@:" },
};

fn proxyIsElement(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn proxyRole(target: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const entry = entryOf(target) orelse return objc.nsString("AXGroup");
    return objc.nsString(axRole(entry.role));
}

fn proxyRoleDescription(target: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const entry = entryOf(target) orelse return objc.nsString("group");
    return objc.nsString(@tagName(entry.role));
}

fn proxyLabel(target: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const entry = entryOf(target) orelse return objc.nsString("");
    return objc.nsString(entry.label[0..entry.label_len]);
}

fn proxyValue(target: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const entry = entryOf(target) orelse return objc.nsString("");
    return objc.nsString(entry.value[0..entry.value_len]);
}

fn proxyIdentifier(target: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const entry = entryOf(target) orelse return objc.nsString("");
    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{entry.id}) catch "";
    return objc.nsString(text);
}

fn proxyFrame(target: objc.Object, _: objc.SEL) callconv(.c) objc.CGRect {
    const handle = objc.getZig(Handle, target) orelse return .{};
    const entry = handle.bridge.findEntry(handle.id) orelse return .{};
    return handle.bridge.screenRect(Bridge.visibleRect(entry));
}

fn proxyParent(target: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const handle = objc.getZig(Handle, target) orelse return objc.msg(objc.Object, objc.class("NSView"), "new", .{});
    return handle.bridge.view;
}

fn proxyFocused(target: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const entry = entryOf(target) orelse return objc.NO;
    return if (entry.focused) objc.YES else objc.NO;
}

fn proxyPerformPress(target: objc.Object, _: objc.SEL) callconv(.c) void {
    const handle = objc.getZig(Handle, target) orelse return;
    handle.bridge.press(handle.id);
}
