//! WebAssembly entrypoint for the read-only web frontend.
//! JS owns WebGL2; Zig owns the UI tree, draw list, and glyph atlas.

const std = @import("std");
const draw = @import("ui/draw.zig");
const frame_mod = @import("ui/frame.zig");
const layout = @import("ui/layout.zig");
const app = @import("app/app.zig");
const gallery = @import("app/gallery.zig");
const session_mod = @import("stream/session.zig");
const ttf = @import("ui/ttf.zig");

const gpa = std.heap.wasm_allocator;

var arena: std.heap.ArenaAllocator = undefined;
var arena_ready = false;
var frame_ptr: ?*frame_mod.Frame = null;
var loaded: ?session_mod.Session = null;
var screen: app.Screen = .overview;
var theme: draw.Theme = .{};
var width: u32 = 1280;
var height: u32 = 720;

fn ensureArena() void {
    if (!arena_ready) {
        arena = std.heap.ArenaAllocator.init(gpa);
        arena_ready = true;
    }
}

fn destroyFrame() void {
    if (frame_ptr) |frame| {
        frame.deinit();
        gpa.destroy(frame);
        frame_ptr = null;
    }
}

fn createFrame() void {
    destroyFrame();
    const frame = gpa.create(frame_mod.Frame) catch return;
    frame.init(gpa, width, height, theme) catch {
        gpa.destroy(frame);
        return;
    };
    frame_ptr = frame;
}

export fn web_init(w: u32, h: u32) u32 {
    ensureArena();
    width = w;
    height = h;
    createFrame();
    return if (frame_ptr == null) 0 else 1;
}

export fn web_resize(w: u32, h: u32) void {
    width = w;
    height = h;
    if (frame_ptr) |frame| {
        frame.width = w;
        frame.height = h;
    }
}

export fn web_alloc(len: usize) usize {
    const bytes = gpa.alloc(u8, len) catch return 0;
    return @intFromPtr(bytes.ptr);
}

export fn web_free(addr: usize, len: usize) void {
    if (addr == 0) return;
    const ptr: [*]u8 = @ptrFromInt(addr);
    gpa.free(ptr[0..len]);
}

export fn web_load_journal(addr: usize, len: usize) u32 {
    if (addr == 0 or len == 0) return 0;
    ensureArena();
    const input: [*]const u8 = @ptrFromInt(addr);
    const allocator = arena.allocator();
    const copied = allocator.dupe(u8, input[0..len]) catch return 0;
    const session = session_mod.Session.fromData(allocator, "web replay", copied) catch return 0;
    loaded = session;
    screen = .overview;
    return 1;
}

export fn web_set_screen(id: u32) void {
    screen = switch (id) {
        0 => .overview,
        1 => .timeline,
        2 => .advisor,
        3 => .events,
        4 => .capture,
        else => .overview,
    };
}

export fn web_set_theme(light: u32) void {
    theme = if (light != 0) .{
        .bg = .{ .r = 0xf3, .g = 0xea, .b = 0xd7 },
        .panel = .{ .r = 0xff, .g = 0xf8, .b = 0xeb },
        .raised = .{ .r = 0xe9, .g = 0xdf, .b = 0xcb },
        .text = .{ .r = 0x1a, .g = 0x17, .b = 0x12 },
        .muted = .{ .r = 0x6b, .g = 0x5f, .b = 0x51 },
        .hairline = .{ .r = 0xc9, .g = 0xba, .b = 0xa2 },
    } else .{};
    if (frame_ptr) |frame| frame.theme = theme;
}

export fn web_frame() u32 {
    const frame = frame_ptr orelse return 0;
    frame.list.clear();
    var ui = layout.Ui.init(frame);
    defer ui.deinit();
    if (loaded) |*session| {
        var state = app.State{ .session = session, .screen = screen };
        app.view(&state, &ui) catch return 0;
    } else {
        gallery.build(&ui) catch return 0;
    }
    ui.finish() catch return 0;
    return @intCast(frame.list.items.items.len);
}

export fn web_instances_ptr() usize {
    const frame = frame_ptr orelse return 0;
    return @intFromPtr(frame.list.items.items.ptr);
}

export fn web_instance_stride() u32 {
    return @intCast(@sizeOf(draw.Instance) / @sizeOf(f32));
}

export fn web_atlas_ptr() usize {
    const frame = frame_ptr orelse return 0;
    return @intFromPtr(frame.atlas.pixels.ptr);
}

export fn web_atlas_size() u32 {
    const frame = frame_ptr orelse return 0;
    return @intCast(frame.atlas.width);
}

export fn web_refusals() u32 {
    return if (loaded) |session| session.refusals else 0;
}

export fn web_capabilities() u32 {
    return if (loaded) |session| @intCast(session.capabilities.len) else 0;
}

export fn web_width() u32 {
    return width;
}

export fn web_height() u32 {
    return height;
}
