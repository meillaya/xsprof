//! Native Linux surface: Xlib window + GLX context, one OpenGL draw list.
//! X11/GL are loaded with std.DynLib, so the build has no link-time GUI
//! dependency. `--smoke` connects under Xvfb but never maps the window.

const std = @import("std");
const xsui = @import("xsui");
const builtin = @import("builtin");
const gl = @import("xsui-gl");
const frame_mod = xsui.frame;
const console_app = @import("../../app/design/app.zig");
const focus_mod = @import("../../app/design/focus.zig");

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
const SelectionRequest = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    owner: Window,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};
const SelectionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};
const Event = extern union {
    type: c_int,
    key: KeyEvent,
    button: ButtonEvent,
    client: ClientMessage,
    selection_request: SelectionRequest,
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
    pending: *const fn (*Display) callconv(.c) c_int,
    lookup_keysym: *const fn (*KeyEvent, c_int) callconv(.c) KeySym,
    intern_atom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom,
    set_wm_protocols: *const fn (*Display, Window, [*]Atom, c_int) callconv(.c) c_int,
    destroy_window: *const fn (*Display, Window) callconv(.c) c_int,
    flush: *const fn (*Display) callconv(.c) c_int,
    set_selection_owner: *const fn (*Display, Atom, Window, c_ulong) callconv(.c) c_int,
    change_property: *const fn (*Display, Window, Atom, Atom, c_int, c_int, [*]const u8, c_int) callconv(.c) c_int,
    send_event: *const fn (*Display, Window, c_int, c_long, *anyopaque) callconv(.c) c_int,
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
            .pending = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XPending") orelse return error.NoX11,
            .lookup_keysym = lib.lookup(*const fn (*KeyEvent, c_int) callconv(.c) KeySym, "XLookupKeysym") orelse return error.NoX11,
            .intern_atom = lib.lookup(*const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom, "XInternAtom") orelse return error.NoX11,
            .set_wm_protocols = lib.lookup(*const fn (*Display, Window, [*]Atom, c_int) callconv(.c) c_int, "XSetWMProtocols") orelse return error.NoX11,
            .destroy_window = lib.lookup(*const fn (*Display, Window) callconv(.c) c_int, "XDestroyWindow") orelse return error.NoX11,
            .flush = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XFlush") orelse return error.NoX11,
            .set_selection_owner = lib.lookup(*const fn (*Display, Atom, Window, c_ulong) callconv(.c) c_int, "XSetSelectionOwner") orelse return error.NoX11,
            .change_property = lib.lookup(*const fn (*Display, Window, Atom, Atom, c_int, c_int, [*]const u8, c_int) callconv(.c) c_int, "XChangeProperty") orelse return error.NoX11,
            .send_event = lib.lookup(*const fn (*Display, Window, c_int, c_long, *anyopaque) callconv(.c) c_int, "XSendEvent") orelse return error.NoX11,
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
    design: console_app.App,
    frame: frame_mod.Frame,
    canvas: xsui.Canvas,
    wm_delete: Atom,
    clipboard_atom: Atom,
    utf8_atom: Atom,
    targets_atom: Atom,
    clip_buf: [512]u8 = undefined,
    clip_len: usize = 0,
};

const width: u32 = 1280;
const height: u32 = 720;

fn syncClipboard(self: *App) void {
    const text = self.design.copyText();
    if (text.len == 0) return;
    const len = @min(text.len, self.clip_buf.len);
    @memcpy(self.clip_buf[0..len], text[0..len]);
    self.clip_len = len;
    _ = self.x.set_selection_owner(self.display, self.clipboard_atom, self.window, 0);
    self.design.clearCopy();
}

fn serveSelection(self: *App, request: SelectionRequest) void {
    const property = if (request.property != 0) request.property else request.target;
    var utf8_list = [_]Atom{self.utf8_atom};
    if (request.target == self.targets_atom) {
        _ = self.x.change_property(self.display, request.requestor, property, 4, 32, 0, @ptrCast(&utf8_list), 1);
    } else if (self.clip_len > 0) {
        _ = self.x.change_property(self.display, request.requestor, property, self.utf8_atom, 8, 0, self.clip_buf[0..].ptr, @intCast(self.clip_len));
    }
    var notify = SelectionEvent{
        .type = 31,
        .serial = 0,
        .send_event = 0,
        .display = self.display,
        .requestor = request.requestor,
        .selection = request.selection,
        .target = request.target,
        .property = if (self.clip_len > 0 or request.target == self.targets_atom) property else 0,
        .time = request.time,
    };
    _ = self.x.send_event(self.display, request.requestor, 0, 0, @ptrCast(&notify));
    _ = self.x.flush(self.display);
}

fn render(self: *App) !void {
    self.frame.theme = self.design.theme();
    self.frame.list.clear();
    self.canvas.resetHits();
    try self.design.draw(&self.canvas);
    self.renderer.paint(
        self.frame.list.items.items,
        &self.frame.atlas,
        width,
        height,
        self.design.theme().bg,
    );
}

