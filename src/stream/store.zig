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

    /// Append a chunk of NDJSON. Complete lines are parsed and the store is
    /// mutated only when the whole chunk is accepted, so a `StoreFull` or
    /// `InvalidJournal` error leaves events, stored bytes, and pending unchanged.
    /// A trailing partial line is held, bounded by the per-line parse limit.
    pub fn append(self: *Store, data: []const u8) !AppendResult {
        if (data.len == 0) return .{};
        const pending_len = self.pending.items.len;
        // Retained bytes after this append, matching the historical budget.
        if (self.stored_bytes + pending_len + data.len > self.max_bytes) {
            return error.StoreFull;
        }

        const last_newline = std.mem.lastIndexOfScalar(u8, data, '\n') orelse {
            // No complete line yet. Hold it, but never beyond one parseable line.
            if (pending_len + data.len > event.max_line_bytes) return error.InvalidJournal;
            try self.pending.appendSlice(self.allocator, data);
            return .{};
        };
        const trailing_len = data.len - (last_newline + 1);
        if (trailing_len > event.max_line_bytes) return error.InvalidJournal;
        const complete_len = pending_len + last_newline + 1;

        // Build and validate the candidate bytes in an arena first; `pending`
        // is not touched until every fallible step has succeeded.
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        var committed = false;
        defer {
            if (!committed) {
                arena.deinit();
                self.allocator.destroy(arena);
            }
        }
        const complete = try arena.allocator().alloc(u8, complete_len);
        @memcpy(complete[0..pending_len], self.pending.items);
        @memcpy(complete[pending_len..], data[0 .. last_newline + 1]);

        const parsed = journal.parseData(arena.allocator(), complete) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidJournal,
            };
        };
        // Reserve all capacity up front so the commit below cannot fail.
        try self.arenas.ensureUnusedCapacity(self.allocator, 1);
        try self.events.ensureUnusedCapacity(self.allocator, parsed.len);
        try self.pending.ensureTotalCapacity(self.allocator, trailing_len);

        self.arenas.appendAssumeCapacity(arena);
        self.events.appendSliceAssumeCapacity(parsed);
        self.stored_bytes += complete_len;
        self.pending.clearRetainingCapacity();
        self.pending.appendSliceAssumeCapacity(data[last_newline + 1 ..]);
        committed = true;
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

const valid_line =
    "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":7,\"cpu\":-1," ++
    "\"pid\":-1,\"tid\":-1,\"a\":0,\"b\":0,\"c\":0,\"detail\":\"atomic\",\"host_mutation\":false}\n";

// A refused append is all-or-nothing: stored events/bytes and the retained
// partial line stay exactly as they were, and a later healthy chunk recovers.
test "store full preserves counts and pending" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const split = 17;
    store.max_bytes = valid_line.len - 1;
    _ = try store.append(valid_line[0..split]);
    try std.testing.expectEqual(@as(usize, 0), store.byteCount());
    try std.testing.expectEqual(@as(usize, 0), store.eventCount());
    try std.testing.expectEqual(@as(usize, split), store.pending.items.len);
    try std.testing.expectError(error.StoreFull, store.append(valid_line[split..]));
    try std.testing.expectEqual(@as(usize, 0), store.byteCount());
    try std.testing.expectEqual(@as(usize, 0), store.eventCount());
    try std.testing.expectEqual(@as(usize, split), store.pending.items.len);
    try std.testing.expectEqualStrings(valid_line[0..split], store.pending.items);

    store.max_bytes = 4096;
    const result = try store.append(valid_line[split..]);
    try std.testing.expectEqual(@as(usize, 1), result.events);
    try std.testing.expectEqual(@as(usize, valid_line.len), result.complete_bytes);
    try std.testing.expectEqual(@as(usize, 1), store.eventCount());
    try std.testing.expectEqual(@as(usize, valid_line.len), store.byteCount());
    try std.testing.expectEqualStrings("atomic", store.events.items[0].detail);
    try std.testing.expectEqual(@as(usize, 0), store.pending.items.len);
}

// A corrupt complete line is refused without losing the already committed
// prefix or the pending partial line.
test "invalid journal preserves counts and pending" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const second =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":8,\"cpu\":-1," ++
        "\"pid\":-1,\"tid\":-1,\"a\":0,\"b\":0,\"c\":0,\"detail\":\"two\",\"host_mutation\":false}\n";
    const first_result = try store.append(valid_line);
    try std.testing.expectEqual(@as(usize, 1), first_result.events);
    const split = 23;
    _ = try store.append(second[0..split]);
    const pending_copy = try std.testing.allocator.dupe(u8, store.pending.items);
    defer std.testing.allocator.free(pending_copy);

    try std.testing.expectError(error.InvalidJournal, store.append("{\"schema\":\"nope\"}\n"));
    try std.testing.expectEqual(@as(usize, 1), store.eventCount());
    try std.testing.expectEqual(@as(usize, valid_line.len), store.byteCount());
    try std.testing.expectEqualStrings(pending_copy, store.pending.items);

    // The rejected bytes are gone, so the healthy remainder still commits.
    _ = try store.append(second[split..]);
    try std.testing.expectEqual(@as(usize, 2), store.eventCount());
    try std.testing.expectEqualStrings("two", store.events.items[1].detail);
    try std.testing.expectEqual(@as(usize, 0), store.pending.items.len);
}

// A newline-less stream must not grow `pending` without bound.
test "partial line is bounded by the parse line limit" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const oversized: [event.max_line_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidJournal, store.append(&oversized));
    try std.testing.expectEqual(@as(usize, 0), store.eventCount());
    try std.testing.expectEqual(@as(usize, 0), store.byteCount());
    try std.testing.expectEqual(@as(usize, 0), store.pending.items.len);
}
