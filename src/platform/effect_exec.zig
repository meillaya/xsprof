//! Portable platform effect executor for the native console surfaces.
//!
//! The design console never touches host IO itself: it queues
//! `effect.Effect` items (bounded) and the surface either executes them or
//! records a fail-closed refusal/audit entry. This module owns the portable
//! execution half (source loads, GPU picker listings, exports, settings
//! persistence); live capture is delegated to a platform `LiveBridge` because
//! it needs `capture/lab_worker` and the `live.Controller` poll loop.
//!
//! Integration hook (app.zig is owned by ui-arch): the shell should call
//! `App.applyLiveModel(session, model, selection)` when the platform live
//! controller reports `changed`; until that exists the platform keeps the
//! recorder state/counters and view-only status honest and reports the hook.

const std = @import("std");
const console_app = @import("../app/design/app.zig");
const effect = @import("../app/design/effect.zig");
const source = @import("../app/design/source.zig");
const recorder = @import("../app/design/recorder.zig");
const picker = @import("../app/design/picker.zig");
const audit_mod = @import("../app/design/audit.zig");
const state_paths = @import("state_paths.zig");
const export_writer = @import("export_writer.zig");
const incident_bundle = @import("../incident/bundle.zig");
const recorder_verify = @import("../recorder/verify.zig");
const session_mod = @import("../stream/session.zig");

pub const max_listing = picker.max_entries;
pub const default_window_ms: u64 = 5 * 60 * 1000;

/// Live-capture bridge implemented by the platform app (Linux only; macOS has
/// no perf_event_open and fails closed before reaching this).
pub const LiveBridge = struct {
    ctx: *anyopaque,
    start: *const fn (ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator, options: recorder.Options) bool,
    stop: *const fn (ctx: *anyopaque) void,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app: *console_app.App,
    live: ?LiveBridge = null,
};

pub fn execute(ctx: *Context, item: effect.Effect) void {
    switch (item) {
        .none, .notify, .copy_text, .refusal, .append_audit, .open_journal, .reload_source => {},
        .load_path => |request| loadPath(ctx, request),
        .load_demo => loadDemo(ctx),
        .list_dir => |request| listDir(ctx, request),
        .start_capture => |options| startCapture(ctx, options),
        .stop_capture => stopCapture(ctx),
        .extract_window => |request| extractWindow(ctx, request.last_ms),
        .export_file => |request| exportFile(ctx, request.kind, request.path[0..request.path_len]),
        .export_audit => exportAudit(ctx),
        .save_settings => saveSettings(ctx),
        .verify_recorder => verifyRecorder(ctx),
    }
}

/// Consumed by the platform loop when `App.open_requested` is set: native uses
/// the GPU picker, never an OS file dialog.
pub fn openJournal(ctx: *Context) void {
    if (!effect.supports(ctx.app.surface, .list_dir)) {
        refuse(ctx, .list_dir, "source.open");
        return;
    }
    ctx.app.state.dialog = .picker;
    ctx.app.state.focus_return = ctx.app.state.focus_id;
    ctx.app.state.picker.open(.file, .replay_file);
    ctx.app.state.picker.phase = .loading;
    ctx.app.state.focus_visible = true;
    var request = effect.ListRequest{ .mode = .file, .purpose = .replay_file };
    request.mode = ctx.app.state.picker.mode;
    request.purpose = ctx.app.state.picker.purpose;
    listDir(ctx, request);
}

/// Consumed when `App.reload_requested` is set: reload the current source kind.
pub fn reloadSource(ctx: *Context) void {
    const kind = ctx.app.state.source.kind orelse {
        loadDemo(ctx);
        return;
    };
    switch (kind) {
        .demo => loadDemo(ctx),
        .replay => {
            const path = ctx.app.state.source.pathSlice();
            if (path.len == 0) {
                failSource(ctx, .failed, "source.reload.failed", "no replay path is loaded");
                return;
            }
            ctx.app.loadReplay(ctx.io, path) catch |err| {
                failSource(ctx, .failed, "source.reload.failed", @errorName(err));
                return;
            };
            ctx.app.recordAudit("source.reload", .ok, "REPLAY");
        },
        .recorder_window => extractWindow(ctx, ctx.app.state.source.window.lastMs() orelse 0),
        .live => {
            const bridge = ctx.live orelse {
                refuse(ctx, .live_capture, "source.reload");
                return;
            };
            bridge.stop(bridge.ctx);
            const options = ctx.app.state.recorder.options;
            if (!bridge.start(bridge.ctx, ctx.io, ctx.allocator, options)) return;
            ctx.app.setLive(true);
            ctx.app.recorderStarted("live capture");
            ctx.app.recordAudit("source.reload", .ok, "LIVE");
        },
    }
}

