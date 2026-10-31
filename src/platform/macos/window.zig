//! Native macOS shell: one AppKit window, a CAMetalLayer, the shared app
//! state, and a coalesced redraw tick. Headless tests never call this.

const std = @import("std");
const xsui = @import("xsui");
const builtin = @import("builtin");
const objc = @import("xsui-objc");
const metal = @import("xsui-metal");
const frame_mod = xsui.frame;
const layout = xsui.layout;
const app_mod = @import("../../app/app.zig");
const lab_state = @import("../../app/lab/state.zig");
const lab_controller = @import("../../app/lab/controller.zig");
const lab_view = @import("../../app/lab_view.zig");
const session_mod = @import("../../stream/session.zig");
const input_mod = xsui.input;

const width: u32 = 1280;
const height: u32 = 720;

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    renderer: metal.Renderer,
    lab: lab_state.LabState,
    controller: lab_controller.Controller,
    session: ?session_mod.Session = null,
    light: bool = false,
    window: objc.Object = undefined,
    view: objc.Object = undefined,
    delegate: objc.Object = undefined,
    dirty: bool = true,
    input: input_mod.Input = .{},

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
        const theme = if (self.light) xsui.themes.light else xsui.themes.dark;
        var frame: frame_mod.Frame = undefined;
        frame.init(self.allocator, width, height, theme) catch return false;
        defer frame.deinit();
        var ui = layout.Ui.init(&frame);
        defer ui.deinit();
        ui.frame.input = self.input;
        lab_view.build(&self.lab, &ui) catch return false;
        ui.finish() catch return false;
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
        if (messages.len != 0 or self.lab.capture.phase == .running or self.lab.transport.playing) {
            self.dirty = true;
        }
        self.input.clearTransient();
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
    .{ .name = "mouseUp:", .imp = &mouseUp, .types = "v@:@" },
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
    if (self.lab.transport.playing) self.lab.advance(33_000);
    const active = self.lab.capture.phase == .running or self.lab.capture.phase == .starting or
        self.lab.transport.playing;
    if (!self.dirty and !active) return;
    if (self.render()) {
        self.dirty = self.dirty or self.lab.capture.phase == .running or
            self.lab.capture.phase == .starting or self.lab.transport.playing;
    }
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
    self.input.pointer_x = @floatCast(point.x);
    self.input.pointer_y = @floatCast(point.y);
    self.input.pointer_down = true;
    self.input.clicked = true;
    self.dirty = true;
}

fn mouseUp(target: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    self.input.pointer_down = false;
    self.dirty = true;
}

fn scrollWheel(target: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    const point = localPoint(target, event);
    self.input.pointer_x = @floatCast(point.x);
    self.input.pointer_y = @floatCast(point.y);
    self.input.scroll_y = @floatCast(objc.msg(f64, event, "scrollingDeltaY", .{}));
    self.dirty = true;
}

fn keyDown(target: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    const chars = objc.fromNSString(objc.msg(?objc.Object, event, "charactersIgnoringModifiers", .{}));
    if (chars.len == 0) return;
    const ch = chars[0];
    if (self.lab.input_focus != .none) {
        if (ch == 127) {
            self.input.key = .backspace;
        } else if (ch == 13) {
            self.input.key = .enter;
        } else if (ch == 27) {
            self.input.key = .escape;
        } else if (ch >= 32) {
            _ = self.input.pushText(chars);
        }
        self.dirty = true;
        return;
    }
    if (ch >= '1' and ch <= '5') {
        self.lab.view.screen = @fromBackingInt(@intCast(ch - '1'));
        self.dirty = true;
        return;
    }
    switch (ch) {
        'q' => self.close(),
        't' => {
            self.light = !self.light;
            self.dirty = true;
        },
        '0' => {
            self.input.key = .zero;
            self.dirty = true;
        },
        'c' => {
            self.input.key = .filter;
            self.dirty = true;
        },
        'P' => {
            self.input.key = .pid;
            self.dirty = true;
        },
        'k' => {
            self.input.key = .kind;
            self.dirty = true;
        },
        'l' => {
            self.input.key = .loss;
            self.dirty = true;
        },
        'L' => {
            self.input.key = .lab;
            self.dirty = true;
        },
        'K' => {
            self.input.key = .palette;
            self.dirty = true;
        },
        127 => {
            self.input.key = .backspace;
            self.dirty = true;
        },
        13 => {
            self.input.key = .enter;
            self.dirty = true;
        },
        'x' => {
            self.input.key = .clear;
            self.dirty = true;
        },
        27 => {
            self.input.key = .escape;
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
    io: std.Io,
    allocator: std.mem.Allocator,
    session: ?session_mod.Session,
    screen: app_mod.Screen,
    light: bool,
    smoke: bool,
) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    var lab = try lab_state.LabState.init(std.heap.smp_allocator);
    if (session != null) {
        lab.view.session = &session.?;
        lab.view.screen = screen;
        lab.source.phase = .ready;
    } else {
        lab.view.screen = screen;
    }
    var app = App{
        .allocator = allocator,
        .io = io,
        .renderer = try metal.Renderer.init(),
        .lab = lab,
        .controller = lab_controller.Controller.init(std.heap.smp_allocator),
        .session = session,
        .light = light,
    };
    defer app.lab.deinit();
    defer app.controller.deinit();
    defer app.renderer.deinit();
    if (app.session != null) app.lab.view.session = &app.session.?;
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
