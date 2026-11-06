//! Native macOS shell: one AppKit window, a CAMetalLayer, and the shared
//! design console. Headless tests never call this. The timer only runs a
//! human-visible window; --smoke creates a hidden surface and renders once
//! (plus an optional synthetic resize and accessibility-tree assertion).

const std = @import("std");
const xsui = @import("xsui");
const builtin = @import("builtin");
const objc = @import("xsui-objc");
const metal = @import("xsui-metal");
const frame_mod = xsui.frame;
const console_app = @import("../../app/design/app.zig");
const focus_mod = @import("../../app/design/focus.zig");
const pointer_mod = @import("../../app/design/pointer.zig");
const options_mod = @import("../options.zig");
const a11y_mod = @import("a11y.zig");
const session_mod = @import("../session.zig");
const live_mod = @import("../../app/design/live.zig");
const follow_source = @import("../follow_source.zig");

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
    tracking: objc.Object = undefined,
    /// Logical (1x) viewport in points. Retina crispness is DEGRADED: the
    /// drawable stays at 1x until the scale-aware canvas lands.
    width: u32 = options_mod.default_width,
    height: u32 = options_mod.default_height,
    scale: f64 = 1.0,
    dirty: bool = true,
    last_tick_ns: i96 = 0,
    a11y_enabled: bool = false,
    a11y: ?a11y_mod.Bridge = null,
    a11y_buffer: [a11y_mod.max_nodes]objc.Object = undefined,

    /// Draws the shared console and presents it. Returns false when no drawable
    /// is available (the tick retries) or the draw failed.
    fn render(self: *App) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        self.frame.theme = self.design.theme();
        self.frame.list.clear();
        self.canvas.resetHits();
        self.design.draw(&self.canvas) catch return false;
        self.updateA11y();
        const presented = self.renderer.present(
            self.frame.list.items.items,
            &self.frame.atlas,
            self.width,
            self.height,
            self.design.theme().bg,
        );
        if (presented) self.dirty = false;
        return presented;
    }

    /// Single resize path: logical frame + canvas clip + drawable + AX frames.
    fn resize(self: *App, requested_width: u32, requested_height: u32) void {
        const size = options_mod.clampSize(.{ .width = requested_width, .height = requested_height });
        if (size.width == self.width and size.height == self.height) return;
        self.width = size.width;
        self.height = size.height;
        self.frame.resize(size.width, size.height);
        self.canvas.resetViewport();
        self.renderer.setSize(size.width, size.height);
        const layer_frame = objc.CGRect{
            .size = .{ .width = @floatFromInt(size.width), .height = @floatFromInt(size.height) },
        };
        objc.msg(void, self.renderer.layer, "setFrame:", .{layer_frame});
        self.dirty = true;
    }

    /// Reads the window's content bounds and backing scale. Called by the
    /// resize/backing delegates and once per tick as a safety net.
    fn syncSizeFromWindow(self: *App) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const content = objc.msg(objc.Object, self.window, "contentView", .{});
        const bounds = objc.msg(objc.CGRect, content, "bounds", .{});
        if (bounds.size.width < 1 or bounds.size.height < 1) return;
        self.scale = objc.msg(f64, self.window, "backingScaleFactor", .{});
        self.resize(@intFromFloat(@round(bounds.size.width)), @intFromFloat(@round(bounds.size.height)));
    }

    fn tickDelta(self: *App) void {
        const now = std.Io.Clock.now(.awake, self.io).nanoseconds;
        var delta_ms: u64 = 33;
        if (self.last_tick_ns != 0 and now > self.last_tick_ns) {
            const delta_ns = now - self.last_tick_ns;
            delta_ms = @intCast(@min(@divTrunc(delta_ns, std.time.ns_per_ms), 100));
            if (delta_ms == 0) delta_ms = 1;
        }
        self.last_tick_ns = now;
        self.design.tick(delta_ms);
        if (self.design.state.timeline_playing) self.dirty = true;
    }

    fn updateA11y(self: *App) void {
        const bridge = if (self.a11y) |*value| value else return;
        var tree = xsui.a11y.Tree.build(self.allocator, &self.canvas, self.design.state.focus_id) catch return;
        defer tree.deinit();
        bridge.update(&tree);
    }

    fn activateNode(self: *App, id: u32) void {
        const rect = self.canvas.hitRect(id) orelse return;
        _ = self.render();
        self.design.click(&self.canvas, rect.x + rect.w * 0.5, rect.y + rect.h * 0.5);
        self.syncClipboard();
        self.dirty = true;
        _ = self.render();
    }

    /// Hidden smoke: proves the AX object tree exists without ordering the
    /// window front or posting to a real screen.
    fn smokeA11y(self: *App) void {
        const bridge = if (self.a11y) |*value| value else {
            if (self.a11y_enabled) {
                std.debug.print("native a11y smoke: DEGRADED reason=\"bridge unavailable\"\n", .{});
            }
            return;
        };
        var tree = xsui.a11y.Tree.build(self.allocator, &self.canvas, self.design.state.focus_id) catch {
            std.debug.print("native a11y smoke: DEGRADED reason=\"tree build failed\"\n", .{});
            return;
        };
        defer tree.deinit();
        bridge.update(&tree);
        const children = bridge.fillChildren(&self.a11y_buffer);
        const array = bridge.childrenArray(&self.a11y_buffer);
        const array_count = objc.msg(objc.NSUInteger, array, "count", .{});
        const focused: u32 = if (bridge.focusedProxy() != null) 1 else 0;
        std.debug.print(
            "native a11y smoke: nodes={d} bridge={d} array={d} focused={d} truncated={s}\n",
            .{ tree.count(), children, array_count, focused, if (tree.truncated) "true" else "false" },
        );
    }

    fn attach(self: *App, hidden: bool) !void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        _ = objc.msg(objc.BOOL, nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, if (hidden) 1 else 0)});
        const rect = objc.CGRect{ .size = .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) } };
        self.window = objc.msg(
            objc.Object,
            objc.msg(objc.Object, objc.class("NSWindow"), "alloc", .{}),
            "initWithContentRect:styleMask:backing:defer:",
            // titled | closable | miniaturizable | resizable
            .{ rect, @as(objc.NSUInteger, 1 | 2 | 4 | 8), @as(objc.NSUInteger, 2), objc.NO },
        );
        objc.msg(void, self.window, "setReleasedWhenClosed:", .{objc.NO});
        objc.msg(void, self.window, "setTitle:", .{objc.nsString("xsprof — read-only console")});
        objc.msg(void, self.window, "setContentMinSize:", .{objc.CGSize{
            .width = @floatFromInt(options_mod.min_width),
            .height = @floatFromInt(options_mod.min_height),
        }});
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
        self.renderer.setSize(self.width, self.height);
        self.tracking = objc.msg(
            objc.Object,
            objc.msg(objc.Object, objc.class("NSTrackingArea"), "alloc", .{}),
            "initWithRect:options:owner:userInfo:",
            .{
                rect,
                // mouseMoved | activeInKeyWindow | inVisibleRect | enabledDuringMouseDrag
                @as(objc.NSUInteger, 0x02 | 0x20 | 0x200 | 0x400),
                self.view,
                @as(?objc.Object, null),
            },
        );
        objc.msg(void, self.view, "addTrackingArea:", .{self.tracking});

        const delegate_class = objc.defineClass(.{
            .name = "XsprofConsoleDelegate",
            .superclass = "NSObject",
            .methods = &delegate_methods,
        });
        self.delegate = objc.msg(objc.Object, delegate_class, "new", .{});
        objc.setZig(self.delegate, self);
        objc.msg(void, self.window, "setDelegate:", .{self.delegate});

        if (self.a11y_enabled) {
            self.a11y = a11y_mod.Bridge.init(self.allocator, self.view, self.window) catch |err| blk: {
                std.debug.print("macos ui: a11y DEGRADED reason=\"{s}\"\n", .{@errorName(err)});
                break :blk null;
            };
            if (self.a11y) |*bridge| bridge.setPressHandler(self, pressFromA11y);
        }

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

    fn close(self: *App) void {
        _ = self;
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        objc.msg(void, nsapp, "terminate:", .{@as(?objc.Object, null)});
    }
};

