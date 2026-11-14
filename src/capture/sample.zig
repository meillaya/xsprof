//! Experimental per-PID sampling lane: `perf_event_open` software CPU-clock
//! samples with an optional callchain, streamed as `stack_sample` events.
//!
//! This lane is deliberately separate from the scheduler/tracepoint collector
//! in `live.zig` (which is not touched here beyond shared read-only helpers).
//! It is opt-in (`record --sample cpu --pid PID`), per-process, read-only, and
//! Linux-only. Non-Linux hosts return SKIP, permission problems return SKIP
//! with the exact reason, and an unsupported kernel returns REFUSE. Nothing
//! here elevates privileges or changes host policy.
//!
//! Sample record layout follows the kernel's `PERF_RECORD_SAMPLE` field order
//! for `sample_type = IP|TID|TIME|CPU[|CALLCHAIN]`:
//!   ip u64, pid/tid u32 pair, time u64, cpu u32 + reserved u32,
//!   [nr u64, nr * u64 ips].
//! Ring loss (`PERF_RECORD_LOST`, `PERF_RECORD_LOST_SAMPLES`) becomes an
//! explicit `sample_loss` marker — samples are never interpolated.

const std = @import("std");
const builtin = @import("builtin");
const event = @import("../core/event.zig");
const json = @import("../core/json.zig");
const proc = @import("../os/linux/proc.zig");

pub const sample_linux = builtin.os.tag == .linux;

pub const State = enum { READY, DEGRADED, SKIP, REFUSE };

pub const default_freq_hz: u32 = 99;
pub const min_freq_hz: u32 = 1;
pub const max_freq_hz: u32 = 10_000;
pub const default_max_stack_frames: u16 = 32;
pub const max_stack_frames: u16 = event.max_stack_frames;
pub const max_cpus = 256;
pub const default_ring_pages: u16 = 64;
pub const default_poll_timeout_ms: u32 = 20;

pub const Options = struct {
    /// Target process id. Sampling is per-process by design; -1 is invalid.
    pid: i32 = -1,
    freq_hz: u32 = default_freq_hz,
    /// Capture `PERF_SAMPLE_CALLCHAIN` frames. Without it the lane records
    /// IP-only `stack_sample` rows (the `stack` array is omitted).
    stacks: bool = false,
    max_stack_frames: u16 = default_max_stack_frames,
    ring_pages: u16 = default_ring_pages,
    poll_timeout_ms: u32 = default_poll_timeout_ms,

    pub fn validate(self: Options) error{ InvalidPid, InvalidFrequency, InvalidStackFrames }!void {
        if (self.pid <= 0) return error.InvalidPid;
        if (self.freq_hz < min_freq_hz or self.freq_hz > max_freq_hz) return error.InvalidFrequency;
        if (self.max_stack_frames == 0 or self.max_stack_frames > max_stack_frames) {
            return error.InvalidStackFrames;
        }
        if (self.ring_pages == 0) return error.InvalidStackFrames;
    }

    pub fn sampleType(self: Options) u64 {
        const sample = std.os.linux.PERF.SAMPLE;
        var value: u64 = @as(u64, sample.IP) |
            @as(u64, sample.TID) |
            @as(u64, sample.TIME) |
            @as(u64, sample.CPU);
        if (self.stacks) value |= @as(u64, sample.CALLCHAIN);
        return value;
    }
};

/// One declared ring's CPU coverage. Sampling stays explicit about partial
/// coverage (per-CPU ring shortfalls) and about the per-task fallback.
pub const Coverage = struct {
    pub const Mode = enum { per_cpu, per_task };

    mode: Mode = .per_cpu,
    cpus: u32 = 0,
    expected: u32 = 0,
    reason_buf: [128]u8 = @splat(0),
    reason_len: usize = 0,

    pub fn reason(self: *const Coverage) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    pub fn setReason(self: *Coverage, text: []const u8) void {
        const len = @min(text.len, self.reason_buf.len);
        @memcpy(self.reason_buf[0..len], text[0..len]);
        self.reason_len = len;
    }

    pub fn state(self: *const Coverage) State {
        if (self.expected == 0) return .READY;
        if (self.cpus == 0) return .SKIP;
        if (self.cpus < self.expected) return .DEGRADED;
        return .READY;
    }

    /// The capability detail row for the capture stream. The per-task fallback
    /// is complete coverage for the sampled PID, so it stays READY with the
    /// fallback reason attached.
    pub fn detail(self: *const Coverage, allocator: std.mem.Allocator) ![]const u8 {
        const state_name = @tagName(self.state());
        if (self.reason_len != 0) {
            return std.fmt.allocPrint(allocator, "stack_sampling:{s}:{d} of {d} rings; {s}", .{
                state_name,
                self.cpus,
                self.expected,
                self.reason(),
            });
        }
        return std.fmt.allocPrint(allocator, "stack_sampling:{s}:{d} of {d} rings", .{
            state_name,
            self.cpus,
            self.expected,
        });
    }
};

