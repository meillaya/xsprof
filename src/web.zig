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
var session_arena: std.heap.ArenaAllocator = undefined;
var session_ready = false;
var journal_buf: std.ArrayList(u8) = .empty;
var live_mode = false;
var frame_ptr: ?*frame_mod.Frame = null;
var loaded: ?session_mod.Session = null;
var view_state: app.State = undefined;
var view_ready = false;
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

fn reloadSession() void {
    if (session_ready) session_arena.deinit();
    session_arena = std.heap.ArenaAllocator.init(gpa);
    session_ready = true;
    const source = if (live_mode) "live capture" else "web replay";
    loaded = session_mod.Session.fromData(
        session_arena.allocator(),
        source,
        journal_buf.items,
    ) catch null;
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
    ensureArena();
    journal_buf.clearRetainingCapacity();
    if (addr != 0 and len != 0) {
        const input: [*]const u8 = @ptrFromInt(addr);
        journal_buf.appendSlice(gpa, input[0..len]) catch return 0;
    }
    reloadSession();
    screen = .overview;
    view_ready = false;
    return 1;
}

export fn web_append_journal(addr: usize, len: usize) u32 {
    if (addr == 0 or len == 0) return 1;
    ensureArena();
    if (journal_buf.items.len + len > 32 * 1024 * 1024) {
        const keep = @min(journal_buf.items.len, 16 * 1024 * 1024);
        std.mem.copyForwards(
            u8,
            journal_buf.items[0..keep],
            journal_buf.items[journal_buf.items.len - keep ..],
        );
        journal_buf.shrinkRetainingCapacity(keep);
    }
    const input: [*]const u8 = @ptrFromInt(addr);
    journal_buf.appendSlice(gpa, input[0..len]) catch return 0;
    reloadSession();
    return if (loaded == null) 0 else 1;
}

export fn web_set_live(value: u32) void {
    live_mode = value != 0;
}

export fn web_pointer(x: f32, y: f32, clicked: u32, down: u32, scroll: f32) void {
    const frame = frame_ptr orelse return;
    frame.input.pointer_x = x;
    frame.input.pointer_y = y;
    frame.input.pointer_down = down != 0;
    if (clicked != 0) frame.input.clicked = true;
    frame.input.scroll_y += scroll;
}

export fn web_key(key: u32) void {
    const frame = frame_ptr orelse return;
    frame.input.key = switch (key) {
        0 => .zero,
        1 => .escape,
        2 => .left,
        3 => .right,
        else => .none,
    };
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
        if (!view_ready) {
            view_state = .{ .session = session, .screen = screen };
            view_ready = true;
        }
        view_state.session = session;
        view_state.screen = screen;
        app.view(&view_state, &ui) catch return 0;
    } else {
        gallery.build(&ui) catch return 0;
    }
    ui.finish() catch return 0;
    frame.input.clearTransient();
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

export fn web_atlas_version() u32 {
    const frame = frame_ptr orelse return 0;
    return frame.atlas.version;
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