fn pressFromA11y(ctx: ?*anyopaque, id: u32) void {
    const self: *App = @ptrCast(@alignCast(ctx orelse return));
    self.activateNode(id);
}

const view_methods = [_]objc.Method{
    .{ .name = "acceptsFirstResponder", .imp = &acceptsFirstResponder, .types = "c@:" },
    .{ .name = "isFlipped", .imp = &isFlipped, .types = "c@:" },
    .{ .name = "keyDown:", .imp = &keyDown, .types = "v@:@" },
    .{ .name = "mouseDown:", .imp = &mouseDown, .types = "v@:@" },
    .{ .name = "mouseUp:", .imp = &mouseUp, .types = "v@:@" },
    .{ .name = "mouseMoved:", .imp = &mouseMoved, .types = "v@:@" },
    .{ .name = "mouseDragged:", .imp = &mouseDragged, .types = "v@:@" },
    .{ .name = "scrollWheel:", .imp = &scrollWheel, .types = "v@:@" },
    .{ .name = "viewDidChangeBackingProperties", .imp = &viewDidChangeBackingProperties, .types = "v@:" },
    .{ .name = "isAccessibilityElement", .imp = &axIsElement, .types = "c@:" },
    .{ .name = "accessibilityRole", .imp = &axRole, .types = "@@:" },
    .{ .name = "accessibilityLabel", .imp = &axLabel, .types = "@@:" },
    .{ .name = "accessibilityChildren", .imp = &axChildren, .types = "@@:" },
    .{ .name = "accessibilityChildrenInNavigationOrder", .imp = &axChildren, .types = "@@:" },
    .{ .name = "accessibilityFocusedUIElement", .imp = &axFocused, .types = "@@:" },
    .{ .name = "accessibilityHitTest:", .imp = &axHitTest, .types = "@@:{CGPoint=dd}" },
    .{ .name = "accessibilityParent", .imp = &axParent, .types = "@@:" },
};

