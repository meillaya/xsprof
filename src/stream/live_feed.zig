//! Bounded decoded-event handoff between the live recorder tail and the
//! console. The tail decodes compact `.xsraw` blocks straight into `Batch`
//! values whose `comm`/`detail` strings live in a per-batch arena; the console
//! adopts each batch into `stream/store`, which keeps the arena alive for as
//! long as the index references those strings. No NDJSON is produced, parsed,
//! or buffered on this path.
//!
//! Threading: one producer (the tail thread) pushes finished batches, one
//! consumer (the UI thread) pops them. The queue mutex only guards the batch
//! list; batch arenas are owned by exactly one side at a time.
//!
//! Trim policy (the single explicit policy for the live feed): a batch that
//! alone exceeds a bound is dropped, otherwise the oldest batches are evicted
//! until the new one fits. Evicted events are accumulated in `takeDropped`, so
//! the consumer emits exactly one `feed_trim` loss marker per drain and no
//! bytes are ever silently forgotten.

const std = @import("std");
const event = @import("../core/event.zig");
const Io = std.Io;

/// One decoded batch: events plus the arena that owns their strings. Created by
/// the producer, consumed by either `Store.commitBatch` (adopts the arena) or
/// `deinit` (discards everything).
pub const Batch = struct {
    allocator: std.mem.Allocator,
    /// Heap-stable arena pointer: the address never changes after `create`, so
    /// allocators handed out by `allocator()` stay valid when the store adopts
    /// the batch.
    arena: *std.heap.ArenaAllocator,
    events: std.ArrayList(event.RawEvent) = .empty,

    pub fn create(allocator: std.mem.Allocator) !*Batch {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const batch = try allocator.create(Batch);
        batch.* = .{ .allocator = allocator, .arena = arena };
        return batch;
    }

    /// Free the batch and its arena. Not valid after `release`.
    pub fn deinit(self: *Batch) void {
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        allocator.destroy(self);
    }

    /// Free only the batch handle after another owner adopted the arena and the
    /// event slice (see `stream/store.commitBatch`).
    pub fn release(self: *Batch) void {
        self.allocator.destroy(self);
    }

    pub fn count(self: *const Batch) usize {
        return self.events.items.len;
    }

    /// Accounted bytes: everything the arena holds plus the batch handle. The
    /// store budget charges this, so `max_bytes` tracks real memory rather than
    /// wire size.
    pub fn byteSize(self: *const Batch) usize {
        return self.arena.queryCapacity() + @sizeOf(Batch);
    }

    /// Copy one decoded event into the arena. The source strings may point into
    /// a reusable decode buffer (the compact reader), so they are never
    /// borrowed past the caller's next `next()` call.
    pub fn push(self: *Batch, entry: event.RawEvent) !void {
        var copy = entry;
        if (entry.comm.len != 0) copy.comm = try self.arena.allocator().dupe(u8, entry.comm);
        if (entry.detail.len != 0) copy.detail = try self.arena.allocator().dupe(u8, entry.detail);
        try self.events.append(self.arena.allocator(), copy);
    }

    /// Append an event whose strings are already owned by this batch's arena
    /// (legacy NDJSON parsed at the boundary, synthesized markers).
    pub fn pushOwned(self: *Batch, entry: event.RawEvent) !void {
        try self.events.append(self.arena.allocator(), entry);
    }

    /// Synthesize one loss marker with a message owned by the batch arena.
    pub fn pushMarker(self: *Batch, ts_ns: u64, detail: []const u8) !void {
        const owned = try self.arena.allocator().dupe(u8, detail);
        try self.events.append(self.arena.allocator(), .{
            .kind = .marker,
            .ts_ns = ts_ns,
            .cpu = -1,
            .detail = owned,
        });
    }
};

