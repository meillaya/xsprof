//! Surface capabilities, refusal reasons, and the bounded effect queue.
//!
//! The design console never performs host IO itself: reducers update state and
//! push effects. Each surface drains the queue and either executes an effect or
//! records a fail-closed refusal with a stable code + human reason.

const std = @import("std");
const source = @import("source.zig");
const recorder = @import("recorder.zig");
const picker = @import("picker.zig");
const audit = @import("audit.zig");

pub const Surface = enum { snapshot, web, macos, linux };

pub const Capability = enum {
    load_file,
    list_dir,
    live_capture,
    recorder_control,
    persist_settings,
    write_file,
    clipboard_write,
    serve_loopback,
    a11y_tree,
};

pub fn supports(surface: Surface, capability: Capability) bool {
    return switch (surface) {
        .snapshot => capability == .a11y_tree,
        .web => switch (capability) {
            .load_file, .persist_settings, .clipboard_write, .a11y_tree => true,
            else => false,
        },
        .macos => switch (capability) {
            .load_file, .list_dir, .persist_settings, .write_file, .clipboard_write, .serve_loopback, .a11y_tree => true,
            else => false,
        },
        .linux => switch (capability) {
            .live_capture, .write_file => true,
            else => true,
        },
    };
}

pub const Refusal = struct {
    code: []const u8,
    reason: []const u8,
};

/// Stable, privacy-safe refusal used when a surface cannot perform an action.
pub fn refusalFor(surface: Surface, capability: Capability) Refusal {
    return switch (capability) {
        .list_dir => .{
            .code = "surface.list_dir.unsupported",
            .reason = if (surface == .web)
                "web cannot browse the host filesystem; upload a journal instead"
            else
                "this surface cannot list directories; pass a path instead",
        },
        .live_capture => .{
            .code = "surface.live.unsupported",
            .reason = "live capture needs a Linux host with perf_event_open READY; use xsprof serve --live from a recorder host",
        },
        .recorder_control => .{
            .code = "surface.recorder.unsupported",
            .reason = "recorder control is native-Linux only; manage the recorder on the host",
        },
        .write_file => .{
            .code = "surface.write.unsupported",
            .reason = "this surface cannot write host files; exports are unavailable",
        },
        .persist_settings => .{
            .code = "surface.settings.unsupported",
            .reason = "this surface cannot persist settings; changes apply for this session only",
        },
        .clipboard_write => .{
            .code = "surface.clipboard.unsupported",
            .reason = "this surface has no clipboard; copy is unavailable",
        },
        .load_file => .{
            .code = "surface.load.unsupported",
            .reason = "this surface cannot load a source; pass --replay or --demo-model",
        },
        .serve_loopback => .{
            .code = "surface.serve.unsupported",
            .reason = "loopback serving is available from the native console only",
        },
        .a11y_tree => .{
            .code = "surface.a11y.unsupported",
            .reason = "this surface has no accessibility bridge",
        },
    };
}

pub const ExportKind = enum {
    journal,
    trace,
    report,
    incident,

    pub fn label(self: ExportKind) []const u8 {
        return switch (self) {
            .journal => "journal.ndjson",
            .trace => "trace.json",
            .report => "report.html",
            .incident => "incident bundle",
        };
    }
};

pub const max_path = 512;
pub const max_text = 160;

pub const Text = struct {
    buf: [max_text]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Text, text: []const u8) void {
        self.len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..self.len], text[0..self.len]);
    }
};

pub const LoadRequest = struct {
    kind: source.Kind = .replay,
    path: [max_path]u8 = @splat(0),
    path_len: usize = 0,
    window_ms: u64 = 0,

    pub fn pathSlice(self: *const LoadRequest) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn setPath(self: *LoadRequest, path: []const u8) void {
        self.path_len = @min(path.len, self.path.len);
        @memcpy(self.path[0..self.path_len], path[0..self.path_len]);
    }
};

pub const ListRequest = struct {
    path: [max_path]u8 = @splat(0),
    path_len: usize = 0,
    mode: picker.Mode = .file,
    purpose: picker.Purpose = .replay_file,

    pub fn pathSlice(self: *const ListRequest) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const Effect = union(enum) {
    none,
    load_path: LoadRequest,
    load_demo,
    list_dir: ListRequest,
    start_capture: recorder.Options,
    stop_capture,
    extract_window: struct { last_ms: u64 },
    export_file: struct {
        kind: ExportKind,
        path: [max_path]u8 = @splat(0),
        path_len: usize = 0,
    },
    save_settings,
    verify_recorder,
    export_audit,
    append_audit: audit.Entry,
    copy_text: Text,
    notify: struct { text: Text, is_error: bool = false },
    refusal: Refusal,
    open_journal,
    reload_source,
};

pub const max_effects = 8;

pub const Batch = struct {
    items: [max_effects]Effect = @splat(.none),
    len: u8 = 0,
    overflow: bool = false,

    pub fn add(self: *Batch, effect: Effect) void {
        if (self.len >= max_effects) {
            self.overflow = true;
            return;
        }
        self.items[self.len] = effect;
        self.len += 1;
    }

    pub fn slice(self: *const Batch) []const Effect {
        return self.items[0..self.len];
    }

    pub fn notify(self: *Batch, text: []const u8, is_error: bool) void {
        var t = Text{};
        t.set(text);
        self.add(.{ .notify = .{ .text = t, .is_error = is_error } });
    }

    pub fn refuse(self: *Batch, code: []const u8, reason: []const u8) void {
        self.add(.{ .refusal = .{ .code = code, .reason = reason } });
    }
};

test "effect batches are bounded" {
    var batch = Batch{};
    var i: usize = 0;
    while (i < max_effects + 3) : (i += 1) batch.add(.save_settings);
    try std.testing.expectEqual(@as(u8, max_effects), batch.len);
    try std.testing.expect(batch.overflow);
}

test "capability matrix matches surface reality" {
    try std.testing.expect(supports(.linux, .recorder_control));
    try std.testing.expect(supports(.linux, .live_capture));
    try std.testing.expect(!supports(.macos, .live_capture));
    try std.testing.expect(!supports(.web, .recorder_control));
    try std.testing.expect(!supports(.web, .list_dir));
    try std.testing.expect(supports(.web, .load_file));
    try std.testing.expect(supports(.snapshot, .a11y_tree));
    try std.testing.expect(!supports(.snapshot, .write_file));
    try std.testing.expectEqualStrings("surface.recorder.unsupported", refusalFor(.web, .recorder_control).code);
    try std.testing.expectEqualStrings("surface.list_dir.unsupported", refusalFor(.web, .list_dir).code);
}
