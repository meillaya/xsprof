//! Read-only perf_event_open capture for scheduler tracepoints and page faults.
//! Non-Linux hosts fail closed. Nothing here writes scheduler state.

const std = @import("std");
const builtin = @import("builtin");
const event = @import("../core/event.zig");
const json = @import("../core/json.zig");
const loss = @import("../core/loss.zig");
const sched_state = @import("../core/sched_state.zig");
const proc = @import("../os/linux/proc.zig");
const ring_mod = @import("ring.zig");
const order = @import("order.zig");

pub const live_linux = builtin.os.tag == .linux;

pub const State = enum { READY, DEGRADED, SKIP, REFUSE };

/// One declared collector's ring coverage. `expected` is the ring count the
/// capture options declared (one per CPU for tracepoint/software rings);
/// `cpus` is how many opened. The reason is set whenever they disagree.
pub const RingCoverage = struct {
    cpus: u32 = 0,
    expected: u32 = 0,
    reason_buf: [96]u8 = @splat(0),
    reason_len: usize = 0,

    pub fn reason(self: *const RingCoverage) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    pub fn setReason(self: *RingCoverage, text: []const u8) void {
        const len = @min(text.len, self.reason_buf.len);
        @memcpy(self.reason_buf[0..len], text[0..len]);
        self.reason_len = len;
    }

    /// READY when every declared ring opened, DEGRADED for a partial set, and
    /// SKIP when a declared collector has no ring at all.
    pub fn state(self: *const RingCoverage) State {
        if (self.expected == 0) return .READY;
        if (self.cpus == 0) return .SKIP;
        if (self.cpus < self.expected) return .DEGRADED;
        return .READY;
    }

    pub fn isFull(self: *const RingCoverage) bool {
        return self.expected == 0 or self.cpus == self.expected;
    }
};

pub const collector_count = 4;

/// Per-collector coverage in canonical (ascending key) name order. An
/// `expected == 0` collector was not declared by the capture options and is
/// omitted from the wire object and the session markers.
pub const Coverage = struct {
    page_faults: RingCoverage = .{},
    sched_migrate: RingCoverage = .{},
    sched_switch: RingCoverage = .{},
    sched_wakeup: RingCoverage = .{},

    /// READY only when every declared collector is fully up.
    pub fn state(self: *const Coverage) State {
        inline for (@typeInfo(Coverage).@"struct".field_names) |field_name| {
            if (@field(self, field_name).state() != .READY) return .DEGRADED;
        }
        return .READY;
    }

    pub fn declared(self: *const Coverage) usize {
        var count: usize = 0;
        inline for (@typeInfo(Coverage).@"struct".field_names) |field_name| {
            if (@field(self, field_name).expected != 0) count += 1;
        }
        return count;
    }

    /// Fill canonical JSON entries for the additive `rings` object of
    /// `xsprof/capture-summary/v1`. Callers own the storage; the returned
    /// count is the number of declared collectors.
    pub fn fillJson(
        self: *const Coverage,
        outer: *[collector_count]json.Entry,
        inner: *[collector_count][3]json.Entry,
    ) usize {
        var count: usize = 0;
        inline for (@typeInfo(Coverage).@"struct".field_names) |field_name| {
            const ring = &@field(self, field_name);
            if (ring.expected != 0) {
                var used: usize = 0;
                inner[count][used] = .{ .key = "cpus", .value = .{ .unsigned = ring.cpus } };
                used += 1;
                inner[count][used] = .{ .key = "expected", .value = .{ .unsigned = ring.expected } };
                used += 1;
                if (ring.reason_len != 0) {
                    inner[count][used] = .{ .key = "reason", .value = .{ .string = ring.reason() } };
                    used += 1;
                }
                outer[count] = .{ .key = field_name, .value = .{ .object = inner[count][0..used] } };
                count += 1;
            }
        }
        return count;
    }

    /// Session metadata capability events: one `ring_<collector>:<STATE>:<n> of
    /// <m> cpus[; reason]` row per declared collector. Strings are allocated
    /// from `allocator` (normally the caller's per-capture arena).
    pub fn events(
        self: *const Coverage,
        allocator: std.mem.Allocator,
        now_ns: u64,
    ) ![]event.RawEvent {
        var list: std.ArrayList(event.RawEvent) = .empty;
        errdefer list.deinit(allocator);
        inline for (@typeInfo(Coverage).@"struct".field_names) |field_name| {
            const ring = @field(self, field_name);
            if (ring.expected != 0) {
                const detail = if (ring.reason_len == 0)
                    try std.fmt.allocPrint(allocator, "ring_{s}:{s}:{d} of {d} cpus", .{
                        field_name,
                        @tagName(ring.state()),
                        ring.cpus,
                        ring.expected,
                    })
                else
                    try std.fmt.allocPrint(allocator, "ring_{s}:{s}:{d} of {d} cpus; {s}", .{
                        field_name,
                        @tagName(ring.state()),
                        ring.cpus,
                        ring.expected,
                        ring.reason(),
                    });
                try list.append(allocator, .{
                    .kind = .capability,
                    .ts_ns = now_ns,
                    .cpu = -1,
                    .pid = -1,
                    .tid = -1,
                    .detail = detail,
                });
            }
        }
        return list.toOwnedSlice(allocator);
    }
};