pub const Dropped = struct {
    events: u64 = 0,
    batches: u64 = 0,
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    batches: std.ArrayList(*Batch) = .empty,
    /// Bounds on handed-off (not yet consumed) events. One of these tripping is
    /// a trim: the oldest complete batches are evicted, never partial events.
    max_bytes: usize = 8 * 1024 * 1024,
    max_batches: usize = 64,
    max_events: usize = 256 * 1024,
    bytes: usize = 0,
    events: usize = 0,
    dropped_events: u64 = 0,
    dropped_batches: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: Io) Queue {
        return .{ .allocator = allocator, .io = io };
    }

    /// Frees every batch still queued. Only call after the producer stopped.
    pub fn deinit(self: *Queue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.batches.items) |batch| batch.deinit();
        self.batches.deinit(self.allocator);
    }

    pub fn eventCount(self: *Queue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.events;
    }

    pub fn byteCount(self: *Queue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.bytes;
    }

    /// Hand over a finished batch. Never fails and always takes ownership: the
    /// queue either adopts the batch, evicts older batches to make room, or
    /// discards this one when it cannot fit at all. Every discarded event is
    /// counted for `takeDropped`.
    pub fn push(self: *Queue, batch: *Batch) void {
        const batch_bytes = batch.byteSize();
        const batch_events = batch.count();
        // Evicted batches are destroyed after the lock is released so arenas
        // never free child allocations inside the critical section.
        var evicted: std.ArrayList(*Batch) = .empty;
        defer {
            for (evicted.items) |old| old.deinit();
            evicted.deinit(self.allocator);
        }
        self.mutex.lockUncancelable(self.io);
        const drop_new = batch_events == 0 or
            batch_bytes > self.max_bytes or
            batch_events > self.max_events;
        if (!drop_new) {
            while (self.batches.items.len >= self.max_batches or
                self.bytes + batch_bytes > self.max_bytes or
                self.events + batch_events > self.max_events)
            {
                const oldest = self.batches.orderedRemove(0);
                self.bytes -= oldest.byteSize();
                self.events -= oldest.count();
                self.dropped_events +|= oldest.count();
                self.dropped_batches +|= 1;
                evicted.append(self.allocator, oldest) catch oldest.deinit();
            }
        }
        if (drop_new) {
            if (batch_events != 0) {
                self.dropped_events +|= batch_events;
                self.dropped_batches +|= 1;
            }
        } else {
            self.batches.append(self.allocator, batch) catch {
                self.dropped_events +|= batch_events;
                self.dropped_batches +|= 1;
                self.mutex.unlock(self.io);
                batch.deinit();
                return;
            };
            self.bytes += batch_bytes;
            self.events += batch_events;
        }
        self.mutex.unlock(self.io);
        if (drop_new) batch.deinit();
    }

    /// Oldest batch for the consumer, or null. The caller owns the batch and
    /// must call `deinit` or hand it to `Store.commitBatch`.
    pub fn pop(self: *Queue) ?*Batch {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.batches.items.len == 0) return null;
        const batch = self.batches.orderedRemove(0);
        self.bytes -= batch.byteSize();
        self.events -= batch.count();
        return batch;
    }

    /// Trim/gap loss observed since the previous call. The consumer turns this
    /// into loss markers and resets the counters by reading them.
    pub fn takeDropped(self: *Queue) Dropped {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const dropped = Dropped{
            .events = self.dropped_events,
            .batches = self.dropped_batches,
        };
        self.dropped_events = 0;
        self.dropped_batches = 0;
        return dropped;
    }
};

test "batch copies strings into its arena and survives the source" {
    var source = [_]u8{ 'w', 'o', 'r', 'k', 'e', 'r' };
    const batch = try Batch.create(std.testing.allocator);
    defer batch.deinit();
    try batch.push(.{ .ts_ns = 1, .comm = &source });
    try batch.pushMarker(2, "sample_loss live_follow dropped=1 corrupt_segment");
    source[0] = 'X';
    try std.testing.expectEqual(@as(usize, 2), batch.count());
    try std.testing.expectEqualStrings("worker", batch.events.items[0].comm);
    try std.testing.expectEqual(event.Kind.marker, batch.events.items[1].kind);
    try std.testing.expectEqual(@as(i32, -1), batch.events.items[1].cpu);
    try std.testing.expect(std.mem.indexOf(u8, batch.events.items[1].detail, "corrupt_segment") != null);
}

test "queue hands batches over in order and accounts memory" {
    var queue = Queue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();
    const first = try Batch.create(std.testing.allocator);
    try first.push(.{ .ts_ns = 1 });
    const second = try Batch.create(std.testing.allocator);
    try second.push(.{ .ts_ns = 2 });
    queue.push(first);
    queue.push(second);
    try std.testing.expectEqual(@as(usize, 2), queue.eventCount());
    try std.testing.expect(queue.byteCount() > 0);
    const got_first = queue.pop() orelse return error.TestUnexpectedResult;
    defer got_first.deinit();
    try std.testing.expectEqual(@as(u64, 1), got_first.events.items[0].ts_ns);
    const got_second = queue.pop() orelse return error.TestUnexpectedResult;
    defer got_second.deinit();
    try std.testing.expectEqual(@as(u64, 2), got_second.events.items[0].ts_ns);
    try std.testing.expect(queue.pop() == null);
    try std.testing.expectEqual(@as(usize, 0), queue.eventCount());
}

test "queue trims oldest batches and reports dropped events once" {
    var queue = Queue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();
    queue.max_batches = 2;
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        const batch = try Batch.create(std.testing.allocator);
        try batch.push(.{ .ts_ns = @intCast(index) });
        try batch.push(.{ .ts_ns = @intCast(index) });
        queue.push(batch);
    }
    // Only the two newest batches survive (four events); the older two were
    // evicted whole and report two events each.
    try std.testing.expectEqual(@as(usize, 4), queue.eventCount());
    const dropped = queue.takeDropped();
    try std.testing.expectEqual(@as(u64, 4), dropped.events);
    try std.testing.expectEqual(@as(u64, 2), dropped.batches);
    try std.testing.expectEqual(@as(u64, 0), queue.takeDropped().events);
    const kept = queue.pop() orelse return error.TestUnexpectedResult;
    defer kept.deinit();
    try std.testing.expectEqual(@as(u64, 2), kept.events.items[0].ts_ns);
}

test "queue drops a single batch larger than the budget" {
    var queue = Queue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();
    queue.max_bytes = 32;
    const batch = try Batch.create(std.testing.allocator);
    try batch.push(.{ .kind = .sched_switch, .ts_ns = 1, .cpu = 0, .pid = 7, .tid = 7, .a = 7, .comm = "worker" });
    queue.push(batch);
    try std.testing.expectEqual(@as(usize, 0), queue.eventCount());
    try std.testing.expectEqual(@as(u64, 1), queue.takeDropped().events);
}

test "empty batches are discarded without reporting loss" {
    var queue = Queue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();
    const batch = try Batch.create(std.testing.allocator);
    queue.push(batch);
    try std.testing.expectEqual(@as(usize, 0), queue.eventCount());
    try std.testing.expectEqual(@as(u64, 0), queue.takeDropped().events);
}
