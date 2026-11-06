//! GPU-native file/directory picker model. Listing is performed by the host
//! surface (Effect.list_dir); this module owns selection, filtering, scroll,
//! bounds, and error/loading states so the overlay is fully deterministic.

const std = @import("std");
const text_input = @import("text_input.zig");

pub const max_entries = 128;
pub const max_name = 96;
pub const max_path = 512;
pub const max_reason = 160;
pub const visible_rows = 9;

pub const Mode = enum { file, directory };
pub const Purpose = enum { replay_file, recorder_dir };

pub const Entry = struct {
    name: [max_name]u8 = @splat(0),
    name_len: usize = 0,
    is_dir: bool = false,

    pub fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Phase = enum { browsing, loading, error_state };

pub const State = struct {
    active: bool = false,
    mode: Mode = .file,
    purpose: Purpose = .replay_file,
    phase: Phase = .browsing,
    cwd: [max_path]u8 = @splat(0),
    cwd_len: usize = 0,
    entries: [max_entries]Entry = @splat(Entry{}),
    len: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,
    filter: text_input.Input = .{},
    reason: [max_reason]u8 = @splat(0),
    reason_len: usize = 0,

    pub fn cwdSlice(self: *const State) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    pub fn reasonSlice(self: *const State) []const u8 {
        return self.reason[0..self.reason_len];
    }

    pub fn open(self: *State, mode: Mode, purpose: Purpose) void {
        self.active = true;
        self.mode = mode;
        self.purpose = purpose;
        self.phase = .loading;
        self.len = 0;
        self.selected = 0;
        self.scroll = 0;
        self.filter.clear();
        self.reason_len = 0;
        if (self.cwd_len == 0) self.setCwd(if (purpose == .recorder_dir) "/var/lib/xsprof" else ".");
    }

    pub fn close(self: *State) void {
        self.active = false;
        self.phase = .browsing;
        self.reason_len = 0;
    }

    pub fn setCwd(self: *State, path: []const u8) void {
        self.cwd_len = @min(path.len, self.cwd.len);
        @memcpy(self.cwd[0..self.cwd_len], path[0..self.cwd_len]);
    }

    /// Host completion: replace the listing. Entries beyond capacity are
    /// dropped explicitly through the bounded array.
    pub fn setListing(self: *State, entries: []const Entry) void {
        self.len = @min(entries.len, max_entries);
        var i: usize = 0;
        while (i < self.len) : (i += 1) self.entries[i] = entries[i];
        self.phase = .browsing;
        self.reason_len = 0;
        self.clamp();
    }

    pub fn setError(self: *State, reason: []const u8) void {
        self.phase = .error_state;
        self.reason_len = @min(reason.len, self.reason.len);
        @memcpy(self.reason[0..self.reason_len], reason[0..self.reason_len]);
        self.len = 0;
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn empty(self: *State) void {
        self.len = 0;
        self.selected = 0;
        self.scroll = 0;
        self.phase = .browsing;
    }

    pub fn move(self: *State, delta: i32) void {
        if (self.len == 0) return;
        const current: i64 = @intCast(self.selected);
        var next = current + delta;
        if (next < 0) next = @as(i64, @intCast(self.len)) - 1;
        if (next >= @as(i64, @intCast(self.len))) next = 0;
        self.selected = @intCast(next);
        self.clamp();
    }

    pub fn selectedEntry(self: *const State) ?Entry {
        if (self.selected >= self.len) return null;
        return self.entries[self.selected];
    }

    /// Parent directory of cwd (root clamps to itself).
    pub fn parentPath(self: *const State, out: []u8) []const u8 {
        const path = self.cwdSlice();
        if (path.len == 0 or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, ".")) {
            return std.fmt.bufPrint(out, "{s}", .{path}) catch path;
        }
        var end = path.len - 1;
        while (end > 0 and path[end] == '/') end -= 1;
        while (end > 0 and path[end] != '/') end -= 1;
        const parent = if (end == 0) "/" else path[0..end];
        return std.fmt.bufPrint(out, "{s}", .{parent}) catch path;
    }

    pub fn joinPath(self: *const State, name: []const u8, out: []u8) []const u8 {
        const cwd = self.cwdSlice();
        if (cwd.len == 0 or std.mem.eql(u8, cwd, ".")) {
            return std.fmt.bufPrint(out, "{s}", .{name}) catch name;
        }
        if (std.mem.eql(u8, cwd, "/")) {
            return std.fmt.bufPrint(out, "/{s}", .{name}) catch name;
        }
        return std.fmt.bufPrint(out, "{s}/{s}", .{ cwd, name }) catch name;
    }

    fn clamp(self: *State) void {
        if (self.len == 0) {
            self.selected = 0;
            self.scroll = 0;
            return;
        }
        if (self.selected >= self.len) self.selected = self.len - 1;
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + visible_rows) self.scroll = self.selected - visible_rows + 1;
        if (self.scroll + visible_rows > self.len) self.scroll = if (self.len > visible_rows) self.len - visible_rows else 0;
    }
};

fn entry(name: []const u8, is_dir: bool) Entry {
    var e = Entry{ .is_dir = is_dir };
    e.name_len = @min(name.len, max_name);
    @memcpy(e.name[0..e.name_len], name[0..e.name_len]);
    return e;
}

test "picker bounds selection and scroll" {
    var state = State{};
    state.open(.file, .replay_file);
    var many: [20]Entry = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var buf: [32]u8 = undefined;
        many[i] = entry(std.fmt.bufPrint(&buf, "file-{d}.ndjson", .{i}) catch "x", false);
    }
    state.setListing(&many);
    try std.testing.expectEqual(@as(usize, 20), state.len);
    state.move(-1);
    try std.testing.expectEqual(@as(usize, 19), state.selected);
    state.move(1);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    state.move(10);
    try std.testing.expectEqual(@as(usize, 10), state.selected);
    try std.testing.expect(state.scroll + visible_rows > state.selected);
    state.setError("permission denied");
    try std.testing.expectEqual(Phase.error_state, state.phase);
    try std.testing.expectEqualStrings("permission denied", state.reasonSlice());
}

test "picker joins paths and climbs to parent" {
    var state = State{};
    state.setCwd("/tmp/xsprof");
    var out: [768]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/xsprof/a.ndjson", state.joinPath("a.ndjson", &out));
    try std.testing.expectEqualStrings("/tmp", state.parentPath(&out));
    state.setCwd("/");
    try std.testing.expectEqualStrings("/", state.parentPath(&out));
    try std.testing.expectEqualStrings("/a", state.joinPath("a", &out));
    state.setCwd(".");
    try std.testing.expectEqualStrings("a.ndjson", state.joinPath("a.ndjson", &out));
}
