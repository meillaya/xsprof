//! Minimal Objective-C runtime bindings: no C shims and no headers.
//! The comptime `msg` prototype pattern is adapted from nanoui (MIT,
//! Copyright (c) 2026 Rach Pradhan); see THIRD_PARTY_NOTICES.md.

const std = @import("std");
const builtin = @import("builtin");

pub const Object = *opaque {};
pub const Class = *opaque {};
pub const SEL = *opaque {};
pub const BOOL = bool;
pub const YES = true;
pub const NO = false;
pub const NSInteger = isize;
pub const NSUInteger = usize;
pub const CGFloat = f64;

pub const CGPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const CGSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };

extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void;
extern "c" fn objc_msgSend_stret() void;
extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) ?Class;
extern "c" fn objc_registerClassPair(cls: Class) void;
extern "c" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) BOOL;
extern "c" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) BOOL;
extern "c" fn class_getInstanceVariable(cls: Class, name: [*:0]const u8) ?*anyopaque;
extern "c" fn ivar_getOffset(v: *anyopaque) isize;
extern "c" fn object_getClass(obj: Object) Class;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

pub fn class(name: [:0]const u8) Class {
    return objc_getClass(name) orelse std.debug.panic("objc: no class {s}", .{name});
}

/// Non-panicking class lookup for fail-closed capability probes (for example
/// `NSAccessibilityElement` on older macOS versions).
pub fn findClass(name: [:0]const u8) ?Class {
    return objc_getClass(name);
}

pub fn sel(name: [:0]const u8) SEL {
    return sel_registerName(name);
}

pub fn msg(comptime R: type, target: anytype, selector: [:0]const u8, args: anytype) R {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    const params = comptime blk: {
        var p: [info.field_types.len + 2]type = undefined;
        p[0] = @TypeOf(target);
        p[1] = SEL;
        for (info.field_types, 0..) |t, i| p[i + 2] = t;
        break :blk p;
    };
    const F = @Fn(&params, &@splat(.{}), R, .{ .@"callconv" = .c });
    const f: *const F = if (comptime needsStret(R))
        @ptrCast(&objc_msgSend_stret)
    else
        @ptrCast(&objc_msgSend);
    return @call(.auto, f, .{ target, sel(selector) } ++ args);
}

fn needsStret(comptime R: type) bool {
    return builtin.cpu.arch == .x86_64 and @sizeOf(R) > 16;
}

pub fn alloc(comptime class_name: [:0]const u8) Object {
    return msg(Object, class(class_name), "alloc", .{});
}

pub fn new(comptime class_name: [:0]const u8) Object {
    return msg(Object, class(class_name), "new", .{});
}

pub fn release(obj: Object) void {
    msg(void, obj, "release", .{});
}

pub fn retain(obj: Object) Object {
    return msg(Object, obj, "retain", .{});
}

pub const Pool = struct {
    handle: ?*anyopaque,
    pub fn push() Pool {
        return .{ .handle = objc_autoreleasePoolPush() };
    }
    pub fn pop(p: Pool) void {
        objc_autoreleasePoolPop(p.handle);
    }
};

pub fn nsString(s: []const u8) Object {
    const str = msg(?Object, alloc("NSString"), "initWithBytes:length:encoding:", .{
        s.ptr,
        s.len,
        @as(NSUInteger, 4),
    }) orelse msg(Object, class("NSString"), "string", .{});
    _ = msg(Object, str, "autorelease", .{});
    return str;
}

pub fn fromNSString(str: ?Object) []const u8 {
    const value = str orelse return "";
    const p = msg(?[*:0]const u8, value, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

pub const Method = struct {
    name: [:0]const u8,
    imp: *const anyopaque,
    types: [:0]const u8,
};

pub const ClassSpec = struct {
    name: [:0]const u8,
    superclass: [:0]const u8 = "NSObject",
    methods: []const Method,
};

const zig_ivar = "zigPtr";

pub fn defineClass(spec: ClassSpec) Class {
    if (objc_getClass(spec.name)) |c| return c;
    const cls = objc_allocateClassPair(class(spec.superclass), spec.name, 0) orelse
        std.debug.panic("objc: cannot define {s}", .{spec.name});
    _ = class_addIvar(cls, zig_ivar, @sizeOf(usize), @ctz(@as(usize, @alignOf(usize))), "^v");
    for (spec.methods) |m| _ = class_addMethod(cls, sel(m.name), m.imp, m.types);
    objc_registerClassPair(cls);
    return cls;
}

fn ivarSlot(obj: Object) ?*?*anyopaque {
    const iv = class_getInstanceVariable(object_getClass(obj), zig_ivar) orelse return null;
    const base: [*]u8 = @ptrCast(obj);
    return @ptrCast(@alignCast(base + @as(usize, @intCast(ivar_getOffset(iv)))));
}

pub fn setZig(obj: Object, ptr: ?*anyopaque) void {
    (ivarSlot(obj) orelse @panic("objc: no zig ivar")).* = ptr;
}

pub fn getZig(comptime T: type, obj: Object) ?*T {
    const slot = ivarSlot(obj) orelse return null;
    return @ptrCast(@alignCast(slot.*));
}
