//! WebAssembly entrypoint for the read-only web frontend.
//! JS owns WebGL2; Zig owns the UI tree, draw list, and glyph atlas.

const std = @import("std");
const draw = @import("ui/draw.zig");
const frame_mod = @import("ui/frame.zig");
const layout = @import("ui/layout.zig");
const app = @import("app/app.zig");
const lab_state = @import("app/lab/state.zig");
const lab_view = @import("app/lab_view.zig");
const scenario = @import("app/lab/scenario.zig");
const chrome_trace = @import("viz/chrome_trace.zig");
const session_mod = @import("stream/session.zig");
const stream_store = @import("stream/store.zig");
const stream_index = @import("stream/index.zig");
const ttf = @import("ui/ttf.zig");

const gpa = std.heap.wasm_allocator;

var arena: std.heap.ArenaAllocator = undefined;
var arena_ready = false;
var session_arena: std.heap.ArenaAllocator = undefined;
var session_ready = false;
var event_store: stream_store.Store = undefined;
var event_index: stream_index.Index = undefined;
var store_ready = false;
var indexed_events: usize = 0;
var live_mode = false;
var paused_flag = false;
var follow_flag = true;
var frame_ptr: ?*frame_mod.Frame = null;
var loaded: ?session_mod.Session = null;
var lab: lab_state.LabState = undefined;
var lab_ready = false;
var scenario_result: ?[]u8 = null;
var trace_result: ?[]u8 = null;
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

fn ensureLab() bool {
    if (!lab_ready) {
        lab = lab_state.LabState.init(gpa) catch return false;
        lab.host_controls = false;
        lab_ready = true;
    }
    return true;
}

fn syncLab() void {
    if (!ensureLab()) return;
    if (loaded) |*session| {
        lab.view.session = session;
        lab.source.phase = .ready;
    } else {
        lab.view.session = lab.empty_session;
        lab.source.phase = .none;
    }
    lab.view.screen = screen;
    lab.view.live_paused = paused_flag;
    lab.view.live_follow = follow_flag;
}

fn reloadSession() void {
    if (session_ready) session_arena.deinit();
    session_arena = std.heap.ArenaAllocator.init(gpa);
    session_ready = true;
    if (!store_ready) {
        loaded = null;
        return;
    }
    const source = if (live_mode) "live capture" else "web replay";
    loaded = event_index.snapshot(session_arena.allocator(), source) catch null;
    if (lab_ready) {
        // The old session arena is gone; pointers into its event strings must
        // not survive the reload.
        lab.view.selection = null;
        lab.view.filter.comm = null;
    }
    syncLab();
}

fn resetStore() void {
    if (store_ready) {
        event_store.deinit();
        event_index.deinit();
    }
    event_store = stream_store.Store.init(gpa);
    event_store.max_bytes = 64 * 1024 * 1024;
    event_index = stream_index.Index.init(gpa);
    store_ready = true;
    indexed_events = 0;
}

fn indexNewEvents() !void {
    const events = event_store.events.items[indexed_events..];
    try event_index.append(events);
    indexed_events = event_store.eventCount();
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
    if (!ensureLab()) return 0;
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
    resetStore();
    if (addr != 0 and len != 0) {
        const input: [*]const u8 = @ptrFromInt(addr);
        _ = event_store.append(input[0..len]) catch return 0;
    }
    indexNewEvents() catch return 0;
    reloadSession();
    screen = .overview;
    syncLab();
    return 1;
}

export fn web_append_journal(addr: usize, len: usize) u32 {
    if (addr == 0 or len == 0) return 1;
    ensureArena();
    if (!store_ready) return 0;
    const input: [*]const u8 = @ptrFromInt(addr);
    _ = event_store.append(input[0..len]) catch return 0;
    indexNewEvents() catch return 0;
    reloadSession();
    return if (loaded == null) 0 else 1;
}

export fn web_set_live(value: u32) void {
    live_mode = value != 0;
}

export fn web_set_paused(value: u32) void {
    paused_flag = value != 0;
    if (lab_ready) lab.view.live_paused = paused_flag;
}

export fn web_set_follow(value: u32) void {
    follow_flag = value != 0;
    if (lab_ready) lab.view.live_follow = follow_flag;
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
    frame.input.key = @import("ui/input.zig").fromWebCode(key);
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
    if (lab_ready) lab.view.screen = screen;
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

export fn web_run_scenario(addr: usize, len: usize) u32 {
    if (!ensureLab() or loaded == null) return 0;
    if (addr == 0 or len == 0) return 0;
    const input: [*]const u8 = @ptrFromInt(addr);
    var run_arena = std.heap.ArenaAllocator.init(gpa);
    defer run_arena.deinit();
    const parsed = scenario.parse(run_arena.allocator(), input[0..len]) catch return 0;
    const result = scenario.runLoaded(run_arena.allocator(), &lab, &loaded.?, parsed) catch return 0;
    var allocating = std.Io.Writer.Allocating.init(gpa);
    defer allocating.deinit();
    scenario.writeJson(&allocating.writer, result) catch return 0;
    allocating.writer.writeByte('\n') catch return 0;
    const bytes = allocating.toOwnedSlice() catch return 0;
    if (scenario_result) |old| gpa.free(old);
    scenario_result = bytes;
    return 1;
}

export fn web_generate_trace() u32 {
    if (loaded == null) return 0;
    var allocating = std.Io.Writer.Allocating.init(gpa);
    defer allocating.deinit();
    chrome_trace.writeTimeline(&allocating.writer, gpa, loaded.?.events, null, null) catch return 0;
    const bytes = allocating.toOwnedSlice() catch return 0;
    if (trace_result) |old| gpa.free(old);
    trace_result = bytes;
    return 1;
}

export fn web_trace_result_ptr() usize {
    const bytes = trace_result orelse return 0;
    return @intFromPtr(bytes.ptr);
}

export fn web_trace_result_len() u32 {
    const bytes = trace_result orelse return 0;
    return @intCast(bytes.len);
}

export fn web_scenario_result_ptr() usize {
    const bytes = scenario_result orelse return 0;
    return @intFromPtr(bytes.ptr);
}

export fn web_scenario_result_len() u32 {
    const bytes = scenario_result orelse return 0;
    return @intCast(bytes.len);
}

export fn web_frame() u32 {
    const frame = frame_ptr orelse return 0;
    if (!ensureLab()) return 0;
    syncLab();
    frame.list.clear();
    var ui = layout.Ui.init(frame);
    defer ui.deinit();
    ui.frame.input = frame.input;
    lab_view.build(&lab, &ui) catch return 0;
    ui.finish() catch return 0;
    const messages = lab_view.collect(&lab, &ui, &ui.frame.input);
    for (messages.slice()) |message| {
        _ = lab.apply(message) catch {};
    }
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
