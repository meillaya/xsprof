//! Renderer extension contract. A backend renders one `DrawList` (which owns
//! its glyph atlas pointer) into a target and reports an explicit capability.
//! The CPU rasterizer is the reference; Metal and GL implement this contract
//! through `interface()` adapters. Third-party backends can do the same.
//!
//! Capability states follow the xsprof gate vocabulary: READY, DEGRADED, SKIP,
//! REFUSE, always with a human-readable reason. A missing device is SKIP, never
//! a fabricated success.

const std = @import("std");
const draw = @import("../draw.zig");

pub const Backend = enum(u8) { cpu = 0, metal = 1, gl = 2 };

pub const Status = enum(u8) { ready = 0, degraded = 1, skip = 2, refuse = 3 };

pub const Capability = struct {
    backend: Backend,
    status: Status,
    reason: []const u8,
};

pub const Target = struct {
    width: u32,
    height: u32,
};

pub const Renderer = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        backend: Backend,
        deinit: *const fn (context: *anyopaque) void,
        resize: *const fn (context: *anyopaque, target: Target) void,
        /// Draws the list. Returns false when a window drawable is not
        /// available yet (the host retries on the next tick).
        draw: *const fn (
            context: *anyopaque,
            list: *const draw.DrawList,
            target: Target,
            background: draw.Color,
        ) anyerror!bool,
        /// Optional offscreen readback. Pixels are backend-native: Metal and
        /// the CPU reference return BGRA8; callers own and free the slice.
        readback: ?*const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            list: *const draw.DrawList,
            target: Target,
            background: draw.Color,
        ) anyerror![]u8 = null,
    };

    pub fn backend(self: Renderer) Backend {
        return self.vtable.backend;
    }

    pub fn deinit(self: Renderer) void {
        self.vtable.deinit(self.context);
    }

    pub fn resize(self: Renderer, target: Target) void {
        self.vtable.resize(self.context, target);
    }

    pub fn drawFrame(
        self: Renderer,
        list: *const draw.DrawList,
        target: Target,
        background: draw.Color,
    ) !bool {
        return self.vtable.draw(self.context, list, target, background);
    }

    pub fn supportsReadback(self: Renderer) bool {
        return self.vtable.readback != null;
    }

    pub fn readPixels(
        self: Renderer,
        allocator: std.mem.Allocator,
        list: *const draw.DrawList,
        target: Target,
        background: draw.Color,
    ) ![]u8 {
        const readback = self.vtable.readback orelse return error.ReadbackUnsupported;
        return readback(self.context, allocator, list, target, background);
    }
};

const Fake = struct {
    deinit_calls: u32 = 0,
    resize_calls: u32 = 0,
    draw_calls: u32 = 0,
    last: Target = .{ .width = 0, .height = 0 },
};

fn fakeDeinit(context: *anyopaque) void {
    const self: *Fake = @ptrCast(@alignCast(context));
    self.deinit_calls += 1;
}

fn fakeResize(context: *anyopaque, target: Target) void {
    const self: *Fake = @ptrCast(@alignCast(context));
    self.resize_calls += 1;
    self.last = target;
}

fn fakeDraw(
    context: *anyopaque,
    list: *const draw.DrawList,
    target: Target,
    background: draw.Color,
) !bool {
    _ = background;
    const self: *Fake = @ptrCast(@alignCast(context));
    self.draw_calls += 1;
    self.last = target;
    return list.items.items.len != 0;
}

fn fakeReadback(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    list: *const draw.DrawList,
    target: Target,
    background: draw.Color,
) ![]u8 {
    _ = background;
    const self: *Fake = @ptrCast(@alignCast(context));
    self.last = target;
    const bytes = try allocator.alloc(u8, 4);
    @memset(bytes, @intCast(list.items.items.len));
    return bytes;
}

test "custom backend dispatches through the renderer interface" {
    var atlas = try draw.Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var list = draw.DrawList.init(std.testing.allocator, &atlas);
    defer list.deinit();
    try list.rect(0, 0, 2, 2, .{ .r = 255, .g = 0, .b = 0 }, .{ 0, 0, 4, 4 });

    var fake = Fake{};
    const renderer: Renderer = .{
        .context = &fake,
        .vtable = &.{
            .backend = .cpu,
            .deinit = fakeDeinit,
            .resize = fakeResize,
            .draw = fakeDraw,
            .readback = fakeReadback,
        },
    };
    try std.testing.expectEqual(Backend.cpu, renderer.backend());
    try std.testing.expect(renderer.supportsReadback());
    renderer.resize(.{ .width = 64, .height = 32 });
    try std.testing.expect(try renderer.drawFrame(&list, .{ .width = 64, .height = 32 }, .{ .r = 0, .g = 0, .b = 0 }));
    const pixels = try renderer.readPixels(std.testing.allocator, &list, .{ .width = 64, .height = 32 }, .{ .r = 0, .g = 0, .b = 0 });
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(u8, 1), pixels[0]);
    renderer.deinit();
    try std.testing.expectEqual(@as(u32, 1), fake.deinit_calls);
    try std.testing.expectEqual(@as(u32, 1), fake.resize_calls);
    try std.testing.expectEqual(@as(u32, 1), fake.draw_calls);
}

test "readback is optional" {
    var atlas = try draw.Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var list = draw.DrawList.init(std.testing.allocator, &atlas);
    defer list.deinit();
    var fake = Fake{};
    const renderer: Renderer = .{
        .context = &fake,
        .vtable = &.{
            .backend = .gl,
            .deinit = fakeDeinit,
            .resize = fakeResize,
            .draw = fakeDraw,
        },
    };
    try std.testing.expect(!renderer.supportsReadback());
    try std.testing.expectError(error.ReadbackUnsupported, renderer.readPixels(
        std.testing.allocator,
        &list,
        .{ .width = 1, .height = 1 },
        .{ .r = 0, .g = 0, .b = 0 },
    ));
}
