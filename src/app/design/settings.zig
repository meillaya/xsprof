//! UI settings: schema xsprof/ui-settings/v1, canonical compact JSON with
//! strictly ascending keys, bounded parse, and deterministic defaults.
//! Persistence (file writes) is a surface responsibility; this module is
//! pure so snapshot tests and reducers stay deterministic.

const std = @import("std");
const xsui = @import("xsui");
const recents = @import("recents.zig");
const source = @import("source.zig");
const text_input = @import("text_input.zig");

pub const schema = "xsprof/ui-settings/v1";
pub const version: u32 = 1;
pub const max_path = 512;

pub const Key = enum { reduced_motion, a11y_announce, a11y_tree, capture_enabled };

pub const Settings = struct {
    theme_index: usize = 0,
    reduced_motion: bool = false,
    a11y_announce: bool = true,
    a11y_tree: bool = true,
    capture_enabled: bool = false,
    onboarding_version: u32 = 0,
    last_source: source.Kind = .demo,
    recorder_dir: text_input.Input = .{},
    recorder_preset: u8 = 0,
    max_bytes: u64 = 2 * 1024 * 1024 * 1024,
    max_age_ms: u64 = 10 * 60 * 1000,
    history_interval_ms: u64 = 60 * 1000,
    history_retain_ms: u64 = 24 * 60 * 60 * 1000,
    recents: recents.List = .{},

    pub fn recorderDirSlice(self: *const Settings) []const u8 {
        return self.recorder_dir.slice();
    }

    pub fn setRecorderDir(self: *Settings, path: []const u8) void {
        self.recorder_dir.reset(path);
    }

    pub fn toggle(self: *Settings, key: Key) bool {
        const next = switch (key) {
            .reduced_motion => !self.reduced_motion,
            .a11y_announce => !self.a11y_announce,
            .a11y_tree => !self.a11y_tree,
            .capture_enabled => !self.capture_enabled,
        };
        switch (key) {
            .reduced_motion => self.reduced_motion = next,
            .a11y_announce => self.a11y_announce = next,
            .a11y_tree => self.a11y_tree = next,
            .capture_enabled => self.capture_enabled = next,
        }
        return next;
    }

    pub fn boolValue(self: *const Settings, key: Key) bool {
        return switch (key) {
            .reduced_motion => self.reduced_motion,
            .a11y_announce => self.a11y_announce,
            .a11y_tree => self.a11y_tree,
            .capture_enabled => self.capture_enabled,
        };
    }

    pub fn themeName(self: *const Settings) []const u8 {
        return xsui.themes.presets[self.theme_index % xsui.themes.presets.len].id;
    }
};

fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try w.print("\\u00{x:0>2}", .{byte});
                } else {
                    try w.writeByte(byte);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub fn writeJson(w: *std.Io.Writer, settings: *const Settings) !void {
    try w.writeAll("{\"a11y\":{\"announce\":");
    try w.writeAll(if (settings.a11y_announce) "true" else "false");
    try w.writeAll(",\"reduced_motion\":");
    try w.writeAll(if (settings.reduced_motion) "true" else "false");
    try w.writeAll(",\"tree\":");
    try w.writeAll(if (settings.a11y_tree) "true" else "false");
    try w.writeAll("},\"capture\":{\"enabled\":");
    try w.writeAll(if (settings.capture_enabled) "true" else "false");
    try w.writeAll("},\"host_mutation\":false,\"onboarding_version\":");
    try w.print("{d}", .{settings.onboarding_version});
    try w.writeAll(",\"recents\":[");
    for (settings.recents.slice(), 0..) |entry, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"kind\":");
        try writeString(w, @tagName(entry.kind));
        try w.writeAll(",\"label\":");
        try writeString(w, entry.labelSlice());
        try w.writeAll(",\"path\":");
        try writeString(w, entry.pathSlice());
        try w.writeAll(",\"wall_ns\":");
        try w.print("{d}", .{entry.wall_ns});
        try w.writeAll(",\"window_ms\":");
        try w.print("{d}", .{entry.window_ms});
        try w.writeByte('}');
    }
    try w.writeAll("],\"recorder\":{\"dir\":");
    try writeString(w, settings.recorderDirSlice());
    try w.writeAll(",\"history_interval_ms\":");
    try w.print("{d}", .{settings.history_interval_ms});
    try w.writeAll(",\"history_retain_ms\":");
    try w.print("{d}", .{settings.history_retain_ms});
    try w.writeAll(",\"max_age_ms\":");
    try w.print("{d}", .{settings.max_age_ms});
    try w.writeAll(",\"max_bytes\":");
    try w.print("{d}", .{settings.max_bytes});
    try w.writeAll(",\"preset\":");
    try writeString(w, presetName(settings.recorder_preset));
    try w.writeAll("},\"schema\":");
    try writeString(w, schema);
    try w.writeAll(",\"theme\":");
    try writeString(w, settings.themeName());
    try w.writeAll(",\"version\":");
    try w.print("{d}", .{version});
    try w.writeByte('}');
}

fn presetName(index: u8) []const u8 {
    return switch (index) {
        1 => "memory",
        2 => "deep",
        else => "scheduler",
    };
}

fn presetIndex(name: []const u8) u8 {
    if (std.ascii.eqlIgnoreCase(name, "memory")) return 1;
    if (std.ascii.eqlIgnoreCase(name, "deep")) return 2;
    return 0;
}

const A11yPayload = struct {
    announce: bool = true,
    reduced_motion: bool = false,
    tree: bool = true,
};

const CapturePayload = struct {
    enabled: bool = false,
};

