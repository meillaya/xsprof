const std = @import("std");
const builtin = @import("builtin");
const ui_frame = @import("../ui/frame.zig");
const ui_layout = @import("../ui/layout.zig");
const gallery = @import("../app/gallery.zig");
const app = @import("../app/app.zig");
const session_mod = @import("../stream/session.zig");

const Writer = std.Io.Writer;

fn themeFromName(name: []const u8) @import("../ui/draw.zig").Theme {
    if (std.mem.eql(u8, name, "light")) {
        return .{
            .bg = .{ .r = 0xf3, .g = 0xea, .b = 0xd7 },
            .panel = .{ .r = 0xff, .g = 0xf8, .b = 0xeb },
            .raised = .{ .r = 0xe9, .g = 0xdf, .b = 0xcb },
            .text = .{ .r = 0x1a, .g = 0x17, .b = 0x12 },
            .muted = .{ .r = 0x6b, .g = 0x5f, .b = 0x51 },
            .hairline = .{ .r = 0xc9, .g = 0xba, .b = 0xa2 },
        };
    }
    return .{};
}

pub fn cmdSnapshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var path: []const u8 = "xsprof-snapshot.png";
    var width: u32 = 1280;
    var height: u32 = 720;
    var theme_name: []const u8 = "warm-dark";
    var replay: ?[]const u8 = null;
    var screen_name: []const u8 = "overview";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            path = args[i];
        } else if (std.mem.eql(u8, arg, "--width") and i + 1 < args.len) {
            i += 1;
            width = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("snapshot: invalid --width\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--height") and i + 1 < args.len) {
            i += 1;
            height = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("snapshot: invalid --height\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--theme") and i + 1 < args.len) {
            i += 1;
            theme_name = args[i];
        } else if (std.mem.eql(u8, arg, "--replay") and i + 1 < args.len) {
            i += 1;
            replay = args[i];
        } else if (std.mem.eql(u8, arg, "--view") and i + 1 < args.len) {
            i += 1;
            screen_name = args[i];
        }
    }
    if (width < 64 or height < 64 or width > 4096 or height > 4096) {
        try err.writeAll("snapshot: width/height must be 64..4096\n");
        return 2;
    }
    var frame: ui_frame.Frame = undefined;
    frame.init(allocator, width, height, themeFromName(theme_name)) catch {
        try err.writeAll("snapshot: cannot initialize UI frame\n");
        return 1;
    };
    defer frame.deinit();
    var ui = ui_layout.Ui.init(&frame);
    defer ui.deinit();
    if (replay) |journal_path| {
        const screen = app.parseScreen(screen_name) orelse {
            try err.print("snapshot: unknown view {s}\n", .{screen_name});
            return 2;
        };
        const session = session_mod.Session.load(io, allocator, journal_path) catch |load_error| {
            try err.print("snapshot: cannot load {s}: {s}\n", .{ journal_path, @errorName(load_error) });
            return 1;
        };
        var state = app.State{ .session = &session, .screen = screen };
        app.view(&state, &ui) catch {
            try err.writeAll("snapshot: cannot build profiler view\n");
            return 1;
        };
    } else {
        gallery.build(&ui) catch {
            try err.writeAll("snapshot: cannot build gallery frame\n");
            return 1;
        };
    }
    ui.finish() catch {
        try err.writeAll("snapshot: cannot finish layout\n");
        return 1;
    };
    frame.savePng(io, path) catch |save_error| {
        try err.print("snapshot: cannot write {s}: {s}\n", .{ path, @errorName(save_error) });
        return 1;
    };
    try out.print("{s}\n", .{path});
    return 0;
}

pub fn cmdUi(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    _ = out;
    var replay: ?[]const u8 = null;
    var screen = app.Screen.overview;
    var light = false;
    var smoke = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--replay") and i + 1 < args.len) {
            i += 1;
            replay = args[i];
        } else if (std.mem.eql(u8, args[i], "--view") and i + 1 < args.len) {
            i += 1;
            screen = app.parseScreen(args[i]) orelse {
                try err.writeAll("ui: unknown view\n");
                return 2;
            };
        } else if (std.mem.eql(u8, args[i], "--theme") and i + 1 < args.len) {
            i += 1;
            light = std.mem.eql(u8, args[i], "light");
        } else if (std.mem.eql(u8, args[i], "--smoke")) {
            smoke = true;
        }
    }
    if (comptime builtin.os.tag == .linux) {
        const native = @import("../platform/linux/x11.zig");
        var session: ?session_mod.Session = null;
        if (replay) |path| {
            session = session_mod.Session.load(io, allocator, path) catch |load_error| {
                try err.print("ui: {s}\n", .{@errorName(load_error)});
                return 1;
            };
        }
        native.run(io, allocator, session, screen, light, smoke) catch |run_error| {
            try err.print("ui: {s}\n", .{@errorName(run_error)});
            return 1;
        };
        return 0;
    }
    if (comptime builtin.os.tag == .macos) {
        const native = @import("../platform/macos/window.zig");
        var session: ?session_mod.Session = null;
        if (replay) |path| {
            session = session_mod.Session.load(io, allocator, path) catch |load_error| {
                try err.print("ui: {s}\n", .{@errorName(load_error)});
                return 1;
            };
        }
        native.run(io, allocator, session, screen, light, smoke) catch |run_error| {
            try err.print("ui: {s}\n", .{@errorName(run_error)});
            return 1;
        };
        return 0;
    }
    try err.writeAll("ui: this build has no native window surface\n");
    return 2;
}
