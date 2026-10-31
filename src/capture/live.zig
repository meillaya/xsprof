//! Read-only perf_event_open capture for scheduler tracepoints and page faults.
//! Non-Linux hosts fail closed. Nothing here writes scheduler state.

const std = @import("std");
const builtin = @import("builtin");
const event = @import("../core/event.zig");
const proc = @import("../os/linux/proc.zig");

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
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
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
    if (paranoid > 1) {
        return .{
            .state = .SKIP,
            .reason = try std.fmt.allocPrint(
                allocator,
                "perf_event_paranoid={d} (need CAP_PERFMON or paranoid<=1; fail-closed SKIP)",
                .{paranoid},
            ),
        };
    }
    if (tracefsRoot(io) == null) {
        return .{ .state = .REFUSE, .reason = "tracefs sched events unreadable" };
    }
    return .{ .state = .READY, .reason = "sched tracepoints + perf_event_paranoid<=1" };
}

const RingKind = enum { switch_, wakeup, migrate, faults };

const Fields = struct {
    prev_comm: u16 = 0,
    prev_pid: u16 = 0,
    next_comm: u16 = 0,
    next_pid: u16 = 0,
    comm: u16 = 0,
    pid: u16 = 0,
    target_cpu: u16 = 0,
    orig_cpu: u16 = 0,
    dest_cpu: u16 = 0,
    valid: bool = false,
};

const Ring = struct {
    fd: i32,
    base: [*]align(std.heap.page_size_min) u8,
    length: usize,
    kind: RingKind,
    cpu: u32,
    fields: Fields,
    page: *std.os.linux.perf_event_mmap_page,
    data: []u8,
};

pub const Batch = struct {
    events: []event.RawEvent,
    lost: u64,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Batch) void {
        self.arena.deinit();
        self.events = &.{};
    }
};

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

fn parseFormat(text: []const u8) Fields {
    var fields: Fields = .{ .valid = true };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimStart(u8, raw_line, " \t");
        if (!std.mem.startsWith(u8, line, "field:")) continue;
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const decl = line["field:".len..semi];
        const off_marker = std.mem.indexOf(u8, line, "offset:") orelse continue;
        const off_start = off_marker + "offset:".len;
        const off_end = std.mem.indexOfScalarPos(u8, line, off_start, ';') orelse line.len;
        const offset = std.fmt.parseInt(u16, std.mem.trim(u8, line[off_start..off_end], " "), 10) catch continue;
        var name = std.mem.trim(u8, decl, " \t");
        if (std.mem.indexOfScalar(u8, name, '[')) |bracket| name = name[0..bracket];
        const last_space = std.mem.lastIndexOfScalar(u8, name, ' ') orelse 0;
        name = std.mem.trim(u8, name[last_space..], " \t");
        if (std.mem.eql(u8, name, "prev_comm")) fields.prev_comm = offset;
        if (std.mem.eql(u8, name, "prev_pid")) fields.prev_pid = offset;
        if (std.mem.eql(u8, name, "next_comm")) fields.next_comm = offset;
        if (std.mem.eql(u8, name, "next_pid")) fields.next_pid = offset;
        if (std.mem.eql(u8, name, "comm")) fields.comm = offset;
        if (std.mem.eql(u8, name, "pid")) fields.pid = offset;
        if (std.mem.eql(u8, name, "target_cpu")) fields.target_cpu = offset;
        if (std.mem.eql(u8, name, "orig_cpu")) fields.orig_cpu = offset;
        if (std.mem.eql(u8, name, "dest_cpu")) fields.dest_cpu = offset;
    }
    return fields;
}

fn tracepointId(io: std.Io, allocator: std.mem.Allocator, root: []const u8, name: []const u8) !u64 {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/events/sched/{s}/id", .{ root, name });
    const text = readFile(io, allocator, path, 64) orelse return error.TracepointUnavailable;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch error.TracepointUnavailable;
}

fn formatFor(io: std.Io, allocator: std.mem.Allocator, root: []const u8, name: []const u8) !Fields {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/events/sched/{s}/format", .{ root, name });
    const text = readFile(io, allocator, path, 64 * 1024) orelse return error.TracepointUnavailable;
    return parseFormat(text);
}

