//! Combined event filters. A filter can constrain a task name, a pid, an event
//! kind, and loss/refusal rows at the same time; every predicate is optional.

const std = @import("std");
const event = @import("../core/event.zig");
const session_mod = @import("../stream/session.zig");
const input_mod = @import("../ui/input.zig");

pub const Filter = struct {
    comm: ?[]const u8 = null,
    pid: ?i32 = null,
    kind: ?event.Kind = null,
    loss_only: bool = false,

    pub fn active(self: Filter) bool {
        return self.comm != null or self.pid != null or self.kind != null or self.loss_only;
    }

    pub fn clear(self: *Filter) void {
        self.* = .{};
    }

    pub fn isLoss(entry: event.RawEvent) bool {
        if (entry.kind == .refusal or entry.kind == .incident) return true;
        if (entry.kind != .marker) return false;
        return std.mem.indexOf(u8, entry.detail, "sample_loss") != null or
            std.mem.indexOf(u8, entry.detail, "lost") != null;
    }

    pub fn matchesEvent(self: Filter, entry: event.RawEvent) bool {
        if (self.comm) |comm| {
            if (comm.len == 0 or !std.mem.eql(u8, entry.comm, comm)) return false;
        }
        if (self.pid) |pid| {
            if (entry.pid != pid and entry.tid != pid) return false;
        }
        if (self.kind) |kind| {
            if (entry.kind != kind) return false;
        }
        if (self.loss_only and !isLoss(entry)) return false;
        return true;
    }

    /// Timeline lanes are switch slices, so only task/pid constraints apply.
    /// Kind and loss filters intentionally stay in the event ledger.
    pub fn matchesSlice(self: Filter, slice: session_mod.Slice) bool {
        if (self.comm) |comm| {
            if (comm.len == 0 or !std.mem.eql(u8, slice.comm, comm)) return false;
        }
        if (self.pid) |pid| {
            if (slice.pid != pid) return false;
        }
        return true;
    }

    /// Cycles through kinds that actually occur in the session. After the last
    /// present kind the predicate clears instead of wrapping forever.
    pub fn cycleKind(self: *Filter, session: *const session_mod.Session) void {
        const names = @typeInfo(event.Kind).@"enum".field_names;
        var present: [names.len]event.Kind = undefined;
        var count: usize = 0;
        for (names, 0..) |_, value| {
            const kind: event.Kind = @fromBackingInt(@intCast(value));
            if (hasKind(session, kind)) {
                present[count] = kind;
                count += 1;
            }
        }
        if (count == 0) {
            self.kind = null;
            return;
        }
        const current = self.kind orelse {
            self.kind = present[0];
            return;
        };
        for (present[0..count], 0..) |kind, index| {
            if (kind == current) {
                self.kind = if (index + 1 < count) present[index + 1] else null;
                return;
            }
        }
        self.kind = present[0];
    }

    pub fn handleInput(
        self: *Filter,
        session: *const session_mod.Session,
        selection_comm: ?[]const u8,
        selection_pid: ?i32,
        input: *input_mod.Input,
    ) bool {
        switch (input.key) {
            .filter => if (selection_comm) |comm| {
                self.comm = comm;
            },
            .pid => if (selection_pid) |pid| {
                self.pid = pid;
            },
            .kind => self.cycleKind(session),
            .loss => self.loss_only = !self.loss_only,
            .clear => self.clear(),
            else => return false,
        }
        input.key = .none;
        return true;
    }
};

pub fn hasKind(session: *const session_mod.Session, kind: event.Kind) bool {
    for (session.events) |entry| {
        if (entry.kind == kind) return true;
    }
    return false;
}

test "combined filters match one event at a time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_switch\",\"ts_ns\":1," ++
        "\"cpu\":0,\"pid\":10,\"tid\":10,\"comm\":\"worker\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"page_fault\",\"ts_ns\":2," ++
        "\"cpu\":0,\"pid\":11,\"tid\":11,\"comm\":\"worker\",\"b\":0,\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":3," ++
        "\"cpu\":-1,\"pid\":-1,\"tid\":-1,\"detail\":\"sample_loss dropped=3\"," ++
        "\"host_mutation\":false}\n";
    const session = try session_mod.Session.fromData(arena.allocator(), "test", data);
    try std.testing.expectEqual(@as(usize, 3), session.events.len);

    var filter = Filter{ .comm = "worker" };
    try std.testing.expect(filter.matchesEvent(session.events[0]));
    try std.testing.expect(filter.matchesEvent(session.events[1]));
    try std.testing.expect(!filter.matchesEvent(session.events[2]));

    filter.pid = 11;
    filter.kind = .page_fault;
    try std.testing.expect(!filter.matchesEvent(session.events[0]));
    try std.testing.expect(filter.matchesEvent(session.events[1]));

    filter.clear();
    filter.loss_only = true;
    try std.testing.expect(!filter.matchesEvent(session.events[0]));
    try std.testing.expect(filter.matchesEvent(session.events[2]));
    try std.testing.expect(Filter.isLoss(session.events[2]));
}

test "kind cycling visits present kinds and clears after a full wrap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_switch\",\"ts_ns\":1," ++
        "\"cpu\":0,\"pid\":1,\"comm\":\"a\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"page_fault\",\"ts_ns\":2," ++
        "\"cpu\":0,\"pid\":1,\"comm\":\"a\",\"host_mutation\":false}\n";
    const session = try session_mod.Session.fromData(arena.allocator(), "test", data);
    var filter = Filter{};
    filter.cycleKind(&session);
    try std.testing.expectEqual(event.Kind.sched_switch, filter.kind.?);
    filter.cycleKind(&session);
    try std.testing.expectEqual(event.Kind.page_fault, filter.kind.?);
    filter.cycleKind(&session);
    try std.testing.expect(filter.kind == null);
}

test "input edits the combined filter and clears it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.fromData(arena.allocator(), "test", "");
    var filter = Filter{};
    var input = input_mod.Input{ .key = .filter };
    try std.testing.expect(filter.handleInput(&session, "worker", 7, &input));
    try std.testing.expectEqualStrings("worker", filter.comm.?);
    input.key = .pid;
    _ = filter.handleInput(&session, "worker", 7, &input);
    try std.testing.expectEqual(@as(i32, 7), filter.pid.?);
    input.key = .loss;
    _ = filter.handleInput(&session, "worker", 7, &input);
    try std.testing.expect(filter.loss_only);
    input.key = .clear;
    _ = filter.handleInput(&session, "worker", 7, &input);
    try std.testing.expect(!filter.active());
}
