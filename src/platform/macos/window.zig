//! Native macOS shell: one AppKit window, a CAMetalLayer, and the shared
//! design console. Headless tests never call this. The timer only runs a
//! human-visible window; --smoke creates a hidden surface and renders once.

const std = @import("std");
const xsui = @import("xsui");
const builtin = @import("builtin");
const objc = @import("xsui-objc");
const metal = @import("xsui-metal");
const frame_mod = xsui.frame;
const console_app = @import("../../app/design/app.zig");
const state_mod = @import("../../app/design/state.zig");

const width: u32 = 1280;
const height: u32 = 720;

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    renderer: metal.Renderer,
    design: console_app.App,
    frame: frame_mod.Frame,
    canvas: xsui.Canvas,
    window: objc.Object = undefined,
    view: objc.Object = undefined,
    delegate: objc.Object = undefined,
    dirty: bool = true,

    fn render(self: *App) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        self.frame.theme = self.design.theme();
        self.frame.list.clear();
        self.canvas.resetHits();
        self.design.draw(&self.canvas) catch return false;
        return self.renderer.present(
            self.frame.list.items.items,
            &self.frame.atlas,
            width,
            height,
            self.design.theme().bg,
        );
    }

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
        objc.msg(void, self.window, "setTitle:", .{objc.nsString("xsprof — read-only console")});
        objc.msg(void, self.window, "center", .{});

        const view_class = objc.defineClass(.{
            .name = "XsprofConsoleView",
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
            .name = "XsprofConsoleDelegate",
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

    fn syncClipboard(self: *App) void {
        const text_value = self.design.copyText();
        if (text_value.len == 0) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const pasteboard = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
        objc.msg(void, pasteboard, "clearContents", .{});
        _ = objc.msg(objc.NSInteger, pasteboard, "setString:forType:", .{
            objc.nsString(text_value),
            objc.nsString("public.utf8-plain-text"),
        });
        self.design.clearCopy();
    }

    fn openJournal(self: *App) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const panel = objc.msg(objc.Object, objc.class("NSOpenPanel"), "openPanel", .{});
        objc.msg(void, panel, "setCanChooseFiles:", .{objc.YES});
        objc.msg(void, panel, "setCanChooseDirectories:", .{objc.NO});
        objc.msg(void, panel, "setAllowsMultipleSelection:", .{objc.NO});
        if (objc.msg(objc.NSInteger, panel, "runModal", .{}) != 1) return;
        const url = objc.msg(objc.Object, panel, "URL", .{});
        const path = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
        if (path.len == 0) return;
        self.design.loadReplay(self.io, path) catch return;
        _ = self.render();
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
    .{ .name = "scrollWheel:", .imp = &scrollWheel, .types = "v@:@" },
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
    self.design.tick(33);
    if (self.design.reload_requested) {
        self.design.reload_requested = false;
        if (self.design.source_path) |path| {
            self.design.loadReplay(self.io, path) catch {};
        }
    }
    if (self.design.open_requested) {
        self.design.open_requested = false;
        self.openJournal();
    }
    _ = self.render();
}

fn localPoint(target: objc.Object, event: objc.Object) objc.CGPoint {
    const window_point = objc.msg(objc.CGPoint, event, "locationInWindow", .{});
    return objc.msg(objc.CGPoint, target, "convertPoint:fromView:", .{
        window_point,
        @as(?objc.Object, null),
    });
}

fn mouseDown(target: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    const point = localPoint(target, event);
    _ = self.render();
    self.design.click(&self.canvas, @floatCast(point.x), @floatCast(point.y));
    self.syncClipboard();
    _ = self.render();
}

fn scrollWheel(target: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    const delta = objc.msg(f64, event, "scrollingDeltaY", .{});
    self.design.scrollBy(@floatCast(-delta * 12.0));
    _ = self.render();
}

fn keyDown(target: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    const chars = objc.fromNSString(objc.msg(?objc.Object, event, "charactersIgnoringModifiers", .{}));
    const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{});
    const mods = console_app.Modifiers{
        .meta = flags & (@as(objc.NSUInteger, 1) << 20) != 0,
        .ctrl = flags & (@as(objc.NSUInteger, 1) << 18) != 0,
        .shift = flags & (@as(objc.NSUInteger, 1) << 17) != 0,
    };
    var cp: u21 = 0;
    const keycode = objc.msg(c_ushort, event, "keyCode", .{});
    switch (keycode) {
        53 => cp = 0x1b,
        36 => cp = 0x0a,
        51 => cp = 0x7f,
        126 => cp = 0x11,
        125 => cp = 0x12,
        123 => cp = 0x13,
        124 => cp = 0x14,
        else => {
            if (chars.len > 0) cp = std.unicode.utf8Decode(chars[0..@min(chars.len, 4)]) catch 0;
        },
    }
    if (mods.meta and (cp == 'q' or cp == 'Q')) {
        self.close();
        return;
    }
    if (cp == 0) return;
    self.design.handleKey(cp, mods);
    self.syncClipboard();
    _ = self.render();
}

fn windowWillClose(target: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    self.close();
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
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    var design = console_app.App.init(allocator);
    defer design.deinit();
    design.state.screen = @fromBackingInt(@intCast(@min(screen_index, 4)));
    if (recorder_dir) |dir| design.setRecorderDir(dir);
    design.state.theme_index = @min(theme_index, xsui.themes.presets.len - 1);
    if (demo_model) |path| {
        try design.loadDemo(io, path);
    } else if (replay) |path| {
        try design.loadReplay(io, path);
    }
    var app = App{
        .allocator = allocator,
        .io = io,
        .renderer = try metal.Renderer.init(),
        .design = design,
        .frame = undefined,
        .canvas = undefined,
    };
    try app.frame.init(allocator, width, height, app.design.theme());
    defer app.frame.deinit();
    app.canvas = xsui.Canvas.init(&app.frame);
    defer app.canvas.deinit();
    defer app.design.deinit();
    defer app.renderer.deinit();
    try app.attach(smoke);
    if (smoke) {
        std.debug.print("native smoke: hidden console NSWindow/CAMetalLayer created; no frame shown\n", .{});
        objc.release(app.window);
        objc.release(app.view);
        objc.release(app.delegate);
        return;
    }
    _ = app.render();
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    objc.msg(void, nsapp, "run", .{});
}