fn present(self: *App) !void {
    try render(self);
    self.x.swap_buffers(self.display, self.window);
}

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    replay: ?[]const u8,
    demo_model: ?[]const u8,
    recorder_dir: ?[]const u8,
    screen_index: u32,
    theme_index: usize,
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
    _ = x.store_name(display, window, "xsprof — read-only console");
    const wm_delete = x.intern_atom(display, "WM_DELETE_WINDOW", 0);
    var protocols = [_]Atom{wm_delete};
    _ = x.set_wm_protocols(display, window, &protocols, 1);

    const context = x.create_context(display, visual_info, null, 1) orelse return error.NoGLContext;
    defer x.destroy_context(display, context);
    if (x.make_current(display, window, context) == 0) return error.NoCurrentContext;
    var renderer = try gl.Renderer.init();
    defer renderer.deinit();

    const clipboard_atom = x.intern_atom(display, "CLIPBOARD", 0);
    const utf8_atom = x.intern_atom(display, "UTF8_STRING", 0);
    const targets_atom = x.intern_atom(display, "TARGETS", 0);
    var design = console_app.App.init(allocator);
    design.state.screen = @fromBackingInt(@intCast(@min(screen_index, 4)));
    if (recorder_dir) |dir| design.setRecorderDir(dir);
    design.state.theme_index = @min(theme_index, xsui.themes.presets.len - 1);
    if (demo_model) |path| {
        design.loadDemo(io, path) catch |err| {
            design.clearSource();
            std.debug.print("linux ui: demo load failed: {s}\n", .{@errorName(err)});
        };
    } else if (replay) |path| {
        design.loadReplay(io, path) catch |err| {
            design.clearSource();
            std.debug.print("linux ui: replay load failed: {s}\n", .{@errorName(err)});
        };
    }
    var app = App{
        .allocator = allocator,
        .io = io,
        .x = x,
        .display = display,
        .window = window,
        .context = context,
        .renderer = renderer,
        .design = design,
        .frame = undefined,
        .canvas = undefined,
        .wm_delete = wm_delete,
        .clipboard_atom = clipboard_atom,
        .utf8_atom = utf8_atom,
        .targets_atom = targets_atom,
    };
    try app.frame.init(allocator, width, height, app.design.theme());
    defer app.frame.deinit();
    app.canvas = xsui.Canvas.init(&app.frame);
    defer app.canvas.deinit();
    defer app.design.deinit();
    if (smoke) {
        try present(&app);
        std.debug.print("linux smoke: X11/GLX context and one console frame rendered offscreen\n", .{});
        return;
    }
    _ = x.map_window(display, window);
    _ = x.flush(display);
    try present(&app);
    while (true) {
        while (x.pending(display) == 0) {
            app.design.tick(33);
            if (app.design.reload_requested) {
                app.design.reload_requested = false;
                if (app.design.source_path) |path| {
                    app.design.loadReplay(io, path) catch {};
                }
            }
            if (app.design.open_requested) {
                app.design.open_requested = false;
                app.design.showToast("open journal: use `xsprof ui --replay <file>`", true);
            }
            try present(&app);
            std.Io.sleep(io, .fromMilliseconds(33), .awake) catch {};
        }
        var event: Event = undefined;
        _ = x.next_event(display, &event);
        switch (event.type) {
            2 => {
                const sym = x.lookup_keysym(&event.key, 0);
                const state = event.key.state;
                var cp: u21 = 0;
                switch (sym) {
                    0xff1b => cp = 0x1b,
                    0xff0d => cp = 0x0a,
                    0xff09 => cp = 0x09,
                    0xff08 => cp = 0x7f,
                    0xff52 => cp = 0x11,
                    0xff54 => cp = 0x12,
                    0xff51 => cp = 0x13,
                    0xff53 => cp = 0x14,
                    else => {
                        if (sym >= 32 and sym < 0x7f) cp = @intCast(sym);
                    },
                }
                if ((state & 64) != 0 and (cp == 'q' or cp == 'Q')) break;
                const mods = console_app.Modifiers{
                    .meta = (state & 64) != 0,
                    .ctrl = (state & 4) != 0,
                    .shift = (state & 1) != 0,
                };
                if (cp != 0 and !focus_mod.key(&app.design, &app.canvas, cp, mods.shift)) {
                    app.design.handleKey(cp, mods);
                }
                syncClipboard(&app);
                try present(&app);
            },
            30 => {
                serveSelection(&app, event.selection_request);
            },
            4 => {
                const button = event.button.button;
                if (button == 4 or button == 5) {
                    app.design.scrollBy(if (button == 4) -120 else 120);
                    try present(&app);
                } else {
                    try present(&app);
                    const px: f32 = @floatFromInt(event.button.x);
                    const py: f32 = @floatFromInt(event.button.y);
                    app.design.click(&app.canvas, px, py);
                    syncClipboard(&app);
                    try present(&app);
                }
            },
            5 => {},
            6 => {},
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
