const std = @import("std");
const xsui = @import("xsui");
const builtin = @import("builtin");
const frame_mod = xsui.frame;
const app = @import("../app/app.zig");
const session_mod = @import("../stream/session.zig");
const design_model = @import("../app/design/model.zig");
const design_state = @import("../app/design/state.zig");
const design_view = @import("../app/design/view.zig");

const design_derive = @import("../app/design/derive.zig");

const Writer = std.Io.Writer;

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
    var demo_model: ?[]const u8 = null;
    var recorder_dir: ?[]const u8 = null;
    var screen_name: []const u8 = "overview";
    var overlay_name: []const u8 = "none";
    var backend_name: []const u8 = "cpu";
    var playhead_s: f64 = 0;
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
        } else if (std.mem.eql(u8, arg, "--demo-model") and i + 1 < args.len) {
            i += 1;
            demo_model = args[i];
        } else if (std.mem.eql(u8, arg, "--recorder-dir") and i + 1 < args.len) {
            i += 1;
            recorder_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--overlay") and i + 1 < args.len) {
            i += 1;
            overlay_name = args[i];
        } else if (std.mem.eql(u8, arg, "--playhead") and i + 1 < args.len) {
            i += 1;
            playhead_s = std.fmt.parseFloat(f64, args[i]) catch 0;
        } else if (std.mem.eql(u8, arg, "--backend") and i + 1 < args.len) {
            i += 1;
            backend_name = args[i];
        }
    }
    if (width < 64 or height < 64 or width > 4096 or height > 4096) {
        try err.writeAll("snapshot: width/height must be 64..4096\n");
        return 2;
    }
    const theme_index = xsui.themes.indexOf(theme_name) orelse 0;
    var frame: frame_mod.Frame = undefined;
    frame.init(allocator, width, height, xsui.themes.presets[theme_index].theme) catch {
        try err.writeAll("snapshot: cannot initialize UI frame\n");
        return 1;
    };
    defer frame.deinit();
    if (demo_model) |model_path| {
        const model = design_model.loadDemo(io, allocator, model_path) catch |load_error| {
            try err.print("snapshot: cannot load demo model {s}: {s}\n", .{ model_path, @errorName(load_error) });
            return 1;
        };
        const screen = design_state.parseScreen(screen_name) orelse {
            try err.print("snapshot: unknown view {s}\n", .{screen_name});
            return 2;
        };
        var state = design_state.State{ .screen = screen, .theme_index = theme_index, .timeline_playhead = playhead_s * 1000.0 };
        state.dialog = parseOverlay(overlay_name);
        var canvas = xsui.Canvas.init(&frame);
        defer canvas.deinit();
        design_view.view(&model, &state, &canvas) catch {
            try err.writeAll("snapshot: cannot build console view\n");
            return 1;
        };
        saveFrame(io, allocator, &frame, path, backend_name) catch |save_error| {
            try err.print("snapshot: cannot write {s}: {s}\n", .{ path, @errorName(save_error) });
            return 1;
        };
        try out.print("{s}\n", .{path});
        return 0;
    }
    const screen = design_state.parseScreen(screen_name) orelse {
        try err.print("snapshot: unknown view {s}\n", .{screen_name});
        return 2;
    };
    var state = design_state.State{ .screen = screen, .theme_index = theme_index, .timeline_playhead = playhead_s * 1000.0 };
    state.dialog = parseOverlay(overlay_name);
    var model: design_model.Model = undefined;
    if (replay) |journal_path| {
        const session = session_mod.Session.load(io, allocator, journal_path) catch |load_error| {
            try err.print("snapshot: cannot load {s}: {s}\n", .{ journal_path, @errorName(load_error) });
            return 1;
        };
        model = design_derive.fromSession(allocator, &session, .{
            .fixture = journal_path,
            .source = "REPLAY",
        }) catch |derive_error| {
            try err.print("snapshot: cannot derive console model: {s}\n", .{@errorName(derive_error)});
            return 1;
        };
        if (recorder_dir) |dir| {
            const manifest_path = std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir}) catch null;
            if (manifest_path) |mp| {
                const manifest_mod = @import("../recorder/manifest.zig");
                if (manifest_mod.read(io, allocator, mp)) |maybe| {
                    if (maybe) |manifest| {
                        design_derive.applyRecorder(allocator, &model, &manifest) catch {};
                    }
                } else |_| {}
            }
        }
    } else {
        model = .{
            .meta = .{ .host = "no source", .source = "EMPTY", .fixture = "open a journal" },
            .summary = .{ .windowMs = 0 },
        };
    }
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    design_view.view(&model, &state, &canvas) catch {
        try err.writeAll("snapshot: cannot build console view\n");
        return 1;
    };
    saveFrame(io, allocator, &frame, path, backend_name) catch |save_error| {
        try err.print("snapshot: cannot write {s}: {s}\n", .{ path, @errorName(save_error) });
        return 1;
    };
    try out.print("{s}\n", .{path});
    return 0;
}

