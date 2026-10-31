//! Native Linux surface: Xlib window + GLX context, one OpenGL draw list.
//! X11/GL are loaded with std.DynLib, so the build has no link-time GUI
//! dependency. `--smoke` connects under Xvfb but never maps the window.

const std = @import("std");
const builtin = @import("builtin");
const gl = @import("gl.zig");
const draw = @import("../../ui/draw.zig");
const frame_mod = @import("../../ui/frame.zig");
const layout = @import("../../ui/layout.zig");
const app_mod = @import("../../app/app.zig");
const gallery = @import("../../app/gallery.zig");
const session_mod = @import("../../stream/session.zig");

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
    x: X11,
    display: *Display,
    window: Window,
    context: *GLXContext,
    renderer: gl.Renderer,
    session: ?session_mod.Session = null,
    screen: app_mod.Screen = .overview,
    light: bool = false,
    wm_delete: Atom,
};

const width: u32 = 1280;
const height: u32 = 720;

fn render(self: *App) !void {
    const theme: draw.Theme = if (self.light) .{
        .bg = .{ .r = 0xf3, .g = 0xea, .b = 0xd7 },
        .panel = .{ .r = 0xff, .g = 0xf8, .b = 0xeb },
        .raised = .{ .r = 0xe9, .g = 0xdf, .b = 0xcb },
        .text = .{ .r = 0x1a, .g = 0x17, .b = 0x12 },
        .muted = .{ .r = 0x6b, .g = 0x5f, .b = 0x51 },
        .hairline = .{ .r = 0xc9, .g = 0xba, .b = 0xa2 },
    } else .{};
    var frame: frame_mod.Frame = undefined;
    try frame.init(self.allocator, width, height, theme);
    defer frame.deinit();
    var ui = layout.Ui.init(&frame);
    defer ui.deinit();
    if (self.session) |*session| {
        var state = app_mod.State{ .session = session, .screen = self.screen };
        try app_mod.view(&state, &ui);
    } else {
        try gallery.build(&ui);
    }
    try ui.finish();
    self.renderer.paint(frame.list.items.items, &frame.atlas, width, height, theme.bg);
}

pub fn run(
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
        .event_mask = 1 | 4 | 0x8000 | 0x20000,
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

    var app = App{
        .allocator = allocator,
        .x = x,
        .display = display,
        .window = window,
        .context = context,
        .renderer = renderer,
        .session = session,
        .screen = screen,
        .light = light,
        .wm_delete = wm_delete,
    };
    if (smoke) {
        try render(&app);
        x.swap_buffers(display, window);
        std.debug.print("linux smoke: X11/GLX context and one frame rendered offscreen\n", .{});
        return;
    }
    _ = x.map_window(display, window);
    _ = x.flush(display);
    try render(&app);
    x.swap_buffers(display, window);
    while (true) {
        var event: Event = undefined;
        _ = x.next_event(display, &event);
        switch (event.type) {
            2 => {
                const sym = x.lookup_keysym(&event.key, 0);
                if (sym >= '1' and sym <= '5') {
                    app.screen = @fromBackingInt(@intCast(@as(u8, @intCast(sym)) - '1'));
                } else if (sym == 't') {
                    app.light = !app.light;
                } else if (sym == 'q' or sym == 0xff1b) {
                    break;
                }
                try render(&app);
                x.swap_buffers(display, window);
            },
            12, 22 => {
                try render(&app);
                x.swap_buffers(display, window);
            },
            33 => {
                if (event.client.data.l[0] == @as(c_long, @intCast(wm_delete))) break;
            },
            else => {},
        }
    }
}
