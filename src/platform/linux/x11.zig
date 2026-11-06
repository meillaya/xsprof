//! Native Linux surface: Xlib window + GLX context, one OpenGL draw list.
//! X11/GL are loaded with std.DynLib, so the build has no link-time GUI
//! dependency. `--smoke` connects under Xvfb but never maps the window.
//! Event translation, resize, input, and the monotonic tick live in `app.zig`.

const std = @import("std");
const builtin = @import("builtin");
const xsui = @import("xsui");
const xlib = @import("xlib.zig");
const events = @import("events.zig");
const app_mod = @import("app.zig");
const console_app = @import("../../app/design/app.zig");
const options_mod = @import("../options.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, opts: options_mod.Options) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    const surface = opts.size();
    var x = try xlib.X11.load();
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
    var attrs = xlib.SetWindowAttributes{
        .background_pixel = 0,
        // KeyPress | ButtonPress | ButtonRelease | PointerMotion |
        // Exposure | StructureNotify (ConfigureNotify arrives here).
        .event_mask = 1 | 4 | 8 | 64 | 0x8000 | 0x20000,
        .colormap = colormap,
    };
    const window = x.create_window(
        display,
        root,
        0,
        0,
        surface.width,
        surface.height,
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
    var protocols = [_]xlib.Atom{wm_delete};
    _ = x.set_wm_protocols(display, window, &protocols, 1);
    var hints = xlib.SizeHints{
        .flags = xlib.pmin_size_flag | xlib.pmax_size_flag,
        .min_width = @intCast(options_mod.min_width),
        .min_height = @intCast(options_mod.min_height),
        .max_width = @intCast(options_mod.max_width),
        .max_height = @intCast(options_mod.max_height),
    };
    _ = x.set_wm_normal_hints(display, window, &hints);

    const context = x.create_context(display, visual_info, null, 1) orelse return error.NoGLContext;
    defer x.destroy_context(display, context);
    if (x.make_current(display, window, context) == 0) return error.NoCurrentContext;
    const gl = @import("xsui-gl");
    var renderer = try gl.Renderer.init();
    defer renderer.deinit();

    const clipboard_atom = x.intern_atom(display, "CLIPBOARD", 0);
    const utf8_atom = x.intern_atom(display, "UTF8_STRING", 0);
    const targets_atom = x.intern_atom(display, "TARGETS", 0);
    const design = console_app.App.init(allocator);

    var app = app_mod.App{
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
        .width = surface.width,
        .height = surface.height,
        .a11y = opts.a11y,
    };
    try app.frame.init(allocator, surface.width, surface.height, app.design.theme());
    defer app.frame.deinit();
    app.canvas = xsui.Canvas.init(&app.frame);
    defer app.canvas.deinit();
    app.startSession(opts);
    defer app.shutdownSession();
    defer app.design.deinit();

    if (opts.smoke) {
        try app.present();
        if (opts.resize) |requested| {
            const target = options_mod.clampSize(requested);
            // Inject the same ConfigureNotify the X server would deliver; the
            // window stays unmapped, so this is safe in automated work.
            var synthetic: events.Event = undefined;
            synthetic.configure = .{
                .type = events.configure_notify,
                .serial = 0,
                .send_event = 0,
                .display = display,
                .event = window,
                .window = window,
                .x = 0,
                .y = 0,
                .width = @intCast(target.width),
                .height = @intCast(target.height),
                .border_width = 0,
                .above = 0,
                .override_redirect = 0,
            };
            _ = try app.handleEvent(&synthetic);
            try app.present();
            std.debug.print(
                "linux smoke: synthetic ConfigureNotify {d}x{d} -> frame {d}x{d}\n",
                .{ target.width, target.height, app.frame.width, app.frame.height },
            );
        }
        app.dumpA11y();
        if (opts.live or opts.follow_recorder != null) app.smokeLive(opts);
        std.debug.print("linux smoke: X11/GLX context and one console frame rendered offscreen\n", .{});
        return;
    }

    _ = x.map_window(display, window);
    _ = x.flush(display);
    app.dirty = true;
    try app.present();
    app.dumpA11y();
    var keep_running = true;
    while (keep_running) {
        while (x.pending(display) != 0) {
            var event: events.Event = undefined;
            _ = x.next_event(display, @ptrCast(&event));
            keep_running = try app.handleEvent(&event);
            if (!keep_running) break;
        }
        if (!keep_running) break;
        try app.idle();
        if (app.design.quit_requested) keep_running = false;
        if (app.dirty) try app.present();
        std.Io.sleep(io, .fromMilliseconds(33), .awake) catch {};
    }
}

test "linux surface type-checks without a display" {
    // Never executed; calling it forces semantic analysis of the whole surface
    // and is the headless compile gate for this host.
    const execute = false;
    if (execute) run(std.testing.io, std.testing.allocator, .{}) catch {};
}
