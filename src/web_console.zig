//! New console bridge for the WebGL2 frontend. Kept separate from the legacy
//! lab exports so web_lab_smoke keeps its scenario/trace contract while the
//! visible product moves to the design console.

const std = @import("std");
const xsui = @import("xsui");
const console_app = @import("app/design/app.zig");
const state_mod = @import("app/design/state.zig");
const pointer_mod = @import("app/design/pointer.zig");
const focus_mod = @import("app/design/focus.zig");

const gpa = std.heap.wasm_allocator;

var ready = false;
var app: console_app.App = undefined;
var frame_ptr: ?*xsui.frame.Frame = null;
var canvas_ptr: ?*xsui.Canvas = null;
var width: u32 = 1440;
var height: u32 = 900;
var loaded = false;

fn ensure() bool {
    if (ready) return true;
    app = console_app.App.init(gpa);
    ready = true;
    return createFrame();
}

fn createFrame() bool {
    destroyFrame();
    const frame_value = gpa.create(xsui.frame.Frame) catch return false;
    frame_value.init(gpa, width, height, app.theme()) catch {
        gpa.destroy(frame_value);
        return false;
    };
    const canvas = gpa.create(xsui.Canvas) catch {
        frame_value.deinit();
        gpa.destroy(frame_value);
        return false;
    };
    canvas.* = xsui.Canvas.init(frame_value);
    frame_ptr = frame_value;
    canvas_ptr = canvas;
    return true;
}

fn destroyFrame() void {
    if (canvas_ptr) |canvas| {
        canvas.deinit();
        gpa.destroy(canvas);
        canvas_ptr = null;
    }
    if (frame_ptr) |frame_value| {
        frame_value.deinit();
        gpa.destroy(frame_value);
        frame_ptr = null;
    }
}

pub fn init(w: u32, h: u32) u32 {
    width = w;
    height = h;
    if (!ensure()) return 0;
    if (frame_ptr == null and !createFrame()) return 0;
    return 1;
}

pub fn resize(w: u32, h: u32) void {
    width = w;
    height = h;
    _ = createFrame();
}

pub fn loadJournal(addr: usize, len: usize) u32 {
    if (!ensure()) return 0;
    const data = if (len == 0) "" else @as([*]const u8, @ptrFromInt(addr))[0..len];
    app.loadJournalData(data, "web replay") catch {
        loaded = false;
        return 0;
    };
    loaded = true;
    return 1;
}

pub fn loadRecorder(addr: usize, len: usize) u32 {
    if (!ensure()) return 0;
    const data = if (len == 0) "" else @as([*]const u8, @ptrFromInt(addr))[0..len];
    app.loadRecorderData(data) catch return 0;
    return 1;
}

pub fn loadDemo(addr: usize, len: usize) u32 {
    if (!ensure()) return 0;
    const data = if (len == 0) "" else @as([*]const u8, @ptrFromInt(addr))[0..len];
    app.loadDemoData(data) catch {
        loaded = false;
        return 0;
    };
    loaded = true;
    return 1;
}

pub fn frame() u32 {
    if (!ensure()) return 0;
    const frame_value = frame_ptr orelse return 0;
    const canvas = canvas_ptr orelse return 0;
    frame_value.theme = app.theme();
    frame_value.list.clear();
    canvas.resetHits();
    app.draw(canvas) catch return 0;
    return @intCast(frame_value.list.items.items.len);
}

pub fn instancesPtr() usize {
    const frame_value = frame_ptr orelse return 0;
    return @intFromPtr(frame_value.list.items.items.ptr);
}

pub fn atlasPtr() usize {
    const frame_value = frame_ptr orelse return 0;
    return @intFromPtr(frame_value.atlas.pixels.ptr);
}

pub fn atlasSize() u32 {
    const frame_value = frame_ptr orelse return 0;
    return @intCast(frame_value.atlas.width);
}

pub fn atlasVersion() u32 {
    const frame_value = frame_ptr orelse return 0;
    return frame_value.atlas.version;
}

pub fn focusRail() void {
    if (!ready) return;
    app.state.focus_id = 100 + @as(u32, @backingInt(app.state.screen));
    app.state.focus_visible = true;
}

pub fn key(codepoint: u32, meta: u32, ctrl: u32, shift: u32) void {
    if (!ensure()) return;
    if (canvas_ptr) |canvas| {
        if (focus_mod.key(&app, canvas, @intCast(codepoint), shift != 0)) return;
    }
    app.handleKey(@intCast(codepoint), .{
        .meta = meta != 0,
        .ctrl = ctrl != 0,
        .shift = shift != 0,
    });
}

pub fn copyText() []const u8 {
    if (!ready) return "";
    return app.copyText();
}

pub fn clearCopy() void {
    if (ready) app.clearCopy();
}

pub fn pointerDown(x: f32, y: f32) void {
    if (ready) pointer_mod.pointerDown(&app, x, y);
}

pub fn pointerMove(x: f32, y: f32) void {
    if (ready) pointer_mod.pointerMove(&app, x, y);
}

pub fn pointerLeave() void {
    if (ready) app.state.hover_slice = null;
}

pub fn pointerUp(x: f32, y: f32) void {
    if (ready) if (canvas_ptr) |canvas| pointer_mod.pointerUp(&app, canvas, x, y);
}

pub fn click(x: f32, y: f32) void {
    if (!ensure()) return;
    const canvas = canvas_ptr orelse return;
    // The last frame populated hit rectangles; if a surface somehow clicks
    // before the first frame, build one deterministically.
    if (canvas.hits.items.len == 0) _ = frame();
    app.click(canvas, x, y);
}

pub fn scroll(delta: f32) void {
    if (!ensure()) return;
    app.scrollBy(delta);
}

pub fn tick(delta_ms: u32) void {
    if (!ensure()) return;
    app.tick(delta_ms);
}

pub fn setScreen(index: u32) void {
    if (!ensure()) return;
    const screens = [_]state_mod.Screen{ .overview, .timeline, .advisor, .events, .capture };
    app.state.screen = screens[@min(index, 4)];
}

pub fn setLive(value: u32) void {
    if (!ensure()) return;
    app.setLive(value != 0);
}

pub fn setTheme(index: u32) void {
    if (!ensure()) return;
    if (index < xsui.themes.presets.len) app.state.theme_index = index;
}

pub fn takeOpen() u32 {
    if (!ready) return 0;
    const value: u32 = if (app.open_requested) 1 else 0;
    app.open_requested = false;
    return value;
}

pub fn takeReload() u32 {
    if (!ready) return 0;
    const value: u32 = if (app.reload_requested) 1 else 0;
    app.reload_requested = false;
    return value;
}

pub fn isLoaded() u32 {
    return if (loaded) 1 else 0;
}

pub fn widthValue() u32 {
    return width;
}

pub fn heightValue() u32 {
    return height;
}
