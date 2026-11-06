//! WebAssembly entrypoint for the read-only web frontend.
//! JS owns WebGL2; Zig owns the UI tree, draw list, and glyph atlas.

const std = @import("std");
const xsui = @import("xsui");
const draw = xsui.draw;
const frame_mod = xsui.frame;
const layout = xsui.layout;
const app = @import("app/app.zig");
const lab_state = @import("app/lab/state.zig");
const lab_view = @import("app/lab_view.zig");
const scenario = @import("app/lab/scenario.zig");
const chrome_trace = @import("viz/chrome_trace.zig");
const session_mod = @import("stream/session.zig");
const stream_store = @import("stream/store.zig");
const stream_index = @import("stream/index.zig");
const console = @import("web_console.zig");

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
var compare_store: stream_store.Store = undefined;
var compare_index: stream_index.Index = undefined;
var compare_store_ready = false;
var compare_arena: std.heap.ArenaAllocator = undefined;
var compare_arena_ready = false;
var compare_session: ?session_mod.Session = null;
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
    frame.input.key = xsui.input.fromWebCode(key);
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
    theme = if (light != 0) xsui.themes.light else xsui.themes.dark;
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

fn clearCompare() void {
    if (lab_ready) {
        lab.compare.session = null;
        lab.compare.phase = .none;
        lab.compare.path_len = 0;
    }
    if (compare_session != null) compare_session = null;
    if (compare_store_ready) {
        compare_store.deinit();
        compare_index.deinit();
        compare_store_ready = false;
    }
    if (compare_arena_ready) {
        compare_arena.deinit();
        compare_arena_ready = false;
    }
}

export fn web_load_compare(addr: usize, len: usize) u32 {
    if (!ensureLab() or addr == 0 or len == 0) return 0;
    clearCompare();
    compare_arena = std.heap.ArenaAllocator.init(gpa);
    compare_arena_ready = true;
    compare_store = stream_store.Store.init(gpa);
    compare_store.max_bytes = 64 * 1024 * 1024;
    compare_store_ready = true;
    compare_index = stream_index.Index.init(gpa);
    const input: [*]const u8 = @ptrFromInt(addr);
    _ = compare_store.append(input[0..len]) catch return 0;
    compare_index.append(compare_store.events.items) catch return 0;
    compare_session = compare_index.snapshot(compare_arena.allocator(), "web compare") catch null;
    if (compare_session == null) return 0;
    lab.compare.phase = .ready;
    lab.compare.session = &compare_session.?;
    return 1;
}

export fn web_clear_compare() void {
    clearCompare();
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
    return @intCast(xsui.webgl.instance_stride_floats);
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

// --- Design console bridge (visible web UI) -------------------------------
export fn web_ui_init(w: u32, h: u32) u32 {
    return console.init(w, h);
}

export fn web_ui_resize(w: u32, h: u32) void {
    console.resize(w, h);
}

export fn web_ui_load_journal(addr: usize, len: usize) u32 {
    return console.loadJournal(addr, len);
}

export fn web_ui_load_recorder(addr: usize, len: usize) u32 {
    return console.loadRecorder(addr, len);
}

export fn web_ui_load_demo(addr: usize, len: usize) u32 {
    return console.loadDemo(addr, len);
}

export fn web_ui_frame() u32 {
    return console.frame();
}

export fn web_ui_instances_ptr() usize {
    return console.instancesPtr();
}

export fn web_ui_instance_stride() u32 {
    return @intCast(xsui.webgl.instance_stride_floats);
}

export fn web_ui_atlas_ptr() usize {
    return console.atlasPtr();
}

export fn web_ui_atlas_size() u32 {
    return console.atlasSize();
}

export fn web_ui_atlas_version() u32 {
    return console.atlasVersion();
}

export fn web_ui_focus_rail() void {
    console.focusRail();
}

export fn web_ui_key(codepoint: u32, meta: u32, ctrl: u32, shift: u32) void {
    console.key(codepoint, meta, ctrl, shift);
}

export fn web_ui_copy_ptr() usize {
    return @intFromPtr(console.copyText().ptr);
}

export fn web_ui_copy_len() u32 {
    return @intCast(console.copyText().len);
}

export fn web_ui_copy_clear() void {
    console.clearCopy();
}

export fn web_ui_pointer_down(x: f32, y: f32) void {
    console.pointerDown(x, y);
}

export fn web_ui_pointer_move(x: f32, y: f32) void {
    console.pointerMove(x, y);
}

export fn web_ui_pointer_leave() void {
    console.pointerLeave();
}

export fn web_ui_pointer_up(x: f32, y: f32) void {
    console.pointerUp(x, y);
}

export fn web_ui_click(x: f32, y: f32) void {
    console.click(x, y);
}

export fn web_ui_scroll(delta: f32) void {
    console.scroll(delta);
}

export fn web_ui_tick(delta_ms: u32) void {
    console.tick(delta_ms);
}

export fn web_ui_set_screen(index: u32) void {
    console.setScreen(index);
}

export fn web_ui_set_theme(index: u32) void {
    console.setTheme(index);
}

export fn web_ui_set_live(value: u32) void {
    console.setLive(value);
}

export fn web_ui_take_open() u32 {
    return console.takeOpen();
}

export fn web_ui_take_reload() u32 {
    return console.takeReload();
}

export fn web_ui_loaded() u32 {
    return console.isLoaded();
}

export fn web_ui_append_journal(addr: usize, len: usize) u32 {
    return console.appendJournal(addr, len);
}

export fn web_ui_event_count() u32 {
    return console.eventCount();
}

export fn web_ui_screen() u32 {
    return console.screenIndex();
}
