//! Transactional source ownership for the GUI lab. One active Session is kept
//! stable on the heap; loading a new source never leaves the view pointing at
//! freed memory.

const std = @import("std");
const session_mod = @import("../../stream/session.zig");
const extract = @import("../../recorder/extract.zig");

pub const SourceStore = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    session: ?*session_mod.Session = null,

    pub fn init(allocator: std.mem.Allocator) SourceStore {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *SourceStore) void {
        self.clear();
        self.arena.deinit();
    }

    pub fn current(self: *const SourceStore) ?*const session_mod.Session {
        return if (self.session) |session| session else null;
    }

    pub fn clear(self: *SourceStore) void {
        if (self.session) |session| self.allocator.destroy(session);
        self.session = null;
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn loadReplay(
        self: *SourceStore,
        io: std.Io,
        path: []const u8,
    ) !*const session_mod.Session {
        var next = std.heap.ArenaAllocator.init(self.allocator);
        errdefer next.deinit();
        const source = try next.allocator().dupe(u8, path);
        const loaded = try session_mod.Session.load(io, next.allocator(), source);
        return self.install(next, loaded);
    }

    pub fn loadRecorder(
        self: *SourceStore,
        io: std.Io,
        dir: []const u8,
        window_ms: u64,
    ) !*const session_mod.Session {
        var next = std.heap.ArenaAllocator.init(self.allocator);
        errdefer next.deinit();
        const data = try extract.extract(io, next.allocator(), .{
            .dir = dir,
            .last_ms = window_ms,
        });
        const source = try std.fmt.allocPrint(next.allocator(), "{s} window={d}ms", .{ dir, window_ms });
        const loaded = try session_mod.Session.fromData(next.allocator(), source, data);
        return self.install(next, loaded);
    }

    /// Only replaces the visible session after the new one has loaded. A
    /// failed load leaves the previous session and its view pointer intact.
    fn install(
        self: *SourceStore,
        next: std.heap.ArenaAllocator,
        loaded: session_mod.Session,
    ) !*const session_mod.Session {
        const session = try self.allocator.create(session_mod.Session);
        session.* = loaded;
        self.clear();
        self.arena.deinit();
        self.arena = next;
        self.session = session;
        return session;
    }
};

test "source store replaces sessions and fails closed" {
    var store = SourceStore.init(std.testing.allocator);
    defer store.deinit();

    const session = try store.loadReplay(std.testing.io, "fixtures/ui/healthy.ndjson");
    try std.testing.expect(session.events.len > 1000);
    try std.testing.expect(store.current() == session);

    try std.testing.expectError(
        error.JournalUnreadable,
        store.loadReplay(std.testing.io, "fixtures/ui/does-not-exist.ndjson"),
    );
    try std.testing.expect(store.current() == session);
}
