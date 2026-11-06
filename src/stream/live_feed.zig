//! Thread-safe bounded NDJSON store for live capture. The capture worker
//! appends; the console drains snapshots. The store never mutates the host.

const std = @import("std");

const SpinMutex = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinMutex) void {
        while (self.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.locked.store(false, .release);
    }
};

pub const Store = struct {
    mutex: SpinMutex = .{},
    bytes: std.ArrayList(u8) = .empty,
    base: u64 = 0,
    max_bytes: usize = 8 * 1024 * 1024,

    pub fn init() Store {
        return .{};
    }

    pub fn deinit(self: *Store) void {
        self.bytes.deinit(std.heap.smp_allocator);
    }

    pub fn append(self: *Store, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (data.len >= self.max_bytes) {
            const tail = data[data.len - self.max_bytes ..];
            const newline = std.mem.indexOfScalar(u8, tail, '\n');
            const keep = if (newline) |at| tail[at + 1 ..] else tail[tail.len..];
            self.bytes.clearRetainingCapacity();
            self.base += data.len - keep.len;
            self.bytes.appendSlice(std.heap.smp_allocator, keep) catch return;
            return;
        }
        // Trim in one coarse step to half full. Dropping only the exact
        // overflow per event is O(store bytes) per append once the store is
        // full; during a tail catch-up that stalls stop for many seconds.
        if (self.bytes.items.len + data.len > self.max_bytes) {
            const target_keep = self.max_bytes / 2;
            if (self.bytes.items.len > target_keep) {
                const cut = self.bytes.items.len - target_keep;
                const newline = std.mem.indexOfScalarPos(u8, self.bytes.items, cut, '\n');
                const drop = if (newline) |at| at + 1 else self.bytes.items.len;
                const keep = self.bytes.items.len - drop;
                std.mem.copyForwards(u8, self.bytes.items[0..keep], self.bytes.items[drop..]);
                self.bytes.shrinkRetainingCapacity(keep);
                self.base += drop;
            }
        }
        self.bytes.appendSlice(std.heap.smp_allocator, data) catch {};
    }

    pub fn endOffset(self: *Store) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.base + self.bytes.items.len;
    }

    pub const Snapshot = struct {
        data: []u8,
        start: u64,
        end: u64,
        reset: bool,
    };

    pub fn since(
        self: *Store,
        allocator: std.mem.Allocator,
        offset: u64,
    ) !Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const end = self.base + self.bytes.items.len;
        const reset = offset < self.base;
        const start = if (reset) self.base else @min(offset, end);
        const from: usize = @intCast(start - self.base);
        const data = try allocator.dupe(u8, self.bytes.items[from..]);
        return .{ .data = data, .start = start, .end = end, .reset = reset };
    }

    pub fn snapshot(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        const snap = try self.since(allocator, self.base);
        return snap.data;
    }
};

test "live store bounds and offsets" {
    var store = Store.init();
    defer store.deinit();
    store.append("one\n");
    store.append("two\n");
    try std.testing.expectEqual(@as(u64, 8), store.endOffset());
    const snap = try store.since(std.testing.allocator, 0);
    defer std.testing.allocator.free(snap.data);
    try std.testing.expectEqualStrings("one\ntwo\n", snap.data);
    try std.testing.expect(!snap.reset);
    const later = try store.since(std.testing.allocator, 4);
    defer std.testing.allocator.free(later.data);
    try std.testing.expectEqualStrings("two\n", later.data);
}

test "oversized append keeps a complete trailing line" {
    var store = Store.init();
    defer store.deinit();
    store.max_bytes = 6;
    store.append("aa\nbb\ncc\n");
    const snap = try store.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("cc\n", snap);
    try std.testing.expectEqual(@as(u64, 9), store.endOffset());
}

test "full store trims in a coarse step instead of per event" {
    var store = Store.init();
    defer store.deinit();
    store.max_bytes = 100;
    var index: usize = 0;
    while (index < 60) : (index += 1) store.append("line\n");
    const snap = try store.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expect(snap.len <= store.max_bytes);
    try std.testing.expect(std.mem.endsWith(u8, snap, "\n"));
    try std.testing.expect(store.endOffset() == 300);
}
