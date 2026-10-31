//! Native Linux surface: Xlib window + GLX context, one OpenGL draw list.
//! X11/GL are loaded with std.DynLib, so the build has no link-time GUI
//! dependency. `--smoke` connects under Xvfb but never maps the window.

const std = @import("std");
const xsui = @import("xsui");
const builtin = @import("builtin");
const gl = @import("xsui-gl");
const frame_mod = xsui.frame;
const layout = xsui.layout;
const app_mod = @import("../../app/app.zig");
const lab_state = @import("../../app/lab/state.zig");
const lab_controller = @import("../../app/lab/controller.zig");
const lab_view = @import("../../app/lab_view.zig");
const session_mod = @import("../../stream/session.zig");
const input_mod = xsui.input;

const Display = opaque {};
const Window = c_ulong;
const Atom = c_ulong;
const Colormap = c_ulong;
const Visual = opaque {};
const GLXContext = opaque {};
const KeySym = c_ulong;
const VisualInfo = extern struct {
    visual: *Visual,
    visualid: c_ulong,
    screen: c_int,
    depth: c_int,
    class: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    colormap_size: c_int,
    bits_per_rgb: c_int,
};
const SetWindowAttributes = extern struct {
    background_pixmap: c_ulong = 0,
    background_pixel: c_ulong = 0,
    border_pixmap: c_ulong = 0,
    border_pixel: c_ulong = 0,
    bit_gravity: c_int = 0,
    win_gravity: c_int = 0,
    backing_store: c_int = 0,
    backing_planes: c_ulong = 0,
    backing_pixel: c_ulong = 0,
    save_under: c_int = 0,
    event_mask: c_long = 0,
    do_not_propagate_mask: c_long = 0,
    override_redirect: c_int = 0,
    colormap: c_ulong = 0,
    cursor: c_ulong = 0,
};
const KeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};
const ButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: c_int,
};
const ClientMessage = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: extern union { b: [20]u8, s: [10]c_short, l: [5]c_long },
};
const Event = extern union {
    type: c_int,
    key: KeyEvent,
    button: ButtonEvent,
    client: ClientMessage,
    pad: [24]c_long,
};

