//! Read-only perf_event_open capture for scheduler tracepoints and page faults.
//! Non-Linux hosts fail closed. Nothing here writes scheduler state.

const std = @import("std");
const builtin = @import("builtin");
const event = @import("../core/event.zig");
const proc = @import("../os/linux/proc.zig");
const ring_mod = @import("ring.zig");
const order = @import("order.zig");

pub const live_linux = builtin.os.tag == .linux;

pub const State = enum { READY, DEGRADED, SKIP, REFUSE };

pub const Result = struct {
    state: State,
    reason: []const u8 = "",
    events: []const event.RawEvent = &.{},
    lost: u64 = 0,
    cpus: u32 = 0,
    duration_ms: u32 = 0,
};

const default_poll_timeout_ms: u32 = 20;
const default_ring_pages: u16 = 64;
const max_cpus = 256;

pub const Options = struct {
    poll_timeout_ms: u32 = default_poll_timeout_ms,
    ring_pages: u16 = default_ring_pages,
    wakeups: bool = true,
    migrations: bool = true,
    faults: bool = true,
};

pub fn probe(io: std.Io, allocator: std.mem.Allocator) !Result {
    if (!live_linux) {
        return .{ .state = .SKIP, .reason = "non-Linux host: perf_event_open unavailable" };
    }
    return probeLinux(io, allocator);
}

const tracefs_candidates = [_][]const u8{
    "/sys/kernel/tracing",
    "/sys/kernel/debug/tracing",
};

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max)) catch null;
}

pub fn tracefsRoot(io: std.Io) ?[]const u8 {
    for (tracefs_candidates) |base| {
        var path_buffer: [256]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "{s}/events/sched/sched_switch/format",
            .{base},
        ) catch continue;
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch continue;
        file.close(io);
        return base;
    }
    return null;
}

fn probeLinux(io: std.Io, allocator: std.mem.Allocator) !Result {
    const paranoid_text = readFile(io, allocator, "/proc/sys/kernel/perf_event_paranoid", 64);
    if (paranoid_text == null) {
        return .{ .state = .SKIP, .reason = "perf_event_paranoid unreadable" };
    }
    const paranoid = std.fmt.parseInt(i64, std.mem.trim(u8, paranoid_text.?, " \t\r\n"), 10) catch 99;
    const perfmon = proc.effectiveCapability(io, allocator, proc.cap_perfmon);
    if (paranoid > 1 and !perfmon) {
        return .{
            .state = .SKIP,
            .reason = try std.fmt.allocPrint(
                allocator,
                "perf_event_paranoid={d}; no CAP_PERFMON (fail-closed SKIP)",
                .{paranoid},
            ),
        };
    }
    if (tracefsRoot(io) == null) {
        return .{ .state = .REFUSE, .reason = "tracefs sched events unreadable" };
    }
    return .{
        .state = .READY,
        .reason = if (paranoid <= 1)
            "sched tracepoints + perf_event_paranoid<=1"
        else
            "sched tracepoints + CAP_PERFMON",
    };
}

const RingKind = ring_mod.RingKind;
const Fields = ring_mod.Fields;
const Ring = ring_mod.Ring;

pub const Batch = struct {
    events: []event.RawEvent,
    lost: u64,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Batch) void {
        self.arena.deinit();
        self.events = &.{};
    }
};

pub const Preset = enum { scheduler, memory, deep };

pub fn parsePreset(name: []const u8) ?Preset {
    inline for (@typeInfo(Preset).@"enum".field_names) |field| {
        if (std.mem.eql(u8, name, field)) return @field(Preset, field);
    }
    return null;
}

pub fn presetOptions(preset: Preset) Options {
    return switch (preset) {
        .scheduler => .{ .faults = false },
        .memory => .{ .wakeups = false, .migrations = false, .ring_pages = 32 },
        .deep => .{ .ring_pages = 256 },
    };
}