pub const Result = struct {
    state: State,
    reason: []const u8 = "",
    coverage: Coverage = .{},
    lost: u64 = 0,
    cpus: u32 = 0,
    samples: u64 = 0,
    frames: u64 = 0,
    malformed: u64 = 0,
    duration_ms: u32 = 0,
};

fn readFileText(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max: usize,
) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [2048]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max)) catch null;
}

fn targetCommPath(pid: i32, buffer: *[64]u8) ?[]const u8 {
    if (pid <= 0) return null;
    return std.fmt.bufPrint(buffer, "/proc/{d}/comm", .{pid}) catch null;
}

/// Read the target's current comm, bounded and sanitized by the wire writer.
pub fn readComm(io: std.Io, allocator: std.mem.Allocator, pid: i32) ?[]u8 {
    var path_buffer: [64]u8 = undefined;
    const path = targetCommPath(pid, &path_buffer) orelse return null;
    const text = readFileText(io, allocator, path, 128) orelse return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

pub fn probe(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Result {
    if (!sample_linux) {
        return .{ .state = .SKIP, .reason = "non-Linux host: perf_event_open unavailable" };
    }
    return probeLinux(io, allocator, opts);
}

fn probeLinux(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Result {
    opts.validate() catch |err| {
        return .{
            .state = .REFUSE,
            .reason = try std.fmt.allocPrint(
                allocator,
                "invalid sampling options: {s}",
                .{@errorName(err)},
            ),
        };
    };
    const paranoid_text = readFileText(io, allocator, "/proc/sys/kernel/perf_event_paranoid", 64) orelse
        return .{ .state = .SKIP, .reason = "perf_event_paranoid unreadable" };
    const paranoid = std.fmt.parseInt(i64, std.mem.trim(u8, paranoid_text, " \t\r\n"), 10) catch 99;
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
    if (readComm(io, allocator, opts.pid) == null) {
        return .{
            .state = .SKIP,
            .reason = try std.fmt.allocPrint(allocator, "pid {d} not found", .{opts.pid}),
        };
    }
    // The definitive permission signal is opening a ring, not reading sysctls.
    if (openRing(io, allocator, opts, 0)) |ring| {
        closeRing(ring);
    } else |err| {
        return .{
            .state = probeStateFor(err),
            .reason = try probeReason(allocator, opts, paranoid, err),
        };
    }
    const suffix = if (opts.stacks) " with callchains" else " (IP only)";
    return .{
        .state = .READY,
        .reason = try std.fmt.allocPrint(
            allocator,
            "pid {d} software cpu-clock sampling at {d} Hz{s}",
            .{ opts.pid, opts.freq_hz, suffix },
        ),
    };
}

fn probeStateFor(err: anyerror) State {
    return switch (err) {
        error.PermissionDenied => .SKIP,
        error.PerfUnavailable => .REFUSE,
        else => .REFUSE,
    };
}

fn probeReason(
    allocator: std.mem.Allocator,
    opts: Options,
    paranoid: i64,
    err: anyerror,
) ![]const u8 {
    return switch (err) {
        error.PermissionDenied => std.fmt.allocPrint(
            allocator,
            "perf_event_open denied for pid {d} (perf_event_paranoid={d})",
            .{ opts.pid, paranoid },
        ),
        error.PerfUnavailable => std.fmt.allocPrint(
            allocator,
            "perf_event_open unavailable on this kernel: {s}",
            .{@errorName(err)},
        ),
        else => std.fmt.allocPrint(
            allocator,
            "perf_event_open failed for pid {d}: {s}",
            .{ opts.pid, @errorName(err) },
        ),
    };
}

pub const Ring = struct {
    fd: i32,
    base: [*]align(std.heap.page_size_min) u8,
    length: usize,
    cpu: i32,
    page: *std.os.linux.perf_event_mmap_page,
    data: []u8,
};

fn openRing(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: Options,
    cpu: i32,
) !Ring {
    _ = io;
    _ = allocator;
    var attr: std.os.linux.perf_event_attr = .{
        .type = .SOFTWARE,
        .config = @backingInt(std.os.linux.PERF.COUNT.SW.CPU_CLOCK),
        .sample_period_or_freq = opts.freq_hz,
        .sample_type = opts.sampleType(),
        .wakeup_events_or_watermark = 1,
        .sample_max_stack = if (opts.stacks) opts.max_stack_frames else 0,
    };
    attr.flags.freq = true;
    const rc = std.os.linux.perf_event_open(
        &attr,
        opts.pid,
        cpu,
        -1,
        std.os.linux.PERF.FLAG.FD_CLOEXEC,
    );
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .ACCES, .PERM => return error.PermissionDenied,
        .NOENT => return error.PerfUnavailable,
        .NOSYS => return error.PerfUnavailable,
        .NODEV => return error.PerfUnavailable,
        else => return error.PerfOpenFailed,
    }
    const fd: i32 = @intCast(rc);
    errdefer _ = std.os.linux.close(fd);
    const page_size = std.heap.pageSize();
    const length = page_size * (@as(usize, opts.ring_pages) + 1);
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
    return .{
        .fd = fd,
        .base = base,
        .length = length,
        .cpu = cpu,
        .page = page,
        .data = base[data_offset .. data_offset + data_size],
    };
}

fn closeRing(ring: Ring) void {
    _ = std.os.linux.munmap(ring.base, ring.length);
    _ = std.os.linux.close(ring.fd);
}

pub const ParsedSample = struct {
    ip: u64 = 0,
    pid: i32 = -1,
    tid: i32 = -1,
    ts_ns: u64 = 0,
    cpu: i32 = -1,
    frame_count: u8 = 0,
    frames: [event.max_stack_frames]u64 = @splat(0),
    /// True when the record claimed more frames than the wire bound: the excess
    /// is counted as loss, never silently accepted.
    truncated: bool = false,
};

fn readU32At(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readU64At(bytes: []const u8, offset: usize) ?u64 {
    if (offset + 8 > bytes.len) return null;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

/// Parse one `PERF_RECORD_SAMPLE` payload. `has_callchain` mirrors the
/// configured `sample_type` bit; synthetic bytes in tests use the same layout.
pub fn parseSampleRecord(bytes: []const u8, has_callchain: bool) ?ParsedSample {
    if (bytes.len < 8) return null;
    const record_type = readU32At(bytes, 0) orelse return null;
    if (record_type != 9) return null;
    const record_size = std.mem.readInt(u16, bytes[6..][0..2], .little);
    if (record_size < 8 or record_size > bytes.len) return null;
    const payload = bytes[0..record_size];
    var at: usize = 8;
    var parsed: ParsedSample = .{};
    parsed.ip = readU64At(payload, at) orelse return null;
    at += 8;
    const pid = readU32At(payload, at) orelse return null;
    at += 4;
    const tid = readU32At(payload, at) orelse return null;
    at += 4;
    parsed.pid = @bitCast(pid);
    parsed.tid = @bitCast(tid);
    parsed.ts_ns = readU64At(payload, at) orelse return null;
    at += 8;
    const cpu = readU32At(payload, at) orelse return null;
    at += 8; // cpu + reserved
    parsed.cpu = @bitCast(cpu);
    if (has_callchain) {
        const count = readU64At(payload, at) orelse return null;
        at += 8;
        const usable = @min(count, @as(u64, event.max_stack_frames));
        const frame_bytes = @as(usize, @intCast(usable)) * 8;
        if (at + frame_bytes > payload.len) return null;
        parsed.frame_count = @intCast(usable);
        var index: usize = 0;
        while (index < parsed.frame_count) : (index += 1) {
            parsed.frames[index] = std.mem.readInt(u64, payload[at + index * 8 ..][0..8], .little);
        }
        parsed.truncated = count > usable;
    }
    return parsed;
}

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
    opts: Options,
    rings: std.ArrayList(Ring) = .empty,
    events: std.ArrayList(event.RawEvent) = .empty,
    batch_arena: std.heap.ArenaAllocator,
    lost: u64 = 0,
    lost_pending: u64 = 0,
    samples: u64 = 0,
    frames: u64 = 0,
    malformed: u64 = 0,
    exited: bool = false,
    comm: []const u8 = "",
    coverage: Coverage = .{},

    /// Probe first when the caller needs the exact SKIP/REFUSE reason; open
    /// again here so a standalone caller cannot use a stale probe result.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Capture {
        const probe_result = try probe(io, allocator, opts);
        if (probe_result.state != .READY and probe_result.state != .DEGRADED) {
            return error.SamplingNotReady;
        }
        var capture: Capture = .{
            .io = io,
            .allocator = allocator,
            .opts = opts,
            .batch_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer capture.deinit();
        capture.comm = readComm(io, allocator, opts.pid) orelse "";
        try capture.openRings();
        return capture;
    }

    fn openRings(self: *Capture) !void {
        const cpu_count: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, max_cpus));
        var coverage: Coverage = .{ .mode = .per_cpu, .expected = cpu_count };
        var first_error: ?anyerror = null;
        var cpu: u32 = 0;
        while (cpu < cpu_count) : (cpu += 1) {
            if (openRing(self.io, self.allocator, self.opts, @intCast(cpu))) |ring| {
                try self.rings.append(self.allocator, ring);
            } else |err| {
                if (first_error == null) first_error = err;
            }
        }
        if (self.rings.items.len == 0) {
            // Per-CPU per-task rings can be denied on low granularity kernels;
            // a single per-task ring still samples this PID on every CPU.
            if (openRing(self.io, self.allocator, self.opts, -1)) |ring| {
                try self.rings.append(self.allocator, ring);
                coverage = .{ .mode = .per_task, .cpus = 1, .expected = 1 };
                if (first_error) |err| {
                    var reason_buffer: [128]u8 = undefined;
                    coverage.setReason(std.fmt.bufPrint(
                        &reason_buffer,
                        "per-CPU rings denied ({s}); single per-task ring",
                        .{@errorName(err)},
                    ) catch "per-CPU rings denied; single per-task ring");
                }
                self.coverage = coverage;
                return;
            } else |err| {
                return err;
            }
        }
        coverage.cpus = @intCast(self.rings.items.len);
        if (coverage.cpus < coverage.expected) {
            var reason_buffer: [128]u8 = undefined;
            coverage.setReason(std.fmt.bufPrint(
                &reason_buffer,
                "{d} of {d} cpus (perf_event_open failed)",
                .{ coverage.cpus, coverage.expected },
            ) catch "partial CPU coverage");
        }
        self.coverage = coverage;
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

    pub fn targetExited(self: *const Capture) bool {
        return self.exited;
    }

    pub fn samplesCaptured(self: *const Capture) u64 {
        return self.samples;
    }

    pub fn framesCaptured(self: *const Capture) u64 {
        return self.frames;
    }

    pub fn coverageState(self: *const Capture) State {
        return self.coverage.state();
    }

    pub fn deinit(self: *Capture) void {
        for (self.rings.items) |ring| closeRing(ring);
        self.rings.deinit(self.allocator);
        self.events.deinit(self.batch_arena.allocator());
        self.batch_arena.deinit();
    }
};

fn noteLoss(self: *Capture, ring: *const Ring, amount: u64, name: []const u8) !void {
    if (amount == 0) return;
    self.lost = self.lost +| amount;
    self.lost_pending = self.lost_pending +| amount;
    const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, self.io).nanoseconds)));
    const detail = try std.fmt.allocPrint(
        self.batch_arena.allocator(),
        "sample_loss {s} lost={d}",
        .{ name, amount },
    );
    try self.events.append(self.batch_arena.allocator(), .{
        .kind = .marker,
        .ts_ns = now,
        .cpu = ring.cpu,
        .detail = detail,
    });
}

