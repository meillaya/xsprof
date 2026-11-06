//! Xlib/GLX type declarations and the runtime-loaded function table. Hand-
//! written `extern` declarations only: no C shims, no `@cImport`, no link-time
//! X11/GL dependency (see `docs/platforms/linux.md`).

const std = @import("std");

pub const Display = opaque {};
pub const Window = c_ulong;
pub const Atom = c_ulong;
pub const Colormap = c_ulong;
pub const Visual = opaque {};
pub const GLXContext = opaque {};
pub const KeySym = c_ulong;

pub const VisualInfo = extern struct {
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

pub const SetWindowAttributes = extern struct {
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

/// XSizeHints flags (Xutil.h). PMinSize/PMaxSize are the ones this surface
/// sets so the window manager cannot shrink the console below usability.
pub const pmin_size_flag: c_long = 1 << 4;
pub const pmax_size_flag: c_long = 1 << 5;

pub const SizeHints = extern struct {
    flags: c_long = 0,
    x: c_int = 0,
    y: c_int = 0,
    width: c_int = 0,
    height: c_int = 0,
    min_width: c_int = 0,
    min_height: c_int = 0,
    max_width: c_int = 0,
    max_height: c_int = 0,
    width_inc: c_int = 0,
    height_inc: c_int = 0,
    min_aspect: extern struct { x: c_int, y: c_int } = .{ .x = 0, .y = 0 },
    max_aspect: extern struct { x: c_int, y: c_int } = .{ .x = 0, .y = 0 },
    base_width: c_int = 0,
    base_height: c_int = 0,
    win_gravity: c_int = 0,
};

/// Runtime-loaded Xlib + GLX entry points. `load` is the only fallible step;
/// a missing library or symbol is SKIP/REFUSE upstream, never a fabricated
/// success.
pub const X11 = struct {
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
    next_event: *const fn (*Display, *anyopaque) callconv(.c) c_int,
    pending: *const fn (*Display) callconv(.c) c_int,
    lookup_keysym: *const fn (*const anyopaque, c_int) callconv(.c) KeySym,
    intern_atom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom,
    set_wm_protocols: *const fn (*Display, Window, [*]Atom, c_int) callconv(.c) c_int,
    set_wm_normal_hints: *const fn (*Display, Window, *SizeHints) callconv(.c) c_int,
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

    pub fn load() !X11 {
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
            .next_event = lib.lookup(*const fn (*Display, *anyopaque) callconv(.c) c_int, "XNextEvent") orelse return error.NoX11,
            .pending = lib.lookup(*const fn (*Display) callconv(.c) c_int, "XPending") orelse return error.NoX11,
            .lookup_keysym = lib.lookup(*const fn (*const anyopaque, c_int) callconv(.c) KeySym, "XLookupKeysym") orelse return error.NoX11,
            .intern_atom = lib.lookup(*const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom, "XInternAtom") orelse return error.NoX11,
            .set_wm_protocols = lib.lookup(*const fn (*Display, Window, [*]Atom, c_int) callconv(.c) c_int, "XSetWMProtocols") orelse return error.NoX11,
            .set_wm_normal_hints = lib.lookup(*const fn (*Display, Window, *SizeHints) callconv(.c) c_int, "XSetWMNormalHints") orelse return error.NoX11,
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

    pub fn deinit(self: *X11) void {
        self.gl_lib.close();
        self.lib.close();
    }
};