pub const Capture = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: Options = .{},
    rings: std.ArrayList(Ring) = .empty,
    events: std.ArrayList(event.RawEvent) = .empty,
    batch_arena: std.heap.ArenaAllocator,
    lost: u64 = 0,
    lost_pending: u64 = 0,
    cpus: u32 = 0,
    root: []const u8 = "",
    switch_fields: Fields = .{},
    wakeup_fields: Fields = .{},
    migrate_fields: Fields = .{},

    /// Open all rings once. The caller probes first when it needs the exact
    /// SKIP/REFUSE reason.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Capture {
        const probe_result = try probeLinux(io, allocator);
        if (probe_result.state != .READY) return error.CaptureNotReady;
        const root = tracefsRoot(io) orelse return error.CaptureNotReady;
        return openReady(io, allocator, opts, root);
    }

    pub fn poll(self: *Capture, timeout_ms: u32) !usize {
        const poll_fds = try self.allocator.alloc(std.posix.pollfd, self.rings.items.len);
        defer self.allocator.free(poll_fds);
        for (self.rings.items, 0..) |ring, index| {
            poll_fds[index] = .{ .fd = ring.fd, .events = std.posix.POLL.IN, .revents = 0 };
        }
        _ = std.posix.poll(poll_fds, @intCast(@min(timeout_ms, std.math.maxInt(i32)))) catch return 0;
        var drained: usize = 0;
        for (poll_fds, 0..) |poll_fd, index| {
            if (poll_fd.revents & std.posix.POLL.IN == 0) continue;
            try drain(self, &self.rings.items[index]);
            drained += 1;
        }
        return drained;
    }

    /// Transfer the current batch and its arena to the caller. The caller
    /// must call `Batch.deinit` after serializing or copying the events.
    pub fn take(self: *Capture) !Batch {
        const owned = self.events.toOwnedSlice(self.batch_arena.allocator()) catch |err| {
            return err;
        };
        order.sortBatch(owned);
        const old_arena = self.batch_arena;
        self.batch_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.events = .empty;
        const lost = self.lost_pending;
        self.lost_pending = 0;
        return .{ .events = owned, .lost = lost, .arena = old_arena };
    }

    pub fn stats(self: *const Capture) struct { lost: u64, cpus: u32 } {
        return .{ .lost = self.lost, .cpus = self.cpus };
    }

    pub fn deinit(self: *Capture) void {
        for (self.rings.items) |ring| {
            _ = std.os.linux.munmap(ring.base, ring.length);
            _ = std.os.linux.close(ring.fd);
        }
        self.rings.deinit(self.allocator);
        self.events.deinit(self.batch_arena.allocator());
        self.batch_arena.deinit();
    }
};

const Sample = struct {
    pid: i32,
    tid: i32,
    ts_ns: u64,
    cpu: i32,
    raw: []const u8,
};

fn parseSample(bytes: []const u8) ?Sample {
    if (bytes.len < 8 + 4 + 4 + 8 + 4 + 4) return null;
    var at: usize = 8;
    const pid: i32 = @bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little));
    const tid: i32 = @bitCast(std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little));
    at += 8;
    const ts_ns = std.mem.readInt(u64, bytes[at..][0..8], .little);
    at += 8;
    const cpu: i32 = @bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little));
    at += 8;
    var raw: []const u8 = &.{};
    if (bytes.len >= at + 4) {
        const raw_len = std.mem.readInt(u32, bytes[at..][0..4], .little);
        at += 4;
        if (raw_len <= bytes.len - at) raw = bytes[at .. at + raw_len] else raw = bytes[at..];
    }
    return .{ .pid = pid, .tid = tid, .ts_ns = ts_ns, .cpu = cpu, .raw = raw };
}

fn readU32(raw: []const u8, offset: u16) u32 {
    const at: usize = offset;
    if (at + 4 > raw.len) return 0;
    return std.mem.readInt(u32, raw[at..][0..4], .little);
}

fn commAt(allocator: std.mem.Allocator, raw: []const u8, offset: u16) ![]const u8 {
    const at: usize = offset;
    if (at + 16 > raw.len) return "";
    const chunk = raw[at .. at + 16];
    const end = std.mem.indexOfScalar(u8, chunk, 0) orelse chunk.len;
    return allocator.dupe(u8, chunk[0..end]);
}