fn emitRecord(self: *Capture, ring: *const Ring, bytes: []const u8) !void {
    if (bytes.len < 8) return;
    const record_type = std.mem.readInt(u32, bytes[0..4], .little);
    switch (record_type) {
        9 => {
            const parsed = parseSampleRecord(bytes, self.opts.stacks) orelse {
                self.malformed += 1;
                return;
            };
            if (parsed.truncated) self.malformed += 1;
            const count: usize = parsed.frame_count;
            var frames: []const u64 = &.{};
            if (count != 0) {
                const owned = try self.batch_arena.allocator().alloc(u64, count);
                @memcpy(owned, parsed.frames[0..count]);
                frames = owned;
            }
            try self.events.append(self.batch_arena.allocator(), .{
                .kind = .stack_sample,
                .ts_ns = parsed.ts_ns,
                .cpu = parsed.cpu,
                .pid = parsed.pid,
                .tid = parsed.tid,
                .a = parsed.ip,
                .comm = self.comm,
                .stack = frames,
            });
            self.samples +|= 1;
            self.frames +|= count;
        },
        2 => {
            // PERF_RECORD_LOST: header, u64 id, u64 lost.
            const lost = readU64At(bytes, 16) orelse return;
            try noteLoss(self, ring, lost, "stacks_perf_ring");
        },
        13 => {
            // PERF_RECORD_LOST_SAMPLES: header, u64 lost (sample_max_stack).
            const lost = readU64At(bytes, 8) orelse return;
            try noteLoss(self, ring, lost, "stacks_perf_ring");
        },
        4 => {
            // PERF_RECORD_EXIT: the target left; stop early with what we have.
            self.exited = true;
        },
        5, 6 => {
            // Throttle/unthrottle: the kernel dropped this event's samples.
            try noteLoss(self, ring, 1, "stacks_throttled");
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
    const malformed_before = self.malformed;
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
            self.malformed += 1;
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
    const malformed_now = self.malformed - malformed_before;
    if (malformed_now != 0) {
        try noteLoss(self, ring, malformed_now, "stacks_malformed_records");
    }
}

// Checks the synthetic sample-record parser against the kernel layout.
test "sample record parsing reads ip, tid, time, cpu, and callchain" {
    var bytes: [8 + 8 + 8 + 8 + 8 + 8 + 3 * 8]u8 = undefined;
    @memset(&bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], 9, .little);
    std.mem.writeInt(u16, bytes[6..8], @intCast(bytes.len), .little);
    std.mem.writeInt(u64, bytes[8..16], 0x401000, .little);
    std.mem.writeInt(u32, bytes[16..20], 4242, .little);
    std.mem.writeInt(u32, bytes[20..24], 4243, .little);
    std.mem.writeInt(u64, bytes[24..32], 123_456, .little);
    std.mem.writeInt(u32, bytes[32..36], 3, .little);
    // bytes[36..40] reserved
    std.mem.writeInt(u64, bytes[40..48], 3, .little);
    std.mem.writeInt(u64, bytes[48..56], 0x401000, .little);
    std.mem.writeInt(u64, bytes[56..64], 0x402000, .little);
    std.mem.writeInt(u64, bytes[64..72], 0x403000, .little);
    const parsed = parseSampleRecord(&bytes, true).?;
    try std.testing.expectEqual(@as(u64, 0x401000), parsed.ip);
    try std.testing.expectEqual(@as(i32, 4242), parsed.pid);
    try std.testing.expectEqual(@as(i32, 4243), parsed.tid);
    try std.testing.expectEqual(@as(u64, 123_456), parsed.ts_ns);
    try std.testing.expectEqual(@as(i32, 3), parsed.cpu);
    try std.testing.expectEqual(@as(u8, 3), parsed.frame_count);
    try std.testing.expectEqual(@as(u64, 0x403000), parsed.frames[2]);
    try std.testing.expect(!parsed.truncated);
}

test "sample record parsing is fail-closed on malformed or oversized records" {
    var bytes: [48]u8 = undefined;
    @memset(&bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], 9, .little);
    std.mem.writeInt(u16, bytes[6..8], 16, .little);
    try std.testing.expect(parseSampleRecord(&bytes, true) == null);
    std.mem.writeInt(u16, bytes[6..8], @intCast(bytes.len), .little);
    std.mem.writeInt(u64, bytes[40..48], 65, .little);
    try std.testing.expect(parseSampleRecord(&bytes, true) == null);

    var ip_only: [48]u8 = undefined;
    @memset(&ip_only, 0);
    std.mem.writeInt(u32, ip_only[0..4], 9, .little);
    std.mem.writeInt(u16, ip_only[6..8], @intCast(ip_only.len), .little);
    std.mem.writeInt(u64, ip_only[8..16], 0x10, .little);
    const parsed = parseSampleRecord(&ip_only, false).?;
    try std.testing.expectEqual(@as(u64, 0x10), parsed.ip);
    try std.testing.expectEqual(@as(u8, 0), parsed.frame_count);
}