fn loadPath(ctx: *Context, request: effect.LoadRequest) void {
    switch (request.kind) {
        .demo => loadDemo(ctx),
        .live => startCapture(ctx, liveOptions(ctx)),
        .replay => {
            const path = request.pathSlice();
            if (path.len == 0) {
                failSource(ctx, .refused, "source.load.refused", "no replay path was selected");
                return;
            }
            ctx.app.state.source.beginLoad(.replay, path);
            ctx.app.loadReplay(ctx.io, path) catch |err| {
                failSource(ctx, .failed, "source.load.failed", @errorName(err));
                return;
            };
            ctx.app.recordAudit("source.load", .ok, "REPLAY");
        },
        .recorder_window => loadRecorderWindow(ctx, request.pathSlice(), request.window_ms),
    }
}

fn loadDemo(ctx: *Context) void {
    const fixture = state_paths.demoFixture(ctx.io, ctx.allocator) catch {
        failSource(ctx, .skipped, "source.demo.missing", "bundled capture fixture is not installed beside the binary");
        return;
    };
    defer ctx.allocator.free(fixture);
    ctx.app.state.source.beginLoad(.demo, fixture);
    ctx.app.loadDemo(ctx.io, fixture) catch |err| {
        failSource(ctx, .failed, "source.demo.failed", @errorName(err));
        return;
    };
    ctx.app.recordAudit("source.load", .ok, "DEMO");
}

fn liveOptions(ctx: *Context) recorder.Options {
    const window_ms = ctx.app.state.source.window.lastMs() orelse default_window_ms;
    const clamped: u32 = @intCast(std.math.clamp(window_ms, 1000, 600_000));
    return .{ .duration_ms = clamped, .preset = presetFromSettings(ctx.app.state.settings.recorder_preset) };
}

fn presetFromSettings(index: u8) recorder.Preset {
    return switch (index) {
        1 => .memory,
        2 => .deep,
        else => .scheduler,
    };
}

fn loadRecorderWindow(ctx: *Context, requested_dir: []const u8, last_ms: u64) void {
    var owned: ?[]u8 = null;
    defer if (owned) |value| ctx.allocator.free(value);
    const dir = if (requested_dir.len != 0)
        requested_dir
    else if (ctx.app.state.settings.recorderDirSlice().len != 0)
        ctx.app.state.settings.recorderDirSlice()
    else blk: {
        owned = state_paths.recorderFallbackDir(ctx.allocator) catch {
            failSource(ctx, .refused, "source.window.refused", "no recorder state directory is configured");
            return;
        };
        break :blk owned.?;
    };
    const window_ms = if (last_ms == 0) default_window_ms else std.math.clamp(last_ms, 1000, 3600 * 1000);
    ctx.app.state.source.beginLoad(.recorder_window, dir);
    ctx.app.loadRecorderWindow(ctx.io, dir, window_ms) catch |err| {
        failSource(ctx, .failed, "source.window.failed", @errorName(err));
        return;
    };
    ctx.app.recordAudit("source.window", .ok, "WINDOW");
}

fn extractWindow(ctx: *Context, last_ms: u64) void {
    if (!effect.supports(ctx.app.surface, .recorder_control)) {
        refuse(ctx, .recorder_control, "source.window");
        return;
    }
    loadRecorderWindow(ctx, ctx.app.state.settings.recorderDirSlice(), last_ms);
}

fn startCapture(ctx: *Context, options: recorder.Options) void {
    if (!effect.supports(ctx.app.surface, .recorder_control)) {
        refuse(ctx, .recorder_control, "capture.start");
        return;
    }
    const bridge = ctx.live orelse {
        failAction(ctx, "capture.start", "surface.recorder.unsupported", "live capture is not attached on this surface");
        return;
    };
    if (!bridge.start(bridge.ctx, ctx.io, ctx.allocator, options)) return;
    ctx.app.recordAudit("capture.start", .ok, "live");
}

fn stopCapture(ctx: *Context) void {
    const bridge = ctx.live orelse {
        failAction(ctx, "capture.stop", "surface.recorder.unsupported", "no live capture is attached");
        return;
    };
    bridge.stop(bridge.ctx);
    ctx.app.recorderStopped();
    ctx.app.recordAudit("capture.stop", .ok, "live");
}