fn emitRecord(self: *Capture, ring: *const Ring, bytes: []const u8) !void {
    if (bytes.len < 8) return;
    const kind = std.mem.readInt(u32, bytes[0..4], .little);
    switch (kind) {
        9 => {
            const sample = parseSample(bytes) orelse return;
            if (ring.isFault()) {
                try self.events.append(self.batch_arena.allocator(), .{
                    .kind = .page_fault,
                    .ts_ns = sample.ts_ns,
                    .cpu = sample.cpu,
                    .pid = sample.pid,
                    .tid = sample.tid,
                    .a = 1,
                    .b = if (ring.kind == .faults_major) 1 else 0,
                });
                return;
            }
            const fields = ring.fields;
            const raw = sample.raw;
            const pid = readU32(raw, fields.pid);
            const prev_pid = readU32(raw, fields.prev_pid);
            const next_pid = readU32(raw, fields.next_pid);
            const target_cpu = readU32(raw, fields.target_cpu);
            const orig_cpu = readU32(raw, fields.orig_cpu);
            const dest_cpu = readU32(raw, fields.dest_cpu);
            switch (ring.kind) {
                .switch_ => try self.events.append(self.batch_arena.allocator(), .{
                    .kind = .sched_switch,
                    .ts_ns = sample.ts_ns,
                    .cpu = sample.cpu,
                    .pid = sample.pid,
                    .tid = sample.tid,
                    .a = next_pid,
                    .b = prev_pid,
                    .c = readU32(raw, fields.prev_state),
                    .comm = try commAt(self.batch_arena.allocator(), raw, fields.next_comm),
                }),
                .wakeup => {
                    const woken = if (pid != 0) pid else readU32(raw, fields.pid);
                    try self.events.append(self.batch_arena.allocator(), .{
                        .kind = .sched_wakeup,
                        .ts_ns = sample.ts_ns,
                        .cpu = sample.cpu,
                        .pid = sample.pid,
                        .tid = sample.tid,
                        .a = woken,
                        .b = target_cpu,
                        .comm = try commAt(self.batch_arena.allocator(), raw, fields.comm),
                    });
                },
                .migrate => try self.events.append(self.batch_arena.allocator(), .{
                    .kind = .sched_migrate,
                    .ts_ns = sample.ts_ns,
                    .cpu = sample.cpu,
                    .pid = sample.pid,
                    .tid = sample.tid,
                    .a = orig_cpu,
                    .b = dest_cpu,
                    .comm = try commAt(self.batch_arena.allocator(), raw, fields.comm),
                }),
                .faults_minor, .faults_major, .faults_combined => {},
            }
        },
        2 => {
            if (bytes.len >= 24) {
                const lost = std.mem.readInt(u64, bytes[16..24], .little);
                self.lost += lost;
                self.lost_pending += lost;
                const detail = try std.fmt.allocPrint(
                    self.batch_arena.allocator(),
                    "sample_loss perf_ring lost={d}",
                    .{lost},
                );
                try self.events.append(self.batch_arena.allocator(), .{
                    .kind = .marker,
                    .ts_ns = @intCast(std.Io.Clock.now(.awake, self.io).nanoseconds),
                    .cpu = @intCast(ring.cpu),
                    .detail = detail,
                });
            }
        },
        else => {},
    }
}

fn drain(self: *Capture, ring: *Ring) !void {
    const head = @atomicLoad(u64, &ring.page.data_head, .acquire);
    var tail = ring.page.data_tail;
    const size = ring.data.len;
    if (size == 0) return;
    var scratch: [8192]u8 = undefined;
    while (tail < head) {
        const offset: usize = @intCast(tail % size);
        const first = @min(8, size - offset);
        @memcpy(scratch[0..first], ring.data[offset .. offset + first]);
        if (first < 8) {
            const rest = 8 - first;
            @memcpy(scratch[first .. first + rest], ring.data[0..rest]);
        }
        const rec_size = std.mem.readInt(u16, scratch[6..8], .little);
        if (rec_size < 8 or rec_size > size) break;
        if (tail + rec_size > head) break;
        if (rec_size > scratch.len) {
            tail += rec_size;
            continue;
        }
        if (offset + rec_size <= size) {
            @memcpy(scratch[0..rec_size], ring.data[offset .. offset + rec_size]);
        } else {
            const first_part = size - offset;
            @memcpy(scratch[0..first_part], ring.data[offset..size]);
            @memcpy(scratch[first_part..rec_size], ring.data[0 .. rec_size - first_part]);
        }
        try emitRecord(self, ring, scratch[0..rec_size]);
        tail += rec_size;
    }
    ring.page.data_tail = head;
}