const delegate_methods = [_]objc.Method{
    .{ .name = "tick:", .imp = &tick, .types = "v@:@" },
    .{ .name = "windowWillClose:", .imp = &windowWillClose, .types = "v@:@" },
    .{ .name = "windowDidResize:", .imp = &windowDidResize, .types = "v@:@" },
    .{ .name = "windowWillResize:toSize:", .imp = &windowWillResize, .types = "{CGSize=dd}@:@{CGSize=dd}" },
    .{ .name = "windowDidChangeBackingProperties:", .imp = &windowDidChangeBackingProperties, .types = "v@:@" },
};

fn acceptsFirstResponder(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn isFlipped(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn localPoint(target: objc.Object, event: objc.Object) objc.CGPoint {
    const window_point = objc.msg(objc.CGPoint, event, "locationInWindow", .{});
    return objc.msg(objc.CGPoint, target, "convertPoint:fromView:", .{
        window_point,
        @as(?objc.Object, null),
    });
}

fn tick(target: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    self.tickDelta();
    var session = session_mod.Session{ .allocator = self.allocator, .io = self.io, .app = &self.design };
    session.drain();
    if (self.design.quit_requested) {
        self.close();
        return;
    }
    if (self.dirty) _ = self.render();
}

fn mouseDown(target: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    const point = localPoint(target, event);
    _ = self.render();
    pointer_mod.pointerDown(&self.design, @floatCast(point.x), @floatCast(point.y));
    self.syncClipboard();
    self.dirty = true;
    _ = self.render();
}

fn mouseUp(target: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    const point = localPoint(target, event);
    _ = self.render();
    pointer_mod.pointerUp(&self.design, &self.canvas, @floatCast(point.x), @floatCast(point.y));
    self.syncClipboard();
    self.dirty = true;
    _ = self.render();
}

fn mouseMoved(target: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    const point = localPoint(target, event);
    pointer_mod.pointerMove(&self.design, @floatCast(point.x), @floatCast(point.y));
    self.dirty = true;
    _ = self.render();
}

fn mouseDragged(target: objc.Object, sel: objc.SEL, event: objc.Object) callconv(.c) void {
    mouseMoved(target, sel, event);
}

fn viewDidChangeBackingProperties(target: objc.Object, _: objc.SEL) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    self.syncSizeFromWindow();
    _ = self.render();
}

fn windowDidResize(target: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    self.syncSizeFromWindow();
    _ = self.render();
}

fn windowWillResize(
    target: objc.Object,
    _: objc.SEL,
    _: objc.Object,
    size: objc.CGSize,
) callconv(.c) objc.CGSize {
    _ = objc.getZig(App, target) orelse return size;
    const fitted = options_mod.fitBounds(
        .{
            .width = @intFromFloat(@max(1, @round(size.width))),
            .height = @intFromFloat(@max(1, @round(size.height))),
        },
        .{ .width = options_mod.min_width, .height = options_mod.min_height },
    );
    return .{ .width = @floatFromInt(fitted.width), .height = @floatFromInt(fitted.height) };
}

fn windowDidChangeBackingProperties(target: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    self.syncSizeFromWindow();
    _ = self.render();
}

fn scrollWheel(target: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    const delta = objc.msg(f64, event, "scrollingDeltaY", .{});
    self.design.scrollBy(@floatCast(-delta * 12.0));
    self.dirty = true;
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
        48 => cp = 0x09,
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
    _ = self.render();
    if (focus_mod.key(&self.design, &self.canvas, cp, mods.shift)) {
        self.dirty = true;
        _ = self.render();
        return;
    }
    self.design.handleKey(cp, mods);
    self.syncClipboard();
    self.dirty = true;
    _ = self.render();
}

fn windowWillClose(target: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const self = objc.getZig(App, target) orelse return;
    self.close();
}

fn axIsElement(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    // The view is a container; children are the AX elements.
    return objc.NO;
}

fn axRole(_: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return objc.nsString("AXGroup");
}

fn axLabel(_: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return objc.nsString("xsprof console");
}

fn axChildren(target: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const self = objc.getZig(App, target) orelse return emptyArray();
    const bridge = if (self.a11y) |*value| value else return emptyArray();
    return bridge.childrenArray(&self.a11y_buffer);
}

fn axFocused(target: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const self = objc.getZig(App, target) orelse return target;
    const bridge = if (self.a11y) |*value| value else return target;
    return bridge.focusedProxy() orelse target;
}

fn axHitTest(target: objc.Object, _: objc.SEL, point: objc.CGPoint) callconv(.c) objc.Object {
    const self = objc.getZig(App, target) orelse return target;
    const in_window = objc.msg(objc.CGPoint, self.window, "convertPointFromScreen:", .{point});
    const local = objc.msg(objc.CGPoint, self.view, "convertPoint:fromView:", .{
        in_window,
        @as(?objc.Object, null),
    });
    const bridge = if (self.a11y) |*value| value else return target;
    return bridge.proxyAt(@floatCast(local.x), @floatCast(local.y)) orelse target;
}

fn axParent(target: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const self = objc.getZig(App, target) orelse return target;
    return self.window;
}

fn emptyArray() objc.Object {
    return objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
}

fn smokeFollow(io: std.Io, allocator: std.mem.Allocator, opts: options_mod.Options) void {
    if (opts.follow_recorder) |dir| {
        var controller = live_mod.Controller.init(allocator, io, .{});
        defer controller.deinit();
        var follow = follow_source.Source{ .dir = dir };
        controller.attach(follow.source(), .{});
        _ = controller.start();
        var selection = live_mod.Selection{};
        var iteration: usize = 0;
        while (iteration < 5) : (iteration += 1) {
            const result = controller.poll(@as(u64, @intCast(iteration)) * 120, selection);
            selection = result.selection;
            std.Io.sleep(io, .fromMilliseconds(120), .awake) catch {};
        }
        const status = controller.statusView();
        const stats = controller.statsView();
        std.debug.print(
            "live smoke: state={s} reason=\"{s}\" source_events={d} indexed={d} rebuilt={d} lost={d}\n",
            .{ @tagName(status.state), status.reason, stats.source_events, stats.events, stats.rebuilds, stats.lost },
        );
        if (controller.view()) |model| {
            std.debug.print("live smoke: model events={d} window_ms={d:.3}\n", .{
                model.events.len,
                model.summary.windowMs,
            });
        }
        return;
    }
    if (opts.live) {
        std.debug.print(
            "live smoke: state=skip reason=\"non-Linux host: perf_event_open unavailable\"\n",
            .{},
        );
    }
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, opts: options_mod.Options) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const surface = opts.size();
    const design = console_app.App.init(allocator);
    var app = App{
        .allocator = allocator,
        .io = io,
        .renderer = try metal.Renderer.init(),
        .design = design,
        .frame = undefined,
        .canvas = undefined,
        .width = surface.width,
        .height = surface.height,
        .a11y_enabled = opts.a11y,
    };
    try app.frame.init(allocator, surface.width, surface.height, app.design.theme());
    defer app.frame.deinit();
    app.canvas = xsui.Canvas.init(&app.frame);
    defer app.canvas.deinit();
    defer app.design.deinit();
    defer app.renderer.deinit();
    const session = session_mod.Session{ .allocator = allocator, .io = io, .app = &app.design };
    session.start(opts, .macos);
    try app.attach(opts.smoke);
    defer objc.release(app.tracking);
    defer objc.release(app.delegate);
    defer objc.release(app.view);
    defer objc.release(app.window);
    // Bridge is a plain Zig value; proxies are released by its deinit.
    defer if (app.a11y) |*bridge| bridge.deinit();
    if (opts.smoke) {
        _ = app.render();
        if (opts.resize) |requested| {
            const target = options_mod.clampSize(requested);
            app.resize(target.width, target.height);
            _ = app.render();
            std.debug.print(
                "macos smoke: resize {d}x{d} -> frame {d}x{d} drawable 1x\n",
                .{ target.width, target.height, app.frame.width, app.frame.height },
            );
        }
        app.smokeA11y();
        smokeFollow(io, allocator, opts);
        std.debug.print("native smoke: hidden console NSWindow/CAMetalLayer created; no frame shown\n", .{});
        return;
    }
    _ = app.render();
    const scale = objc.msg(f64, app.window, "backingScaleFactor", .{});
    if (scale > 1.01) {
        std.debug.print(
            "macos ui: backingScaleFactor={d:.2} DEGRADED (1x drawable; Retina crispness is a later item)\n",
            .{scale},
        );
    }
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    objc.msg(void, nsapp, "run", .{});
}
