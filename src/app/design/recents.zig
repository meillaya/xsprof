//! Bounded recent-source list persisted with the UI settings.

const std = @import("std");

pub const max_entries = 10;
pub const max_path = 512;
pub const max_label = 64;

pub const Kind = enum {
    demo,
    replay,
    recorder_window,
    live,

    pub fn tag(self: Kind) []const u8 {
        return switch (self) {
            .demo => "DEMO",
            .replay => "REPLAY",
            .recorder_window => "WINDOW",
            .live => "LIVE",
        };
    }
};

pub const Entry = struct {
    kind: Kind = .replay,
    path: [max_path]u8 = @splat(0),
    path_len: usize = 0,
    label: [max_label]u8 = @splat(0),
    label_len: usize = 0,
    window_ms: u64 = 0,
    wall_ns: u64 = 0,

    pub fn pathSlice(self: *const Entry) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn labelSlice(self: *const Entry) []const u8 {
        return self.label[0..self.label_len];
    }

    /// Basename for display/a11y; full path stays local-only.
    pub fn baseName(self: *const Entry) []const u8 {
        const path = self.pathSlice();
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| return path[slash + 1 ..];
        return path;
    }
};

pub const List = struct {
    items: [max_entries]Entry = @splat(Entry{}),
    len: usize = 0,

    pub fn clear(self: *List) void {
        self.len = 0;
        self.items = @splat(Entry{});
    }

    pub fn slice(self: *const List) []const Entry {
        return self.items[0..self.len];
    }

    /// Most-recent-first, deduplicated by (kind, path).
    pub fn add(self: *List, entry: Entry) void {
        if (entry.path_len == 0) return;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.items[i].kind == entry.kind and
                std.mem.eql(u8, self.items[i].pathSlice(), entry.pathSlice()))
            {
                _ = self.removeAt(i);
                break;
            }
        }
        const limit = @min(self.len, max_entries - 1);
        std.mem.copyBackwards(Entry, self.items[1 .. limit + 1], self.items[0..limit]);
        self.items[0] = entry;
        self.len = limit + 1;
    }

    pub fn removeAt(self: *List, index: usize) bool {
        if (index >= self.len) return false;
        std.mem.copyForwards(Entry, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
        self.len -= 1;
        self.items[self.len] = Entry{};
        return true;
    }

    pub fn get(self: *const List, index: usize) ?*const Entry {
        if (index >= self.len) return null;
        return &self.items[index];
    }
};

fn make(kind: Kind, path: []const u8, wall_ns: u64) Entry {
    var entry = Entry{ .kind = kind, .wall_ns = wall_ns };
    entry.path_len = @min(path.len, max_path);
    @memcpy(entry.path[0..entry.path_len], path[0..entry.path_len]);
    const base = entry.baseName();
    entry.label_len = @min(base.len, max_label);
    @memcpy(entry.label[0..entry.label_len], base[0..entry.label_len]);
    return entry;
}

test "recents dedupe, cap, and basename" {
    var list = List{};
    list.add(make(.replay, "/var/log/a.ndjson", 1));
    list.add(make(.replay, "/var/log/b.ndjson", 2));
    list.add(make(.replay, "/var/log/a.ndjson", 3));
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("a.ndjson", list.items[0].baseName());
    try std.testing.expectEqualStrings("/var/log/a.ndjson", list.items[0].pathSlice());
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/session-{d}.ndjson", .{i}) catch "x";
        list.add(make(.replay, path, i));
    }
    try std.testing.expectEqual(max_entries, list.len);
    try std.testing.expectEqualStrings("/tmp/session-19.ndjson", list.items[0].pathSlice());
    try std.testing.expect(list.removeAt(0));
    try std.testing.expectEqual(max_entries - 1, list.len);
    list.clear();
    try std.testing.expectEqual(@as(usize, 0), list.len);
}