pub fn openReady(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: Options,
    root: []const u8,
) !Capture {
    var capture: Capture = .{
        .io = io,
        .allocator = allocator,
        .opts = opts,
        .batch_arena = std.heap.ArenaAllocator.init(allocator),
        .root = root,
    };
    errdefer capture.deinit();

    const switch_id = ring_mod.tracepointId(io, allocator, root, "sched_switch") catch return error.TracepointUnavailable;
    const wakeup_id = ring_mod.tracepointId(io, allocator, root, "sched_wakeup") catch 0;
    const migrate_id = ring_mod.tracepointId(io, allocator, root, "sched_migrate_task") catch 0;
    capture.switch_fields = ring_mod.formatFor(io, allocator, root, "sched_switch") catch return error.TracepointUnavailable;
    capture.wakeup_fields = ring_mod.formatFor(io, allocator, root, "sched_wakeup") catch .{};
    capture.migrate_fields = ring_mod.formatFor(io, allocator, root, "sched_migrate_task") catch .{};

    const cpu_count = @min(std.Thread.getCpuCount() catch 1, max_cpus);
    capture.cpus = @intCast(cpu_count);
    var cpu: u32 = 0;
    while (cpu < cpu_count) : (cpu += 1) {
        try capture.rings.append(allocator, try ring_mod.openRing(
            .switch_,
            cpu,
            switch_id,
            capture.switch_fields,
            opts.ring_pages,
        ));
        if (opts.wakeups and wakeup_id != 0) {
            if (ring_mod.openRing(
                .wakeup,
                cpu,
                wakeup_id,
                capture.wakeup_fields,
                opts.ring_pages,
            )) |wakeup_ring| {
                try capture.rings.append(allocator, wakeup_ring);
            } else |_| {}
        }
        if (opts.migrations and migrate_id != 0) {
            if (ring_mod.openRing(
                .migrate,
                cpu,
                migrate_id,
                capture.migrate_fields,
                opts.ring_pages,
            )) |migrate_ring| {
                try capture.rings.append(allocator, migrate_ring);
            } else |_| {}
        }
        if (opts.faults) {
            var fault_rings: usize = 0;
            if (ring_mod.openRing(.faults_minor, cpu, 0, .{}, opts.ring_pages)) |minor| {
                try capture.rings.append(allocator, minor);
                fault_rings += 1;
            } else |_| {}
            if (ring_mod.openRing(.faults_major, cpu, 0, .{}, opts.ring_pages)) |major| {
                try capture.rings.append(allocator, major);
                fault_rings += 1;
            } else |_| {}
            if (fault_rings == 0) {
                if (ring_mod.openRing(
                    .faults_combined,
                    cpu,
                    0,
                    .{},
                    opts.ring_pages,
                )) |combined| {
                    try capture.rings.append(allocator, combined);
                } else |_| {}
            }
        }
    }
    if (capture.rings.items.len == 0) return error.NoEvents;
    return capture;
}

// Checks that probing has a defined SKIP/REFUSE/READY state off Linux.
test "capture fails closed off Linux or without privilege" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try probe(std.testing.io, arena.allocator());
    if (!live_linux) {
        try std.testing.expectEqual(State.SKIP, p.state);
    } else {
        try std.testing.expect(p.state == .SKIP or p.state == .REFUSE or p.state == .READY);
    }
}

// Checks preset event masks and ring sizing.
test "capture presets set explicit options" {
    const scheduler = presetOptions(.scheduler);
    try std.testing.expect(!scheduler.faults);
    try std.testing.expect(scheduler.wakeups);
    const memory = presetOptions(.memory);
    try std.testing.expect(memory.faults);
    try std.testing.expect(!memory.wakeups);
    try std.testing.expectEqual(@as(u16, 256), presetOptions(.deep).ring_pages);
    try std.testing.expect(parsePreset("deep") != null);
}