const X11 = struct {
    lib: std.DynLib,
    gl_lib: std.DynLib,
    open: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    close: *const fn (*Display) callconv(.c) c_int,
    default_screen: *const fn (*Display) callconv(.c) c_int,
    root_window: *const fn (*Display, c_int) callconv(.c) Window,
    create_colormap: *const fn (*Display, Window, *Visual, c_int) callconv(.c) Colormap,
    create_window: *const fn (*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_int, c_uint, *Visual, c_ulong, *SetWindowAttributes) callconv(.c) Window,
    map_window: *const fn (*Display, Window) callconv(.c) c_int,
    store_name: *const fn (*Display, Window, [*:0]const u8) callconv(.c) c_int,
    select_input: *const fn (*Display, Window, c_long) callconv(.c) c_int,
    next_event: *const fn (*Display, *Event) callconv(.c) c_int,
    lookup_keysym: *const fn (*KeyEvent, c_int) callconv(.c) KeySym,
    intern_atom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom,
    set_wm_protocols: *const fn (*Display, Window, [*]Atom, c_int) callconv(.c) c_int,
    destroy_window: *const fn (*Display, Window) callconv(.c) c_int,
    flush: *const fn (*Display) callconv(.c) c_int,
    query_extension: *const fn (*Display, [*:0]const u8, *c_int, *c_int, *c_int) callconv(.c) c_int,
    free: *const fn (?*anyopaque) callconv(.c) void,
    choose_visual: *const fn (*Display, c_int, [*]c_int) callconv(.c) ?*VisualInfo,
    create_context: *const fn (*Display, *VisualInfo, ?*GLXContext, c_int) callconv(.c) ?*GLXContext,
    make_current: *const fn (*Display, Window, ?*GLXContext) callconv(.c) c_int,
    swap_buffers: *const fn (*Display, Window) callconv(.c) void,
    destroy_context: *const fn (*Display, *GLXContext) callconv(.c) void,

    fn load() !X11 {
        var lib = std.DynLib.open("libX11.so.6") catch return error.NoX11;
        errdefer lib.close();
        var gl_lib = std.DynLib.open("libGL.so.1") catch return error.NoGL;
        errdefer gl_lib.close();
        return .{
            .lib = lib,
            .gl_lib = gl_lib,
            .open = lib.lookup(*const fn (?[*:0]const u8) callconv(.c) ?*Display, "XOpenDisplay") orelse return error.NoX11,
            .close = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XCloseDisplay") orelse return error.NoX11,
            .default_screen = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XDefaultScreen") orelse return error.NoX11,
            .root_window = lib.lookup(*const fn (*Display, c_int) callconv(.c) Window, "XRootWindow") orelse return error.NoX11,
            .create_colormap = lib.lookup(*const fn (*Display, Window, *Visual, c_int) callconv(.c) Colormap, "XCreateColormap") orelse return error.NoX11,
            .create_window = lib.lookup(*const fn (*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_int, c_uint, *Visual, c_ulong, *SetWindowAttributes) callconv(.c) Window, "XCreateWindow") orelse return error.NoX11,
            .map_window = lib.lookup(*const fn (*Display, Window) callconv(.c) c_int, "XMapWindow") orelse return error.NoX11,
            .store_name = lib.lookup(*const fn (*Display, Window, [*:0]const u8) callconv(.c) c_int, "XStoreName") orelse return error.NoX11,
            .select_input = lib.lookup(*const fn (*Display, Window, c_long) callconv(.c) c_int, "XSelectInput") orelse return error.NoX11,
            .next_event = lib.lookup(*const fn (*Display, *Event) callconv(.c) c_int, "XNextEvent") orelse return error.NoX11,
            .lookup_keysym = lib.lookup(*const fn (*KeyEvent, c_int) callconv(.c) KeySym, "XLookupKeysym") orelse return error.NoX11,
            .intern_atom = lib.lookup(*const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom, "XInternAtom") orelse return error.NoX11,
            .set_wm_protocols = lib.lookup(*const fn (*Display, Window, [*]Atom, c_int) callconv(.c) c_int, "XSetWMProtocols") orelse return error.NoX11,
            .destroy_window = lib.lookup(*const fn (*Display, Window) callconv(.c) c_int, "XDestroyWindow") orelse return error.NoX11,
            .flush = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XFlush") orelse return error.NoX11,
            .query_extension = lib.lookup(*const fn (*Display, [*:0]const u8, *c_int, *c_int, *c_int) callconv(.c) c_int, "XQueryExtension") orelse return error.NoX11,
            .free = lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "XFree") orelse return error.NoX11,
            .choose_visual = gl_lib.lookup(*const fn (*Display, c_int, [*]c_int) callconv(.c) ?*VisualInfo, "glXChooseVisual") orelse return error.NoGLX,
            .create_context = gl_lib.lookup(*const fn (*Display, *VisualInfo, ?*GLXContext, c_int) callconv(.c) ?*GLXContext, "glXCreateContext") orelse return error.NoGLX,
            .make_current = gl_lib.lookup(*const fn (*Display, Window, ?*GLXContext) callconv(.c) c_int, "glXMakeCurrent") orelse return error.NoGLX,
            .swap_buffers = gl_lib.lookup(*const fn (*Display, Window) callconv(.c) void, "glXSwapBuffers") orelse return error.NoGLX,
            .destroy_context = gl_lib.lookup(*const fn (*Display, *GLXContext) callconv(.c) void, "glXDestroyContext") orelse return error.NoGLX,
        };
    }

    fn deinit(self: *X11) void {
        self.gl_lib.close();
        self.lib.close();
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    x: X11,
    display: *Display,
    window: Window,
    context: *GLXContext,
    renderer: gl.Renderer,
    lab: lab_state.LabState,
    controller: lab_controller.Controller,
    session: ?session_mod.Session = null,
    light: bool = false,
    wm_delete: Atom,
    input: input_mod.Input = .{},
    dirty: bool = false,
};