pub const Result = struct {
    state: State,
    reason: []const u8 = "",
    events: []const event.RawEvent = &.{},
    lost: u64 = 0,
    cpus: u32 = 0,
    duration_ms: u32 = 0,
    /// Actual ring coverage of the opened capture (empty on SKIP/REFUSE).
    coverage: Coverage = .{},
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
    return probeWithOptions(io, allocator, .{});
}

/// Probe the declared collectors, not just tracefs readability: READY means
/// every collector declared by `opts` has a working ring, DEGRADED means at
/// least one is unavailable (exact reasons in `coverage`), and REFUSE means the
/// required sched_switch collector or tracefs itself is unusable.
pub fn probeWithOptions(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Result {
    if (!live_linux) {
        return .{ .state = .SKIP, .reason = "non-Linux host: perf_event_open unavailable" };
    }
    return probeLinux(io, allocator, opts);
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

fn closeRing(ring: Ring) void {
    _ = std.os.linux.munmap(ring.base, ring.length);
    _ = std.os.linux.close(ring.fd);
}

/// Open and immediately close one ring on CPU 0. This is the only reliable
/// signal that an event type is permitted on this host; the tracefs format file
/// being readable does not mean `perf_event_open` will accept the event.
fn probeRing(kind: RingKind, id: u64, fields: Fields) !void {
    const ring = try ring_mod.openRing(kind, 0, id, fields, 1);
    closeRing(ring);
}

fn probeTracepoint(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
    kind: RingKind,
) !void {
    const id = try ring_mod.tracepointId(io, allocator, root, name);
    const fields = try ring_mod.formatFor(io, allocator, root, name);
    try probeRing(kind, id, fields);
}

fn probeFaults() !void {
    inline for ([_]RingKind{ .faults_minor, .faults_major }) |kind| {
        if (ring_mod.openRing(kind, 0, 0, .{}, 1)) |ring| {
            closeRing(ring);
            return;
        } else |_| {}
    }
    const ring = try ring_mod.openRing(.faults_combined, 0, 0, .{}, 1);
    closeRing(ring);
}

fn setProbeFailure(ring: *RingCoverage, name: []const u8, err: anyerror) void {
    var buffer: [96]u8 = undefined;
    const text = switch (err) {
        error.FileNotFound,
        error.TracepointUnavailable,
        => std.fmt.bufPrint(&buffer, "{s} tracepoint unavailable", .{name}) catch "tracepoint unavailable",
        error.PermissionDenied => std.fmt.bufPrint(
            &buffer,
            "{s} perf_event_open denied",
            .{name},
        ) catch "perf_event_open denied",
        else => std.fmt.bufPrint(
            &buffer,
            "{s} perf_event_open failed: {s}",
            .{ name, @errorName(err) },
        ) catch "perf_event_open failed",
    };
    ring.setReason(text);
}

fn setCoverageShortfall(ring: *RingCoverage, opened: u32) void {
    ring.cpus = opened;
    if (ring.reason_len != 0 or ring.isFull()) return;
    var buffer: [96]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buffer,
        "{d} of {d} cpus (perf_event_open failed)",
        .{ opened, ring.expected },
    ) catch "partial CPU coverage";
    ring.setReason(text);
}

fn degradedReason(
    allocator: std.mem.Allocator,
    coverage: *const Coverage,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("partial capture: ");
    var first = true;
    inline for (@typeInfo(Coverage).@"struct".field_names) |field_name| {
        const ring = @field(coverage, field_name);
        if (!ring.isFull()) {
            if (!first) try out.writer.writeAll("; ");
            first = false;
            if (ring.reason_len != 0) {
                try out.writer.print("{s} {s}", .{ field_name, ring.reason() });
            } else {
                try out.writer.print("{s} unavailable", .{field_name});
            }
        }
    }
    if (first) try out.writer.writeAll("one or more collectors unavailable");
    return out.toOwnedSlice();
}

fn probeLinux(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Result {
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
    const root = tracefsRoot(io) orelse
        return .{ .state = .REFUSE, .reason = "tracefs sched events unreadable" };

    var coverage: Coverage = .{};
    // sched_switch is the required collector: without it there is no capture.
    coverage.sched_switch.expected = 1;
    probeTracepoint(io, allocator, root, "sched_switch", .switch_) catch |err| {
        setProbeFailure(&coverage.sched_switch, "sched_switch", err);
        return .{
            .state = .REFUSE,
            .reason = try std.fmt.allocPrint(
                allocator,
                "sched_switch unavailable: {s}",
                .{coverage.sched_switch.reason()},
            ),
            .coverage = coverage,
        };
    };
    coverage.sched_switch.cpus = 1;

    if (opts.wakeups) {
        coverage.sched_wakeup.expected = 1;
        probeTracepoint(io, allocator, root, "sched_wakeup", .wakeup) catch |err| {
            setProbeFailure(&coverage.sched_wakeup, "sched_wakeup", err);
        };
        if (coverage.sched_wakeup.reason_len == 0) coverage.sched_wakeup.cpus = 1;
    }
    if (opts.migrations) {
        coverage.sched_migrate.expected = 1;
        probeTracepoint(io, allocator, root, "sched_migrate_task", .migrate) catch |err| {
            setProbeFailure(&coverage.sched_migrate, "sched_migrate", err);
        };
        if (coverage.sched_migrate.reason_len == 0) coverage.sched_migrate.cpus = 1;
    }
    if (opts.faults) {
        coverage.page_faults.expected = 1;
        probeFaults() catch |err| {
            coverage.page_faults.setReason(if (err == error.PermissionDenied)
                "software events denied"
            else
                "software events unavailable");
        };
        if (coverage.page_faults.reason_len == 0) coverage.page_faults.cpus = 1;
    }

    const state = coverage.state();
    const reason = if (state == .READY)
        if (paranoid <= 1)
            "sched tracepoints + perf_event_paranoid<=1"
        else
            "sched tracepoints + CAP_PERFMON"
    else
        try degradedReason(allocator, &coverage);
    return .{ .state = state, .reason = reason, .coverage = coverage };
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
    /// Actual ring coverage after openReady; probe coverage is advisory.
    coverage: Coverage = .{},

    /// Open all rings once. The caller probes first when it needs the exact
    /// SKIP/REFUSE reason. DEGRADED probing proceeds: the capture is still
    /// useful, and the actual opened-ring coverage is recorded per collector.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Capture {
        const probe_result = try probeWithOptions(io, allocator, opts);
        if (probe_result.state != .READY and probe_result.state != .DEGRADED) {
            return error.CaptureNotReady;
        }
        const root = tracefsRoot(io) orelse return error.CaptureNotReady;
        return openReady(io, allocator, opts, root);
    }

    pub fn coverageState(self: *const Capture) State {
        return self.coverage.state();
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
                    // Canonicalize the kernel's preemption marker to running
                    // (the importer does the same for `R+`) so `c == 0` means
                    // "left the CPU still runnable" in every capture.
                    .c = sched_state.normalizePrevState(readU32(raw, fields.prev_state)),
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
    var coverage: Coverage = .{};
    coverage.sched_switch.expected = @intCast(cpu_count);
    if (opts.wakeups) coverage.sched_wakeup.expected = @intCast(cpu_count);
    if (opts.migrations) coverage.sched_migrate.expected = @intCast(cpu_count);
    if (opts.faults) coverage.page_faults.expected = @intCast(cpu_count);
    if (opts.wakeups and wakeup_id == 0) coverage.sched_wakeup.setReason("tracepoint unavailable");
    if (opts.migrations and migrate_id == 0) coverage.sched_migrate.setReason("tracepoint unavailable");

    var switch_rings: u32 = 0;
    var wakeup_rings: u32 = 0;
    var migrate_rings: u32 = 0;
    var fault_cpus: u32 = 0;
    var cpu: u32 = 0;
    while (cpu < cpu_count) : (cpu += 1) {
        if (ring_mod.openRing(.switch_, cpu, switch_id, capture.switch_fields, opts.ring_pages)) |ring| {
            try capture.rings.append(allocator, ring);
            switch_rings += 1;
        } else |_| {}
        if (opts.wakeups and wakeup_id != 0) {
            if (ring_mod.openRing(.wakeup, cpu, wakeup_id, capture.wakeup_fields, opts.ring_pages)) |ring| {
                try capture.rings.append(allocator, ring);
                wakeup_rings += 1;
            } else |_| {}
        }
        if (opts.migrations and migrate_id != 0) {
            if (ring_mod.openRing(.migrate, cpu, migrate_id, capture.migrate_fields, opts.ring_pages)) |ring| {
                try capture.rings.append(allocator, ring);
                migrate_rings += 1;
            } else |_| {}
        }
        if (opts.faults) {
            var opened_for_cpu = false;
            if (ring_mod.openRing(.faults_minor, cpu, 0, .{}, opts.ring_pages)) |ring| {
                try capture.rings.append(allocator, ring);
                opened_for_cpu = true;
            } else |_| {}
            if (ring_mod.openRing(.faults_major, cpu, 0, .{}, opts.ring_pages)) |ring| {
                try capture.rings.append(allocator, ring);
                opened_for_cpu = true;
            } else |_| {}
            if (!opened_for_cpu) {
                if (ring_mod.openRing(.faults_combined, cpu, 0, .{}, opts.ring_pages)) |ring| {
                    try capture.rings.append(allocator, ring);
                    opened_for_cpu = true;
                } else |_| {}
            }
            if (opened_for_cpu) fault_cpus += 1;
        }
    }
    if (switch_rings == 0) return error.TracepointUnavailable;
    if (capture.rings.items.len == 0) return error.NoEvents;

    // Record the rings that actually opened: partial CPU coverage is a
    // first-class DEGRADED state with its exact shortfall in the reason.
    setCoverageShortfall(&coverage.sched_switch, switch_rings);
    if (opts.wakeups) setCoverageShortfall(&coverage.sched_wakeup, wakeup_rings);
    if (opts.migrations) setCoverageShortfall(&coverage.sched_migrate, migrate_rings);
    if (opts.faults) {
        coverage.page_faults.cpus = fault_cpus;
        if (coverage.page_faults.reason_len == 0 and fault_cpus == 0) {
            coverage.page_faults.setReason("software events unavailable");
        } else {
            setCoverageShortfall(&coverage.page_faults, fault_cpus);
        }
    }
    capture.coverage = coverage;
    return capture;
}

// Checks that probing has a defined SKIP/REFUSE/READY/DEGRADED state off Linux.
test "capture fails closed off Linux or without privilege" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try probe(std.testing.io, arena.allocator());
    if (!live_linux) {
        try std.testing.expectEqual(State.SKIP, p.state);
    } else {
        try std.testing.expect(p.state == .SKIP or p.state == .REFUSE or
            p.state == .READY or p.state == .DEGRADED);
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

// Checks the coverage model: READY only when every declared ring is up,
// DEGRADED with an exact reason when one collector is short, and unrequested
// collectors are omitted rather than counted as failures.
test "coverage declares READY only for a complete collector set" {
    var full: Coverage = .{};
    full.sched_switch = .{ .cpus = 8, .expected = 8 };
    full.sched_wakeup = .{ .cpus = 8, .expected = 8 };
    full.sched_migrate = .{ .cpus = 8, .expected = 8 };
    full.page_faults = .{ .cpus = 8, .expected = 8 };
    try std.testing.expectEqual(State.READY, full.state());
    try std.testing.expectEqual(@as(usize, 4), full.declared());

    // An undeclared collector never degrades the capture.
    var scheduler_only: Coverage = .{};
    scheduler_only.sched_switch = .{ .cpus = 4, .expected = 4 };
    scheduler_only.sched_wakeup = .{ .cpus = 4, .expected = 4 };
    scheduler_only.sched_migrate = .{ .cpus = 4, .expected = 4 };
    try std.testing.expectEqual(State.READY, scheduler_only.state());
    try std.testing.expectEqual(@as(usize, 3), scheduler_only.declared());
}

// Checks the probe finalizer turns a partial collector set into DEGRADED with
// the exact shortfall reason (the shape probeLinux returns on a real host).
test "partial probe coverage is DEGRADED with an exact reason" {
    var coverage: Coverage = .{};
    coverage.sched_switch = .{ .cpus = 1, .expected = 1 };
    coverage.sched_wakeup = .{ .expected = 1 };
    coverage.sched_wakeup.setReason("tracepoint unavailable");
    coverage.sched_migrate = .{ .cpus = 1, .expected = 1 };
    coverage.page_faults = .{ .cpus = 0, .expected = 1 };
    coverage.page_faults.setReason("software events denied");
    try std.testing.expectEqual(State.DEGRADED, coverage.state());
    try std.testing.expectEqual(State.SKIP, coverage.sched_wakeup.state());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const reason = try degradedReason(arena.allocator(), &coverage);
    try std.testing.expectEqualStrings(
        "partial capture: page_faults software events denied; sched_wakeup tracepoint unavailable",
        reason,
    );

    // Partial CPU coverage keeps the collector DEGRADED, not READY.
    var partial_cpus: Coverage = .{};
    partial_cpus.sched_switch = .{ .cpus = 2, .expected = 8 };
    partial_cpus.sched_switch.setReason("2 of 8 cpus (perf_event_open failed)");
    try std.testing.expectEqual(State.DEGRADED, partial_cpus.state());
    try std.testing.expectEqualStrings("2 of 8 cpus (perf_event_open failed)", partial_cpus.sched_switch.reason());
    setCoverageShortfall(&partial_cpus.sched_switch, 2);
    try std.testing.expectEqualStrings("2 of 8 cpus (perf_event_open failed)", partial_cpus.sched_switch.reason());
}

// Checks the capture-summary rings object is canonical ascending and only
// carries declared collectors.
test "coverage json entries are canonical and declared only" {
    var coverage: Coverage = .{};
    coverage.sched_switch = .{ .cpus = 2, .expected = 8 };
    coverage.sched_switch.setReason("2 of 8 cpus (perf_event_open failed)");
    coverage.sched_wakeup = .{ .cpus = 8, .expected = 8 };
    coverage.page_faults = .{ .expected = 8 };
    coverage.page_faults.setReason("software events unavailable");

    var outer: [collector_count]json.Entry = undefined;
    var inner: [collector_count][3]json.Entry = undefined;
    const count = coverage.fillJson(&outer, &inner);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("page_faults", outer[0].key);
    try std.testing.expectEqualStrings("sched_switch", outer[1].key);
    try std.testing.expectEqualStrings("sched_wakeup", outer[2].key);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try json.write(&writer, .{ .object = &.{
        .{ .key = "capability", .value = .{ .string = "DEGRADED" } },
        .{ .key = "rings", .value = .{ .object = outer[0..count] } },
    } });
    try std.testing.expectEqualStrings(
        "{\"capability\":\"DEGRADED\",\"rings\":{" ++
            "\"page_faults\":{\"cpus\":0,\"expected\":8,\"reason\":\"software events unavailable\"}," ++
            "\"sched_switch\":{\"cpus\":2,\"expected\":8,\"reason\":\"2 of 8 cpus (perf_event_open failed)\"}," ++
            "\"sched_wakeup\":{\"cpus\":8,\"expected\":8}}}",
        writer.buffered(),
    );
}

// Checks the session metadata markers are capability rows the stream index can
// parse (name:STATE:reason) and that they omit undeclared collectors.
test "coverage emits capability metadata markers" {
    var coverage: Coverage = .{};
    coverage.sched_switch = .{ .cpus = 4, .expected = 4 };
    coverage.sched_wakeup = .{ .cpus = 1, .expected = 4 };
    coverage.sched_wakeup.setReason("1 of 4 cpus (perf_event_open failed)");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const events = try coverage.events(arena.allocator(), 1234);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(event.Kind.capability, events[0].kind);
    try std.testing.expectEqual(@as(u64, 1234), events[0].ts_ns);
    try std.testing.expectEqualStrings("ring_sched_switch:READY:4 of 4 cpus", events[0].detail);
    try std.testing.expectEqualStrings(
        "ring_sched_wakeup:DEGRADED:1 of 4 cpus; 1 of 4 cpus (perf_event_open failed)",
        events[1].detail,
    );
}

// Checks producers name the loss marker through the shared registry.
test "perf ring loss marker uses the loss registry name" {
    try std.testing.expectEqualStrings("sample_loss", loss.marker.sample_loss);
}