fn exportFile(ctx: *Context, kind: effect.ExportKind, requested_dir: []const u8) void {
    if (!effect.supports(ctx.app.surface, .write_file)) {
        refuse(ctx, .write_file, "export");
        return;
    }
    const dir = state_paths.exportDir(ctx.allocator, requested_dir) catch |err| {
        const failure = if (err == error.UnsafeExportPath)
            export_writer.failFor(error.UnsafeExportPath)
        else
            export_writer.failFor(error.CreateFailed);
        ctx.app.showToast(failure.reason, true);
        ctx.app.recordAudit("export", .refused, failure.code);
        return;
    };
    defer ctx.allocator.free(dir);
    if (kind == .incident) {
        exportIncident(ctx, dir);
        return;
    }
    const session_ptr: ?*const session_mod.Session = if (ctx.app.session) |*loaded| loaded else null;
    const name = export_writer.writeExport(ctx.io, ctx.allocator, dir, kind, session_ptr) catch |err| {
        const failure = export_writer.failFor(err);
        ctx.app.showToast(failure.reason, true);
        ctx.app.recordAudit("export", .refused, failure.code);
        return;
    };
    defer ctx.allocator.free(name);
    var buffer: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "exported {s}", .{name}) catch "exported";
    ctx.app.showToast(message, false);
    ctx.app.recordAudit("export", .ok, kind.label());
}

fn exportIncident(ctx: *Context, export_dir: []const u8) void {
    const recorder_dir = if (ctx.app.state.settings.recorderDirSlice().len != 0)
        ctx.app.state.settings.recorderDirSlice()
    else
        state_paths.recorderFallbackDir(ctx.allocator) catch {
            failAction(ctx, "export.incident", "export.incident.no_recorder", "no recorder state directory is configured");
            return;
        };
    const owned_recorder = recorder_dir.ptr != ctx.app.state.settings.recorderDirSlice().ptr;
    defer if (owned_recorder) ctx.allocator.free(recorder_dir);
    const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, ctx.io).nanoseconds)));
    const out = std.fmt.allocPrint(ctx.allocator, "{s}/xsprof-incident-{d}", .{ export_dir, now }) catch {
        failAction(ctx, "export.incident", "export.incident.path", "could not shape the incident output path");
        return;
    };
    defer ctx.allocator.free(out);
    std.Io.Dir.cwd().createDirPath(ctx.io, out) catch {
        failAction(ctx, "export.incident", "export.incident.create_failed", "could not create the incident folder");
        return;
    };
    const last_ms = ctx.app.state.source.window.lastMs() orelse 10 * 60 * 1000;
    _ = incident_bundle.write(ctx.io, ctx.allocator, .{
        .dir = recorder_dir,
        .out = out,
        .last_ms = last_ms,
        .max_window_bytes = 4 * 1024 * 1024 * 1024,
    }) catch |err| {
        const reason = switch (err) {
            error.NoRecorder => "the recorder has no manifest to bundle",
            error.NoWindow => "the requested incident window is empty",
            else => @errorName(err),
        };
        failAction(ctx, "export.incident", "export.incident.failed", reason);
        return;
    };
    ctx.app.recordAudit("export.incident", .ok, "incident");
    ctx.app.showToast("incident bundle exported", false);
}

fn verifyRecorder(ctx: *Context) void {
    const recorder_dir = if (ctx.app.state.settings.recorderDirSlice().len != 0)
        ctx.app.state.settings.recorderDirSlice()
    else
        state_paths.recorderFallbackDir(ctx.allocator) catch {
            failAction(ctx, "audit.verify", "verify.no_recorder", "no recorder state directory is configured");
            return;
        };
    const owned = recorder_dir.ptr != ctx.app.state.settings.recorderDirSlice().ptr;
    defer if (owned) ctx.allocator.free(recorder_dir);
    const report = recorder_verify.run(ctx.io, ctx.allocator, .{ .dir = recorder_dir }) catch |err| {
        failAction(ctx, "audit.verify", "verify.failed", @errorName(err));
        return;
    };
    var buf: [192]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "verify {s}: {d} clean, {d} dirty, {d} corrupt, {d} missing", .{
        report.state,
        report.clean,
        report.dirty,
        report.corrupt,
        report.missing,
    }) catch "verify complete";
    ctx.app.showToast(message, !std.mem.eql(u8, report.state, "READY"));
    ctx.app.recordAudit("audit.verify", if (std.mem.eql(u8, report.state, "READY")) .ok else .failed, report.state);
}

fn exportAudit(ctx: *Context) void {
    if (!effect.supports(ctx.app.surface, .write_file)) {
        refuse(ctx, .write_file, "audit.export");
        return;
    }
    const name = export_writer.writeAudit(ctx.io, ctx.allocator, &ctx.app.state.audit) catch |err| {
        failAction(ctx, "audit.export", "export.write_failed", export_writer.failFor(err).reason);
        return;
    };
    defer ctx.allocator.free(name);
    ctx.app.recordAudit("audit.export", .ok, "audit.ndjson");
    ctx.app.showToast("audit log exported", false);
}