const width: u32 = 1280;
const height: u32 = 720;

fn render(self: *App) !void {
    const theme = if (self.light) xsui.themes.light else xsui.themes.dark;
    var frame: frame_mod.Frame = undefined;
    try frame.init(self.allocator, width, height, theme);
    defer frame.deinit();
    var ui = layout.Ui.init(&frame);
    defer ui.deinit();
    frame.input = self.input;
    try lab_view.build(&self.lab, &ui);
    try ui.finish();
    const messages = lab_view.collect(&self.lab, &ui, &ui.frame.input);
    for (messages.slice()) |message| {
        const effects = self.lab.apply(message) catch continue;
        for (effects.slice()) |effect| switch (effect) {
            .save_snapshot => |path| {
                frame.savePng(self.io, path) catch {
                    _ = self.lab.apply(.{ .completion = .{ .export_failed = .{
                        .kind = .snapshot,
                        .reason = "cannot write snapshot",
                    } } }) catch {};
                    continue;
                };
                _ = self.lab.apply(.{ .completion = .{ .export_done = .{
                    .kind = .snapshot,
                    .path = path,
                } } }) catch {};
            },
            else => {},
        };
        self.controller.apply(self.io, &self.lab, effects.slice()) catch {};
    }
    self.controller.poll(&self.lab) catch {};
    self.controller.refreshHost(self.io, &self.lab) catch {};
    self.dirty = messages.len != 0 or self.lab.capture.phase == .running or self.lab.transport.playing;
    self.input.clearTransient();
    self.renderer.paint(frame.list.items.items, &frame.atlas, width, height, theme.bg);
}