const RecorderPayload = struct {
    dir: []const u8 = "",
    history_interval_ms: u64 = 60 * 1000,
    history_retain_ms: u64 = 24 * 60 * 60 * 1000,
    max_age_ms: u64 = 10 * 60 * 1000,
    max_bytes: u64 = 2 * 1024 * 1024 * 1024,
    preset: []const u8 = "scheduler",
};

const RecentPayload = struct {
    kind: []const u8 = "replay",
    label: []const u8 = "",
    path: []const u8 = "",
    wall_ns: u64 = 0,
    window_ms: u64 = 0,
};

const Payload = struct {
    a11y: ?A11yPayload = null,
    capture: ?CapturePayload = null,
    host_mutation: ?bool = null,
    onboarding_version: ?u32 = null,
    recents: ?[]const RecentPayload = null,
    recorder: ?RecorderPayload = null,
    schema: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    version: ?u32 = null,
};

pub const ParseError = error{ InvalidSettings, OutOfMemory };

pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!Settings {
    if (data.len == 0 or data.len > 64 * 1024) return error.InvalidSettings;
    const parsed = std.json.parseFromSliceLeaky(Payload, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidSettings;
    return fromPayload(parsed);
}

fn fromPayload(payload: Payload) ParseError!Settings {
    const schema_text = payload.schema orelse return error.InvalidSettings;
    if (!std.mem.eql(u8, schema_text, schema)) return error.InvalidSettings;
    if ((payload.version orelse version) > version) return error.InvalidSettings;
    if (payload.host_mutation orelse false) return error.InvalidSettings;

    var settings = Settings{};
    settings.reduced_motion = false;
    if (payload.a11y) |a11y| {
        settings.a11y_announce = a11y.announce;
        settings.a11y_tree = a11y.tree;
        settings.reduced_motion = a11y.reduced_motion;
    }
    if (payload.capture) |capture| settings.capture_enabled = capture.enabled;
    if (payload.onboarding_version) |value| settings.onboarding_version = value;
    if (payload.theme) |name| {
        if (xsui.themes.indexOf(name)) |index| {
            settings.theme_index = index;
        } else {
            return error.InvalidSettings;
        }
    }
    if (payload.recorder) |recorder| {
        if (recorder.dir.len > text_input.max_text) return error.InvalidSettings;
        settings.setRecorderDir(recorder.dir);
        settings.max_bytes = std.math.clamp(recorder.max_bytes, 64 * 1024 * 1024, 1024 * 1024 * 1024 * 1024);
        settings.max_age_ms = std.math.clamp(recorder.max_age_ms, 1000, 24 * 60 * 60 * 1000);
        settings.history_interval_ms = std.math.clamp(recorder.history_interval_ms, 1000, 60 * 60 * 1000);
        settings.history_retain_ms = std.math.clamp(recorder.history_retain_ms, 60 * 1000, 365 * 24 * 60 * 60 * 1000);
        settings.recorder_preset = presetIndex(recorder.preset);
    }
    if (payload.recents) |entries| {
        if (entries.len > recents.max_entries) return error.InvalidSettings;
        // Oldest-last order is preserved; newest written first.
        var i = entries.len;
        while (i > 0) {
            i -= 1;
            const entry = entries[i];
            if (entry.path.len > recents.max_path) return error.InvalidSettings;
            if (entry.label.len > recents.max_label) return error.InvalidSettings;
            var kind: recents.Kind = .replay;
            inline for (@typeInfo(recents.Kind).@"enum".field_names) |field| {
                if (std.ascii.eqlIgnoreCase(entry.kind, field)) kind = @field(recents.Kind, field);
            }
            var item = recents.Entry{ .kind = kind, .window_ms = entry.window_ms, .wall_ns = entry.wall_ns };
            item.path_len = entry.path.len;
            @memcpy(item.path[0..item.path_len], entry.path);
            item.label_len = entry.label.len;
            @memcpy(item.label[0..item.label_len], entry.label);
            settings.recents.add(item);
        }
    }
    return settings;
}

test "settings round-trip through canonical json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var settings = Settings{ .theme_index = 1, .reduced_motion = true, .capture_enabled = true };
    settings.setRecorderDir("/var/lib/xsprof");
    var entry = recents.Entry{ .kind = .replay, .wall_ns = 42, .window_ms = 60000 };
    entry.path_len = "/tmp/a.ndjson".len;
    @memcpy(entry.path[0..entry.path_len], "/tmp/a.ndjson");
    entry.label_len = "a.ndjson".len;
    @memcpy(entry.label[0..entry.label_len], "a.ndjson");
    settings.recents.add(entry);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJson(&writer, &settings);
    const text = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"a11y\":"));
    const parsed = try parse(arena.allocator(), text);
    try std.testing.expectEqual(@as(usize, 1), parsed.theme_index);
    try std.testing.expect(parsed.reduced_motion);
    try std.testing.expect(parsed.capture_enabled);
    try std.testing.expectEqualStrings("/var/lib/xsprof", parsed.recorderDirSlice());
    try std.testing.expectEqual(@as(usize, 1), parsed.recents.len);
    try std.testing.expectEqualStrings("/tmp/a.ndjson", parsed.recents.items[0].pathSlice());
}

test "settings rejects wrong schema and mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidSettings, parse(arena.allocator(), "{}"));
    try std.testing.expectError(error.InvalidSettings, parse(arena.allocator(), "{\"host_mutation\":true,\"schema\":\"xsprof/ui-settings/v1\",\"version\":1}"));
    try std.testing.expectError(error.InvalidSettings, parse(arena.allocator(), "not json"));
}