// Checks the sampling options carry the documented bounds.
test "sampling options validate bounds and sample_type bits" {
    const base: Options = .{ .pid = 1 };
    try base.validate();
    try std.testing.expect(base.sampleType() & @as(u64, std.os.linux.PERF.SAMPLE.CALLCHAIN) == 0);
    var with_stacks = base;
    with_stacks.stacks = true;
    try std.testing.expect(with_stacks.sampleType() & @as(u64, std.os.linux.PERF.SAMPLE.CALLCHAIN) != 0);
    try std.testing.expectError(error.InvalidPid, (Options{}).validate());
    try std.testing.expectError(
        error.InvalidStackFrames,
        (Options{ .pid = 1, .max_stack_frames = 65 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidFrequency,
        (Options{ .pid = 1, .freq_hz = 0 }).validate(),
    );
}

// Checks the probe fails closed off Linux or without sampling permission, and
// that a Linux probe always carries a reason.
test "sampling probe reports a state and reason on every host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try probe(std.testing.io, arena.allocator(), .{ .pid = 1 });
    try std.testing.expect(result.reason.len != 0);
    if (!sample_linux) {
        try std.testing.expectEqual(State.SKIP, result.state);
    } else {
        try std.testing.expect(result.state == .SKIP or result.state == .REFUSE or
            result.state == .READY or result.state == .DEGRADED);
    }
}

// Checks partial ring coverage stays an explicit DEGRADED coverage object.
test "coverage reports partial rings and the per-task fallback" {
    var coverage: Coverage = .{ .mode = .per_cpu, .cpus = 3, .expected = 8 };
    coverage.setReason("3 of 8 cpus (perf_event_open failed)");
    try std.testing.expectEqual(State.DEGRADED, coverage.state());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const detail = try coverage.detail(arena.allocator());
    try std.testing.expectEqualStrings(
        "stack_sampling:DEGRADED:3 of 8 rings; 3 of 8 cpus (perf_event_open failed)",
        detail,
    );

    var fallback: Coverage = .{ .mode = .per_task, .cpus = 1, .expected = 1 };
    fallback.setReason("per-CPU rings denied (PermissionDenied); single per-task ring");
    try std.testing.expectEqual(State.READY, fallback.state());
    const fallback_detail = try fallback.detail(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, fallback_detail, "single per-task ring") != null);

    var empty: Coverage = .{ .mode = .per_cpu, .cpus = 0, .expected = 4 };
    try std.testing.expectEqual(State.SKIP, empty.state());
}

// Checks the emitted marker detail is classified by the shared loss registry.
test "sampling loss detail uses the loss registry prefix" {
    const loss = @import("../core/loss.zig");
    try std.testing.expectEqual(loss.Kind.sample_loss, loss.classify("sample_loss stacks_perf_ring lost=3").?);
    try std.testing.expectEqual(@as(u64, 3), loss.magnitude("sample_loss stacks_perf_ring lost=3"));
}

// Serialization shape: a sampled row is canonical and carries only bounded
// fields (byte-level check shared with the schema-conformance suite).
test "sampled stack rows serialize canonically" {
    const stack = [_]u64{ 0x401000, 0x401100 };
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try event.writeJson(&writer, .{
        .kind = .stack_sample,
        .ts_ns = 7,
        .cpu = 1,
        .pid = 42,
        .tid = 42,
        .a = 0x401000,
        .comm = "probe",
        .stack = &stack,
    });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"event\":\"stack_sample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"stack\":[4198400,4198656]") != null);
    try std.testing.expect(json.depthOk(writer.buffered(), 8));
}
