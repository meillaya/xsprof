//! Stable append-only event storage. Each parsed batch owns an arena, so
//! `comm`/`detail` slices never dangle when later batches arrive. Only complete
//! lines are parsed; a partial trailing line is retained.

const std = @import("std");
const event = @import("../core/event.zig");
const journal = @import("journal.zig");

const default_max_bytes = 256 * 1024 * 1024;

pub const AppendResult = struct {
    events: usize = 0,
    complete_bytes: usize = 0,
};

pub const Error = error{
    StoreFull,
    InvalidJournal,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    events: std.ArrayList(event.RawEvent) = .empty,
    pending: std.ArrayList(u8) = .empty,
    max_bytes: usize = default_max_bytes,
    stored_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.arenas.items) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        self.arenas.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    /// Append a chunk of NDJSON. Returns only after all complete lines in the
    /// chunk have been parsed and their events committed atomically.
    pub fn append(self: *Store, data: []const u8) !AppendResult {
        if (data.len == 0) return .{};
        try self.pending.appendSlice(self.allocator, data);
        if (self.stored_bytes + self.pending.items.len > self.max_bytes) {
            return error.StoreFull;
        }
        const newline = std.mem.lastIndexOfScalar(u8, self.pending.items, '\n') orelse
            return .{};
        const complete_len = newline + 1;
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        const complete = arena.allocator().dupe(u8, self.pending.items[0..complete_len]) catch |err| {
            arena.deinit();
            self.allocator.destroy(arena);
            return err;
        };

        const parsed = journal.parseData(arena.allocator(), complete) catch |err| {
            arena.deinit();
            self.allocator.destroy(arena);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidJournal,
            };
        };
        self.arenas.append(self.allocator, arena) catch |err| {
            arena.deinit();
            self.allocator.destroy(arena);
            return err;
        };
        self.events.appendSlice(self.allocator, parsed) catch |err| {
            _ = self.arenas.pop();
            arena.deinit();
            self.allocator.destroy(arena);
            return err;
        };
        self.stored_bytes += complete_len;

        const remaining = self.pending.items.len - complete_len;
        std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[complete_len..]);
        self.pending.shrinkRetainingCapacity(remaining);
        return .{ .events = self.events.items.len, .complete_bytes = complete_len };
    }

    pub fn eventCount(self: *const Store) usize {
        return self.events.items.len;
    }

    pub fn byteCount(self: *const Store) usize {
        return self.stored_bytes;
    }
};

// Checks that a split JSON line is held until its newline arrives, and that
// earlier event strings survive later appends.
test "store keeps partial lines and block-backed strings stable" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const first =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":1,\"cpu\":-1," ++
        "\"pid\":-1,\"tid\":-1,\"a\":0,\"b\":0,\"c\":0,\"detail\":\"one\",\"host_mutation\":false}\n";
    const second =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":2,\"cpu\":-1," ++
        "\"pid\":-1,\"tid\":-1,\"a\":0,\"b\":0,\"c\":0,\"detail\":\"two\",\"host_mutation\":false}\n";
    const split = second.len / 2;
    _ = try store.append(first[0 .. first.len - 1]);
    try std.testing.expectEqual(@as(usize, 0), store.eventCount());
    _ = try store.append(first[first.len - 1 ..]);
    try std.testing.expectEqual(@as(usize, 1), store.eventCount());
    _ = try store.append(second[0..split]);
    try std.testing.expectEqual(@as(usize, 1), store.eventCount());
    _ = try store.append(second[split..]);
    try std.testing.expectEqual(@as(usize, 2), store.eventCount());
    try std.testing.expectEqualStrings("one", store.events.items[0].detail);
    try std.testing.expectEqualStrings("two", store.events.items[1].detail);
}

// Checks that a mutation-bearing line is rejected without appending events.
test "store rejects mutation atomically" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const bad =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"host_mutation\":true}\n";
    try std.testing.expectError(error.InvalidJournal, store.append(bad));
    try std.testing.expectEqual(@as(usize, 0), store.eventCount());
}