fn present(self: *App) !void {
    var passes: usize = 0;
    while (passes < 3) : (passes += 1) {
        self.dirty = false;
        try render(self);
        self.x.swap_buffers(self.display, self.window);
        if (!self.dirty) break;
    }
}

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: ?session_mod.Session,
    screen: app_mod.Screen,
    light: bool,
    smoke: bool,
) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    var x = try X11.load();
    defer x.deinit();
    const display = x.open(null) orelse return error.NoDisplay;
    defer _ = x.close(display);
    const screen_num = x.default_screen(display);
    var glx_opcode: c_int = 0;
    var glx_event: c_int = 0;
    var glx_error: c_int = 0;
    if (x.query_extension(display, "GLX", &glx_opcode, &glx_event, &glx_error) == 0)
        return error.NoGLXExtension;
    var visual_attrs = [_]c_int{ 4, 1, 5, 1, 8, 8, 9, 8, 10, 8, 11, 8, 12, 0 };
    var simple_attrs = [_]c_int{ 4, 1, 5, 1, 0 };
    const visual_info = x.choose_visual(display, screen_num, &visual_attrs) orelse
        x.choose_visual(display, screen_num, &simple_attrs) orelse return error.NoVisual;
    defer x.free(visual_info);
    const root = x.root_window(display, screen_num);
    const colormap = x.create_colormap(display, root, visual_info.visual, 0);
    var attrs = SetWindowAttributes{
        .background_pixel = 0,
        .event_mask = 1 | 4 | 8 | 64 | 0x8000 | 0x20000,
        .colormap = colormap,
    };
    const window = x.create_window(
        display,
        root,
        0,
        0,
        width,
        height,
        0,
        @intCast(visual_info.depth),
        1,
        visual_info.visual,
        2 | 2048 | 8192,
        &attrs,
    );
    defer _ = x.destroy_window(display, window);
    _ = x.store_name(display, window, "xsprof");
    const wm_delete = x.intern_atom(display, "WM_DELETE_WINDOW", 0);
    var protocols = [_]Atom{wm_delete};
    _ = x.set_wm_protocols(display, window, &protocols, 1);

    const context = x.create_context(display, visual_info, null, 1) orelse return error.NoGLContext;
    defer x.destroy_context(display, context);
    if (x.make_current(display, window, context) == 0) return error.NoCurrentContext;
    var renderer = try gl.Renderer.init();
    defer renderer.deinit();

    var lab = try lab_state.LabState.init(std.heap.smp_allocator);
    lab.view.screen = screen;
    if (session != null) {
        lab.view.session = &session.?;
        lab.source.phase = .ready;
    }
    var app = App{
        .allocator = allocator,
        .io = io,
        .x = x,
        .display = display,
        .window = window,
        .context = context,
        .renderer = renderer,
        .lab = lab,
        .controller = lab_controller.Controller.init(std.heap.smp_allocator),
        .session = session,
        .light = light,
        .wm_delete = wm_delete,
    };
    defer app.lab.deinit();
    defer app.controller.deinit();
    if (app.session != null) app.lab.view.screen = screen;
    if (app.session != null) app.lab.view.session = &app.session.?;
    if (smoke) {
        try present(&app);
        std.debug.print("linux smoke: X11/GLX context and one frame rendered offscreen\n", .{});
        return;
    }
    _ = x.map_window(display, window);
    _ = x.flush(display);
    try present(&app);
    while (true) {
        var event: Event = undefined;
        _ = x.next_event(display, &event);
        switch (event.type) {
            2 => {
                const sym = x.lookup_keysym(&event.key, 0);
                if (app.lab.input_focus != .none) {
                    if (sym == 0xff08) {
                        app.input.key = .backspace;
                    } else if (sym == 0xff0d) {
                        app.input.key = .enter;
                    } else if (sym == 0xff1b) {
                        app.input.key = .escape;
                    } else if (sym >= 32 and sym < 127) {
                        const byte = [_]u8{@intCast(sym)};
                        _ = app.input.pushText(&byte);
                    }
                    try present(&app);
                    continue;
                }
                if (sym >= '1' and sym <= '5') {
                    app.lab.view.screen = @fromBackingInt(@intCast(@as(u8, @intCast(sym)) - '1'));
                } else if (sym == 't') {
                    app.light = !app.light;
                } else if (sym == 'c') {
                    app.input.key = .filter;
                } else if (sym == 'P') {
                    app.input.key = .pid;
                } else if (sym == 'k') {
                    app.input.key = .kind;
                } else if (sym == 'l') {
                    app.input.key = .loss;
                } else if (sym == 'L') {
                    app.input.key = .lab;
                } else if (sym == 'K') {
                    app.input.key = .palette;
                } else if (sym == 0xff08) {
                    app.input.key = .backspace;
                } else if (sym == 0xff0d) {
                    app.input.key = .enter;
                } else if (sym == 'x') {
                    app.input.key = .clear;
                } else if (sym == 'q' or sym == 0xff1b) {
                    break;
                }
                try present(&app);
            },
            4 => {
                const button = event.button.button;
                if (button == 4 or button == 5) {
                    app.input.scroll_y = if (button == 4) -1 else 1;
                } else {
                    app.input.pointer_x = @floatFromInt(event.button.x);
                    app.input.pointer_y = @floatFromInt(event.button.y);
                    app.input.pointer_down = true;
                    app.input.clicked = true;
                }
                try present(&app);
            },
            5 => {
                app.input.pointer_down = false;
            },
            6 => {
                app.input.pointer_x = @floatFromInt(event.button.x);
                app.input.pointer_y = @floatFromInt(event.button.y);
            },
            12, 22 => {
                try present(&app);
            },
            33 => {
                if (event.client.data.l[0] == @as(c_long, @intCast(wm_delete))) break;
            },
            else => {},
        }
    }
}