fn saveFrame(io: std.Io, allocator: std.mem.Allocator, frame: *frame_mod.Frame, path: []const u8, backend: []const u8) !void {
    if (std.mem.eql(u8, backend, "cpu")) return frame.savePng(io, path);
    if (!std.mem.eql(u8, backend, "metal")) return error.UnknownBackend;
    if (comptime builtin.os.tag != .macos) return error.BackendUnavailable;
    if (comptime builtin.os.tag == .macos) {
        const metal = @import("xsui-metal");
        var renderer = try metal.Renderer.init();
        defer renderer.deinit();
        const iface = renderer.interface();
        const bgra = try iface.readPixels(allocator, &frame.list, .{ .width = frame.width, .height = frame.height }, frame.theme.bg);
        defer allocator.free(bgra);
        const rgba = try allocator.alloc(u8, bgra.len);
        defer allocator.free(rgba);
        var i: usize = 0;
        while (i + 3 < bgra.len) : (i += 4) {
            rgba[i] = bgra[i + 2];
            rgba[i + 1] = bgra[i + 1];
            rgba[i + 2] = bgra[i];
            rgba[i + 3] = bgra[i + 3];
        }
        try saveRgba(io, path, frame.width, frame.height, rgba);
    }
}

fn saveRgba(io: std.Io, path: []const u8, width: u32, height: u32, rgba: []const u8) !void {
    const file = if (path.len != 0 and path[0] == '/')
        try std.Io.Dir.createFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try xsui.png.write(&writer.interface, width, height, rgba);
    try writer.interface.flush();
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
    var demo_model: ?[]const u8 = null;
    var recorder_dir: ?[]const u8 = null;
    var screen_name: []const u8 = "overview";
    var theme_name: []const u8 = "dark";
    var smoke = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--replay") and i + 1 < args.len) {
            i += 1;
            replay = args[i];
        } else if (std.mem.eql(u8, args[i], "--demo-model") and i + 1 < args.len) {
            i += 1;
            demo_model = args[i];
        } else if (std.mem.eql(u8, args[i], "--recorder-dir") and i + 1 < args.len) {
            i += 1;
            recorder_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--view") and i + 1 < args.len) {
            i += 1;
            screen_name = args[i];
        } else if (std.mem.eql(u8, args[i], "--theme") and i + 1 < args.len) {
            i += 1;
            theme_name = args[i];
        } else if (std.mem.eql(u8, args[i], "--smoke")) {
            smoke = true;
        }
    }
    const screen = design_state.parseScreen(screen_name) orelse {
        try err.writeAll("ui: unknown view\n");
        return 2;
    };
    const theme_index = xsui.themes.indexOf(theme_name) orelse 0;
    if (comptime builtin.os.tag == .linux) {
        const native = @import("../platform/linux/x11.zig");
        native.run(io, allocator, replay, demo_model, recorder_dir, @backingInt(screen), theme_index, smoke) catch |run_error| {
            try err.print("ui: {s}\n", .{@errorName(run_error)});
            return 1;
        };
        return 0;
    }
    if (comptime builtin.os.tag == .macos) {
        const native = @import("../platform/macos/window.zig");
        native.run(io, allocator, replay, demo_model, recorder_dir, @backingInt(screen), theme_index, smoke) catch |run_error| {
            try err.print("ui: {s}\n", .{@errorName(run_error)});
            return 1;
        };
        return 0;
    }
    try err.writeAll("ui: this build has no native window surface\n");
    return 2;
}

fn parseOverlay(name: []const u8) design_state.Dialog {
    if (std.mem.eql(u8, name, "palette")) return .palette;
    if (std.mem.eql(u8, name, "appearance") or std.mem.eql(u8, name, "theme")) return .appearance;
    if (std.mem.eql(u8, name, "help")) return .help;
    return .none;
}