fn saveSettings(ctx: *Context) void {
    if (!effect.supports(ctx.app.surface, .persist_settings)) {
        refuse(ctx, .persist_settings, "settings.save");
        return;
    }
    const data = ctx.app.settingsJson(ctx.allocator) catch {
        failAction(ctx, "settings.save", "settings.encode_failed", "settings could not be encoded");
        return;
    };
    defer ctx.allocator.free(data);
    state_paths.saveSettings(ctx.io, ctx.allocator, data) catch |err| {
        failAction(ctx, "settings.save", "settings.write_failed", @errorName(err));
        return;
    };
    ctx.app.recordAudit("settings.save", .ok, "");
    ctx.app.showToast("settings saved", false);
}

fn refuse(ctx: *Context, capability: effect.Capability, action: []const u8) void {
    const refusal = effect.refusalFor(ctx.app.surface, capability);
    ctx.app.showToast(refusal.reason, true);
    ctx.app.recordAudit(action, .refused, refusal.code);
}

fn failSource(ctx: *Context, phase: source.Phase, action: []const u8, reason: []const u8) void {
    ctx.app.noteSourceFailure(phase, reason);
    ctx.app.showToast(reason, true);
    ctx.app.recordAudit(action, .failed, reason);
}

fn failAction(ctx: *Context, action: []const u8, code: []const u8, reason: []const u8) void {
    ctx.app.showToast(reason, true);
    ctx.app.recordAudit(action, .failed, code);
}

// --- bounded GPU picker listing -------------------------------------------

fn resolveListPath(ctx: *Context, request: effect.ListRequest, buffer: *[512]u8) []const u8 {
    const requested = request.pathSlice();
    if (requested.len != 0) {
        const len = @min(requested.len, buffer.len);
        @memcpy(buffer[0..len], requested[0..len]);
        return buffer[0..len];
    }
    if (request.purpose == .recorder_dir) {
        const configured = ctx.app.state.settings.recorderDirSlice();
        if (configured.len != 0) {
            const len = @min(configured.len, buffer.len);
            @memcpy(buffer[0..len], configured[0..len]);
            return buffer[0..len];
        }
    }
    const fallback = state_paths.stateDir(ctx.allocator) catch {
        @memcpy(buffer[0..1], ".");
        return buffer[0..1];
    };
    defer ctx.allocator.free(fallback);
    const len = @min(fallback.len, buffer.len);
    @memcpy(buffer[0..len], fallback[0..len]);
    return buffer[0..len];
}

fn listDir(ctx: *Context, request: effect.ListRequest) void {
    if (!effect.supports(ctx.app.surface, .list_dir)) {
        refuse(ctx, .list_dir, "picker.list");
        return;
    }
    var path_buffer: [512]u8 = @splat(0);
    const path = resolveListPath(ctx, request, &path_buffer);
    var dir = if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openDirAbsolute(ctx.io, path, .{ .iterate = true }) catch |err| {
            return listingFailed(ctx, path, err);
        }
    else
        std.Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true }) catch |err| {
            return listingFailed(ctx, path, err);
        };
    defer dir.close(ctx.io);
    var entries: [max_listing]picker.Entry = @splat(.{});
    var count: usize = 0;
    var iterator = dir.iterate();
    while (iterator.next(ctx.io) catch null) |entry| {
        if (count >= max_listing) break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        var item = picker.Entry{ .is_dir = entry.kind == .directory };
        const len = @min(entry.name.len, picker.max_name);
        @memcpy(item.name[0..len], entry.name[0..len]);
        item.name_len = len;
        entries[count] = item;
        count += 1;
    }
    sortEntries(entries[0..count]);
    ctx.app.state.picker.mode = request.mode;
    ctx.app.state.picker.purpose = request.purpose;
    ctx.app.state.picker.setCwd(path);
    ctx.app.state.picker.setListing(entries[0..count]);
    ctx.app.state.picker.phase = .browsing;
    ctx.app.recordAudit("picker.list", .ok, "dir");
}

fn listingFailed(ctx: *Context, path: []const u8, err: anyerror) void {
    _ = path;
    ctx.app.state.picker.setError(@errorName(err));
    ctx.app.showToast("cannot list this directory", true);
    ctx.app.recordAudit("picker.list", .failed, @errorName(err));
}

fn sortEntries(entries: []picker.Entry) void {
    var index: usize = 1;
    while (index < entries.len) : (index += 1) {
        const item = entries[index];
        var at = index;
        while (at > 0) {
            const previous = entries[at - 1];
            if (!entryBefore(item, previous)) break;
            entries[at] = previous;
            at -= 1;
        }
        entries[at] = item;
    }
}

fn entryBefore(a: picker.Entry, b: picker.Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.mem.order(u8, a.nameSlice(), b.nameSlice()) == .lt;
}

test "effect executor keeps stable refusal surfaces" {
    try std.testing.expect(!effect.supports(.web, .list_dir));
    try std.testing.expect(effect.supports(.linux, .write_file));
    try std.testing.expect(!effect.supports(.macos, .recorder_control));
    try std.testing.expectEqualStrings("source.demo.missing", "source.demo.missing");
}
