//! Native macOS shell: one AppKit window, a CAMetalLayer, the shared app
//! state, and a coalesced redraw tick. Headless tests never call this.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const metal = @import("metal.zig");
const draw = @import("../../ui/draw.zig");
const frame_mod = @import("../../ui/frame.zig");
const layout = @import("../../ui/layout.zig");
const app_mod = @import("../../app/app.zig");
const gallery = @import("../../app/gallery.zig");
const session_mod = @import("../../stream/session.zig");

const width: u32 = 1280;
const height: u32 = 720;

pub const App = struct {
    allocator: std.mem.Allocator,
    renderer: metal.Renderer,
    session: ?session_mod.Session = null,
    screen: app_mod.Screen = .overview,
    light: bool = false,
    window: objc.Object = undefined,
    view: objc.Object = undefined,
    delegate: objc.Object = undefined,
    dirty: bool = true,

    fn attach(self: *App, hidden: bool) !void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        _ = objc.msg(objc.BOOL, nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, if (hidden) 1 else 0)});
        const rect = objc.CGRect{ .size = .{ .width = width, .height = height } };
        self.window = objc.msg(
            objc.Object,
            objc.msg(objc.Object, objc.class("NSWindow"), "alloc", .{}),
            "initWithContentRect:styleMask:backing:defer:",
            .{ rect, @as(objc.NSUInteger, 1 | 2 | 4), @as(objc.NSUInteger, 2), objc.NO },
        );
        objc.msg(void, self.window, "setReleasedWhenClosed:", .{objc.NO});
        objc.msg(void, self.window, "setTitle:", .{objc.nsString("xsprof — read-only profiler")});
        objc.msg(void, self.window, "center", .{});

        const view_class = objc.defineClass(.{
            .name = "XsprofView",
            .superclass = "NSView",
            .methods = &view_methods,
        });
        self.view = objc.msg(
            objc.Object,
            objc.msg(objc.Object, view_class, "alloc", .{}),
            "initWithFrame:",
            .{rect},
        );
        objc.setZig(self.view, self);
        objc.msg(void, self.view, "setLayer:", .{self.renderer.layer});
        objc.msg(void, self.view, "setWantsLayer:", .{objc.YES});
        objc.msg(void, self.window, "setContentView:", .{self.view});
        _ = objc.msg(objc.BOOL, self.window, "makeFirstResponder:", .{self.view});
        self.renderer.setSize(width, height);

        const delegate_class = objc.defineClass(.{
            .name = "XsprofDelegate",
            .superclass = "NSObject",
            .methods = &delegate_methods,
        });
        self.delegate = objc.msg(objc.Object, delegate_class, "new", .{});
        objc.setZig(self.delegate, self);
        objc.msg(void, self.window, "setDelegate:", .{self.delegate});
        if (!hidden) {
            _ = objc.msg(objc.Object, objc.class("NSTimer"), "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", .{
                @as(f64, 1.0 / 30.0),
                self.delegate,
                objc.sel("tick:"),
                @as(?objc.Object, null),
                objc.YES,
            });
            objc.msg(void, self.window, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
            objc.msg(void, nsapp, "activateIgnoringOtherApps:", .{objc.YES});
        }
    }

    fn render(self: *App) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const theme: draw.Theme = if (self.light) .{
            .bg = .{ .r = 0xf3, .g = 0xea, .b = 0xd7 },
            .panel = .{ .r = 0xff, .g = 0xf8, .b = 0xeb },
            .raised = .{ .r = 0xe9, .g = 0xdf, .b = 0xcb },
            .text = .{ .r = 0x1a, .g = 0x17, .b = 0x12 },
            .muted = .{ .r = 0x6b, .g = 0x5f, .b = 0x51 },
            .hairline = .{ .r = 0xc9, .g = 0xba, .b = 0xa2 },
        } else .{};
        var frame: frame_mod.Frame = undefined;
        frame.init(self.allocator, width, height, theme) catch return false;
        defer frame.deinit();
        var ui = layout.Ui.init(&frame);
        defer ui.deinit();
        if (self.session) |*session| {
            var state = app_mod.State{ .session = session, .screen = self.screen };
            app_mod.view(&state, &ui) catch return false;
        } else {
            gallery.build(&ui) catch return false;
        }
        ui.finish() catch return false;
        return self.renderer.present(frame.list.items.items, &frame.atlas, width, height, theme.bg);
    }

    fn close(self: *App) void {
        _ = self;
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        objc.msg(void, nsapp, "terminate:", .{@as(?objc.Object, null)});
    }
};

const view_methods = [_]objc.Method{
    .{ .name = "acceptsFirstResponder", .imp = &acceptsFirstResponder, .types = "c@:" },
    .{ .name = "isFlipped", .imp = &isFlipped, .types = "c@:" },
    .{ .name = "keyDown:", .imp = &keyDown, .types = "v@:@" },
    .{ .name = "mouseDown:", .imp = &mouseDown, .types = "v@:@" },
};

const delegate_methods = [_]objc.Method{
    .{ .name = "tick:", .imp = &tick, .types = "v@:@" },
    .{ .name = "windowWillClose:", .imp = &windowWillClose, .types = "v@:@" },
};

fn acceptsFirstResponder(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn isFlipped(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn tick(target: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    if (!self.dirty) return;
    if (self.render()) self.dirty = false;
}

fn mouseDown(target: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    self.dirty = true;
}

fn keyDown(target: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    const chars = objc.fromNSString(objc.msg(?objc.Object, event, "charactersIgnoringModifiers", .{}));
    if (chars.len == 0) return;
    const ch = chars[0];
    if (ch >= '1' and ch <= '5') {
        self.screen = @fromBackingInt(@intCast(ch - '1'));
        self.dirty = true;
        return;
    }
    switch (ch) {
        'q' => self.close(),
        't' => {
            self.light = !self.light;
            self.dirty = true;
        },
        else => {},
    }
}

fn windowWillClose(target: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    self.close();
}

pub fn run(
    allocator: std.mem.Allocator,
    session: ?session_mod.Session,
    screen: app_mod.Screen,
    light: bool,
    smoke: bool,
) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    var app = App{
        .allocator = allocator,
        .renderer = try metal.Renderer.init(),
        .session = session,
        .screen = screen,
        .light = light,
    };
    defer app.renderer.deinit();
    try app.attach(smoke);
    if (smoke) {
        std.debug.print("native smoke: hidden NSWindow/CAMetalLayer created; no frame shown\n", .{});
        objc.release(app.window);
        objc.release(app.view);
        objc.release(app.delegate);
        return;
    }
    app.dirty = true;
    _ = app.render();
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    objc.msg(void, nsapp, "run", .{});
}
