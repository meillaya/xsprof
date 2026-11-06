//! Perf ring and tracepoint-format plumbing for the read-only collector.
//! Kept separate from `live.zig` so the capture API stays under the line limit
//! and the syscall surface is testable in isolation.

const std = @import("std");

pub const RingKind = enum { switch_, wakeup, migrate, faults_minor, faults_major, faults_combined };

pub const Fields = struct {
    prev_comm: u16 = 0,
    prev_pid: u16 = 0,
    next_comm: u16 = 0,
    next_pid: u16 = 0,
    prev_state: u16 = 0,
    comm: u16 = 0,
    pid: u16 = 0,
    target_cpu: u16 = 0,
    orig_cpu: u16 = 0,
    dest_cpu: u16 = 0,
    valid: bool = false,
};

pub const Ring = struct {
    fd: i32,
    base: [*]align(std.heap.page_size_min) u8,
    length: usize,
    kind: RingKind,
    cpu: u32,
    fields: Fields,
    page: *std.os.linux.perf_event_mmap_page,
    data: []u8,

    pub fn isFault(self: Ring) bool {
        return switch (self.kind) {
            .faults_minor, .faults_major, .faults_combined => true,
            else => false,
        };
    }
};

pub fn readFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max: usize,
) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max)) catch null;
}

pub fn parseFormat(text: []const u8) Fields {
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
        if (std.mem.eql(u8, name, "prev_state")) fields.prev_state = offset;
        if (std.mem.eql(u8, name, "comm")) fields.comm = offset;
        if (std.mem.eql(u8, name, "pid")) fields.pid = offset;
        if (std.mem.eql(u8, name, "target_cpu")) fields.target_cpu = offset;
        if (std.mem.eql(u8, name, "orig_cpu")) fields.orig_cpu = offset;
        if (std.mem.eql(u8, name, "dest_cpu")) fields.dest_cpu = offset;
    }
    return fields;
}

pub fn tracepointId(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
) !u64 {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/events/sched/{s}/id", .{ root, name });
    const text = readFile(io, allocator, path, 64) orelse return error.TracepointUnavailable;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch error.TracepointUnavailable;
}

pub fn formatFor(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
) !Fields {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/events/sched/{s}/format", .{ root, name });
    const text = readFile(io, allocator, path, 64 * 1024) orelse return error.TracepointUnavailable;
    return parseFormat(text);
}

fn configFor(kind: RingKind) ?u64 {
    return switch (kind) {
        .faults_minor => @backingInt(std.os.linux.PERF.COUNT.SW.PAGE_FAULTS_MIN),
        .faults_major => @backingInt(std.os.linux.PERF.COUNT.SW.PAGE_FAULTS_MAJ),
        .faults_combined => @backingInt(std.os.linux.PERF.COUNT.SW.PAGE_FAULTS),
        else => null,
    };
}

pub fn openRing(kind: RingKind, cpu: u32, id: u64, fields: Fields, ring_pages: u16) !Ring {
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
    if (configFor(kind)) |config| {
        attr.type = .SOFTWARE;
        attr.config = config;
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

test "tracepoint format offsets parse" {
    const text =
        "field:unsigned short common_type;\toffset:0;\tsize:2;\n" ++
        "field:char prev_comm[16];\toffset:8;\tsize:16;\n" ++
        "field:pid_t prev_pid;\toffset:24;\tsize:4;\n" ++
        "field:char next_comm[16];\toffset:40;\tsize:16;\n";
    const fields = parseFormat(text);
    try std.testing.expect(fields.valid);
    try std.testing.expectEqual(@as(u16, 8), fields.prev_comm);
    try std.testing.expectEqual(@as(u16, 24), fields.prev_pid);
    try std.testing.expectEqual(@as(u16, 40), fields.next_comm);
}

test "fault ring configs are distinct" {
    try std.testing.expect(configFor(.faults_minor) != null);
    try std.testing.expect(configFor(.faults_major) != null);
    try std.testing.expect(configFor(.faults_minor) != configFor(.faults_major));
    try std.testing.expect(configFor(.switch_) == null);
}