fn openRing(
    io: std.Io,
    allocator: std.mem.Allocator,
    kind: RingKind,
    cpu: u32,
    id: u64,
    fields: Fields,
    ring_pages: u16,
) !Ring {
    var attr: std.os.linux.perf_event_attr = .{
        .type = .TRACEPOINT,
        .config = id,
        .sample_period_or_freq = 1,
        .sample_type = @as(u64, std.os.linux.PERF.SAMPLE.TID) |
            @as(u64, std.os.linux.PERF.SAMPLE.TIME) |
            @as(u64, std.os.linux.PERF.SAMPLE.CPU) |
            @as(u64, std.os.linux.PERF.SAMPLE.RAW),
        .wakeup_events_or_watermark = 1,
    };
    if (kind == .faults) {
        attr.type = .SOFTWARE;
        attr.config = @backingInt(std.os.linux.PERF.COUNT.SW.PAGE_FAULTS);
        attr.sample_type = @as(u64, std.os.linux.PERF.SAMPLE.TID) |
            @as(u64, std.os.linux.PERF.SAMPLE.TIME) |
            @as(u64, std.os.linux.PERF.SAMPLE.CPU);
    }
    const rc = std.os.linux.perf_event_open(&attr, -1, @intCast(cpu), -1, std.os.linux.PERF.FLAG.FD_CLOEXEC);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .ACCES => return error.PermissionDenied,
        .PERM => return error.PermissionDenied,
        .NOENT => return error.TracepointUnavailable,
        .NODEV => return error.TracepointUnavailable,
        else => return error.PerfOpenFailed,
    }
    const fd: i32 = @intCast(rc);
    errdefer _ = std.os.linux.close(fd);
    const page_size = std.heap.pageSize();
    const length = page_size * (@as(usize, ring_pages) + 1);
    const map_rc = std.os.linux.mmap(
        null,
        length,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    switch (std.os.linux.errno(map_rc)) {
        .SUCCESS => {},
        else => return error.MmapFailed,
    }
    const base: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(map_rc);
    const page: *std.os.linux.perf_event_mmap_page = @ptrCast(@alignCast(base));
    const data_offset: usize = @intCast(page.data_offset);
    const data_size: usize = @intCast(page.data_size);
    _ = allocator;
    _ = io;
    return .{
        .fd = fd,
        .base = base,
        .length = length,
        .kind = kind,
        .cpu = cpu,
        .fields = fields,
        .page = page,
        .data = base[data_offset .. data_offset + data_size],
    };
}

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
            if (ring.kind == .faults) {
                try self.events.append(self.batch_arena.allocator(), .{
                    .kind = .page_fault,
                    .ts_ns = sample.ts_ns,
                    .cpu = sample.cpu,
                    .pid = sample.pid,
                    .tid = sample.tid,
                    .a = 1,
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
                .faults => {},
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

    const switch_id = tracepointId(io, allocator, root, "sched_switch") catch return error.TracepointUnavailable;
    const wakeup_id = tracepointId(io, allocator, root, "sched_wakeup") catch 0;
    const migrate_id = tracepointId(io, allocator, root, "sched_migrate_task") catch 0;
    capture.switch_fields = formatFor(io, allocator, root, "sched_switch") catch return error.TracepointUnavailable;
    capture.wakeup_fields = formatFor(io, allocator, root, "sched_wakeup") catch .{};
    capture.migrate_fields = formatFor(io, allocator, root, "sched_migrate_task") catch .{};

    const cpu_count = @min(std.Thread.getCpuCount() catch 1, max_cpus);
    capture.cpus = @intCast(cpu_count);
    var cpu: u32 = 0;
    while (cpu < cpu_count) : (cpu += 1) {
        try capture.rings.append(allocator, try openRing(
            io,
            allocator,
            .switch_,
            cpu,
            switch_id,
            capture.switch_fields,
            opts.ring_pages,
        ));
        if (opts.wakeups and wakeup_id != 0) {
            capture.rings.append(allocator, try openRing(
                io,
                allocator,
                .wakeup,
                cpu,
                wakeup_id,
                capture.wakeup_fields,
                opts.ring_pages,
            )) catch {};
        }
        if (opts.migrations and migrate_id != 0) {
            capture.rings.append(allocator, try openRing(
                io,
                allocator,
                .migrate,
                cpu,
                migrate_id,
                capture.migrate_fields,
                opts.ring_pages,
            )) catch {};
        }
        if (opts.faults) {
            capture.rings.append(allocator, try openRing(
                io,
                allocator,
                .faults,
                cpu,
                0,
                .{},
                opts.ring_pages,
            )) catch {};
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
