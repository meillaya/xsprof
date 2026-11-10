const std = @import("std");
const xsui = @import("xsui");
const builtin = @import("builtin");
const frame_mod = xsui.frame;
const session_mod = @import("../stream/session.zig");
const design_model = @import("../app/design/model.zig");
const design_state = @import("../app/design/state.zig");
const design_view = @import("../app/design/view.zig");
const design_picker = @import("../app/design/picker.zig");
const native_options = @import("../platform/options.zig");

const design_derive = @import("../app/design/derive.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;

pub fn cmdSnapshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
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
    var a11y_path: ?[]const u8 = null;
    var settings_mode: []const u8 = "none";
    var now_ms: u64 = 0;
    var focus_id: ?u32 = null;
    var onboarding_step: ?u8 = null;
    var picker_dir: ?[]const u8 = null;
    var palette_query: ?[]const u8 = null;
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
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--height") and i + 1 < args.len) {
            i += 1;
            height = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("snapshot: invalid --height\n");
                return .usage;
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
        } else if (std.mem.eql(u8, arg, "--a11y") and i + 1 < args.len) {
            i += 1;
            a11y_path = args[i];
        } else if (std.mem.eql(u8, arg, "--settings") and i + 1 < args.len) {
            i += 1;
            settings_mode = args[i];
        } else if (std.mem.eql(u8, arg, "--now") and i + 1 < args.len) {
            i += 1;
            now_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                try err.writeAll("snapshot: invalid --now\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--focus") and i + 1 < args.len) {
            i += 1;
            focus_id = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("snapshot: invalid --focus id\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--onboarding-step") and i + 1 < args.len) {
            i += 1;
            onboarding_step = std.fmt.parseInt(u8, args[i], 10) catch {
                try err.writeAll("snapshot: invalid --onboarding-step\n");
                return .usage;
            };
            if (onboarding_step.? > 3) {
                try err.writeAll("snapshot: --onboarding-step must be 0..3\n");
                return .usage;
            }
        } else if (std.mem.eql(u8, arg, "--picker-dir") and i + 1 < args.len) {
            i += 1;
            picker_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--palette-query") and i + 1 < args.len) {
            i += 1;
            palette_query = args[i];
        }
    }
    if (!std.mem.eql(u8, settings_mode, "none")) {
        try err.writeAll("snapshot: never reads user settings; only --settings none is accepted\n");
        return .usage;
    }
    if (width < 64 or height < 64 or width > 4096 or height > 4096) {
        try err.writeAll("snapshot: width/height must be 64..4096\n");
        return .usage;
    }
    const theme_index = xsui.themes.indexOf(theme_name) orelse 0;
    var frame: frame_mod.Frame = undefined;
    frame.init(allocator, width, height, xsui.themes.presets[theme_index].theme) catch {
        try err.writeAll("snapshot: cannot initialize UI frame\n");
        return .refuse;
    };
    defer frame.deinit();
    if (demo_model) |model_path| {
        const model = design_model.loadDemo(io, allocator, model_path) catch |load_error| {
            try err.print("snapshot: cannot load demo model {s}: {s}\n", .{ model_path, @errorName(load_error) });
            return .refuse;
        };
        const screen = design_state.parseScreen(screen_name) orelse {
            try err.print("snapshot: unknown view {s}\n", .{screen_name});
            return .usage;
        };
        var state = design_state.State{ .screen = screen, .theme_index = theme_index, .timeline_playhead = playhead_s * 1000.0 };
        state.now_ms = now_ms;
        if (!applyOverlay(&state, overlay_name)) {
            try err.print("snapshot: unknown overlay {s}\n", .{overlay_name});
            return .usage;
        }
        applySnapshotExtras(&state, io, focus_id, onboarding_step, picker_dir, palette_query) catch |extras_error| {
            try err.print("snapshot: cannot apply snapshot extras: {s}\n", .{@errorName(extras_error)});
            return .refuse;
        };
        var canvas = xsui.Canvas.init(&frame);
        defer canvas.deinit();
        design_view.view(&model, &state, &canvas) catch {
            try err.writeAll("snapshot: cannot build console view\n");
            return .refuse;
        };
        if (a11y_path) |a11y_file| {
            writeA11y(io, allocator, a11y_file, &state, &canvas) catch |a11y_error| {
                try err.print("snapshot: cannot write a11y tree {s}: {s}\n", .{ a11y_file, @errorName(a11y_error) });
                return .refuse;
            };
        }
        saveFrame(io, allocator, &frame, path, backend_name) catch |save_error| {
            try err.print("snapshot: cannot write {s}: {s}\n", .{ path, @errorName(save_error) });
            return .refuse;
        };
        try out.print("{s}\n", .{path});
        return .ok;
    }
    const screen = design_state.parseScreen(screen_name) orelse {
        try err.print("snapshot: unknown view {s}\n", .{screen_name});
        return .usage;
    };
    var state = design_state.State{ .screen = screen, .theme_index = theme_index, .timeline_playhead = playhead_s * 1000.0 };
    state.now_ms = now_ms;
    if (!applyOverlay(&state, overlay_name)) {
        try err.print("snapshot: unknown overlay {s}\n", .{overlay_name});
        return .usage;
    }
    applySnapshotExtras(&state, io, focus_id, onboarding_step, picker_dir, palette_query) catch |extras_error| {
        try err.print("snapshot: cannot apply snapshot extras: {s}\n", .{@errorName(extras_error)});
        return .refuse;
    };
    var model: design_model.Model = undefined;
    if (replay) |journal_path| {
        const session = session_mod.Session.load(io, allocator, journal_path) catch |load_error| {
            try err.print("snapshot: cannot load {s}: {s}\n", .{ journal_path, @errorName(load_error) });
            return .refuse;
        };
        model = design_derive.fromSession(allocator, &session, .{
            .fixture = journal_path,
            .source = "REPLAY",
        }) catch |derive_error| {
            try err.print("snapshot: cannot derive console model: {s}\n", .{@errorName(derive_error)});
            return .refuse;
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
        return .refuse;
    };
    if (a11y_path) |a11y_file| {
        writeA11y(io, allocator, a11y_file, &state, &canvas) catch |a11y_error| {
            try err.print("snapshot: cannot write a11y tree {s}: {s}\n", .{ a11y_file, @errorName(a11y_error) });
            return .refuse;
        };
    }
    saveFrame(io, allocator, &frame, path, backend_name) catch |save_error| {
        try err.print("snapshot: cannot write {s}: {s}\n", .{ path, @errorName(save_error) });
        return .refuse;
    };
    try out.print("{s}\n", .{path});
    return .ok;
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
) !Exit {
    _ = out;
    var replay: ?[]const u8 = null;
    var demo_model: ?[]const u8 = null;
    var recorder_dir: ?[]const u8 = null;
    var screen_name: []const u8 = "home";
    var theme_name: []const u8 = "dark";
    var smoke = false;
    var width: u32 = native_options.default_width;
    var height: u32 = native_options.default_height;
    var resize: ?native_options.Size = null;
    var a11y = false;
    var live = false;
    var duration_ms: u32 = 0;
    var preset_name: []const u8 = "scheduler";
    var follow_recorder: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, args[i], "--width") and i + 1 < args.len) {
            i += 1;
            width = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("ui: invalid --width\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, args[i], "--height") and i + 1 < args.len) {
            i += 1;
            height = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("ui: invalid --height\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, args[i], "--resize") and i + 1 < args.len) {
            i += 1;
            resize = native_options.parseSize(args[i]) orelse {
                try err.writeAll("ui: invalid --resize (expected WxH, e.g. 900x600)\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, args[i], "--a11y")) {
            a11y = true;
        } else if (std.mem.eql(u8, args[i], "--live")) {
            live = true;
        } else if (std.mem.eql(u8, args[i], "--duration") and i + 1 < args.len) {
            i += 1;
            duration_ms = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("ui: invalid --duration\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, args[i], "--preset") and i + 1 < args.len) {
            i += 1;
            preset_name = args[i];
        } else if (std.mem.eql(u8, args[i], "--follow-recorder") and i + 1 < args.len) {
            i += 1;
            follow_recorder = args[i];
        } else {
            try err.print("ui: unknown option {s}\n", .{args[i]});
            return .usage;
        }
    }
    if (width < native_options.min_width or height < native_options.min_height) {
        try err.print("ui: window must be at least {d}x{d}\n", .{
            native_options.min_width,
            native_options.min_height,
        });
        return .usage;
    }
    if (live and follow_recorder != null) {
        try err.writeAll("ui: --live and --follow-recorder are mutually exclusive\n");
        return .usage;
    }
    const screen = design_state.parseScreen(screen_name) orelse {
        try err.writeAll("ui: unknown view\n");
        return .usage;
    };
    const theme_index = xsui.themes.indexOf(theme_name) orelse 0;
    const native_opts = native_options.Options{
        .replay = replay,
        .demo_model = demo_model,
        .recorder_dir = recorder_dir,
        .screen = @backingInt(screen),
        .theme_index = theme_index,
        .smoke = smoke,
        .width = width,
        .height = height,
        .resize = resize,
        .a11y = a11y,
        .live = live,
        .duration_ms = duration_ms,
        .preset = preset_name,
        .follow_recorder = follow_recorder,
    };
    if (comptime builtin.os.tag == .linux) {
        const native = @import("../platform/linux/x11.zig");
        native.run(io, allocator, native_opts) catch |run_error| {
            try err.print("ui: {s}\n", .{@errorName(run_error)});
            return .refuse;
        };
        return .ok;
    }
    if (comptime builtin.os.tag == .macos) {
        const native = @import("../platform/macos/window.zig");
        native.run(io, allocator, native_opts) catch |run_error| {
            try err.print("ui: {s}\n", .{@errorName(run_error)});
            return .refuse;
        };
        return .ok;
    }
    try err.writeAll("ui: this build has no native window surface\n");
    return .usage;
}

/// Applies a deterministic snapshot overlay. The state is built directly from
/// flags here: snapshots never read user settings or persisted onboarding state.
fn applyOverlay(state: *design_state.State, name: []const u8) bool {
    if (std.mem.eql(u8, name, "none")) return true;
    if (std.mem.eql(u8, name, "palette")) {
        state.dialog = .palette;
        return true;
    }
    if (std.mem.eql(u8, name, "appearance") or std.mem.eql(u8, name, "theme")) {
        state.dialog = .appearance;
        return true;
    }
    if (std.mem.eql(u8, name, "help")) {
        state.dialog = .help;
        return true;
    }
    if (std.mem.eql(u8, name, "onboarding")) {
        state.dialog = .onboarding;
        state.onboarding.active = true;
        return true;
    }
    if (std.mem.eql(u8, name, "picker")) {
        state.dialog = .picker;
        state.picker.open(.file, .replay_file);
        state.picker.phase = .browsing;
        return true;
    }
    if (std.mem.eql(u8, name, "confirm")) {
        state.dialog = .confirm;
        state.confirm_pending = .stop_capture;
        return true;
    }
    return false;
}

/// Extra deterministic snapshot state used by the native showcase renderer:
/// keyboard focus ring, onboarding step, and a real bounded directory listing
/// for the GPU picker. Never reads user settings.
fn applySnapshotExtras(
    state: *design_state.State,
    io: std.Io,
    focus_id: ?u32,
    onboarding_step: ?u8,
    picker_dir: ?[]const u8,
    palette_query: ?[]const u8,
) !void {
    if (focus_id) |id| {
        state.focus_id = id;
        state.focus_visible = true;
    }
    if (onboarding_step) |step| {
        state.dialog = .onboarding;
        state.onboarding.active = true;
        state.onboarding.step = switch (step) {
            0 => .welcome,
            1 => .read_only,
            2 => .capabilities,
            else => .source,
        };
    }
    if (picker_dir) |dir| {
        state.dialog = .picker;
        state.picker.open(.file, .replay_file);
        state.picker.phase = .browsing;
        try loadPickerDir(state, io, dir);
    }
    if (palette_query) |query| {
        state.dialog = .palette;
        state.palette_input.reset(query);
        state.palette_index = 0;
    }
}

fn loadPickerDir(state: *design_state.State, io: std.Io, dir: []const u8) !void {
    var opened = if (dir.len != 0 and dir[0] == '/')
        try std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer opened.close(io);
    var entries: [design_picker.max_entries]design_picker.Entry = @splat(.{});
    var count: usize = 0;
    var iterator = opened.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (count >= design_picker.max_entries) break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        var item = design_picker.Entry{ .is_dir = entry.kind == .directory };
        const len = @min(entry.name.len, design_picker.max_name);
        @memcpy(item.name[0..len], entry.name[0..len]);
        item.name_len = len;
        entries[count] = item;
        count += 1;
    }
    sortPickerEntries(entries[0..count]);
    state.picker.setCwd(dir);
    state.picker.setListing(entries[0..count]);
    state.picker.phase = .browsing;
}

fn sortPickerEntries(entries: []design_picker.Entry) void {
    var index: usize = 1;
    while (index < entries.len) : (index += 1) {
        const item = entries[index];
        var at = index;
        while (at > 0) {
            const previous = entries[at - 1];
            if (!pickerEntryBefore(item, previous)) break;
            entries[at] = previous;
            at -= 1;
        }
        entries[at] = item;
    }
}

fn pickerEntryBefore(a: design_picker.Entry, b: design_picker.Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.mem.order(u8, a.nameSlice(), b.nameSlice()) == .lt;
}

/// Canonical a11y tree for `--a11y FILE`: built from the same canvas
/// semantic registration pass that painted the snapshot frame, using the one
/// shared xsui tree/writer the native bridges consume.
fn writeA11y(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    state: *const design_state.State,
    canvas: *const xsui.Canvas,
) !void {
    var tree = try xsui.A11yTree.build(allocator, canvas, state.focus_id);
    defer tree.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try tree.writeJson(&out.writer);
    const data = try out.toOwnedSlice();
    defer allocator.free(data);
    const file = if (path.len != 0 and path[0] == '/')
        try std.Io.Dir.createFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}
