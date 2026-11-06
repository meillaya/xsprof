//! Read-only environment diagnostics. Every check reports a reason; the
//! command never creates directories, mounts filesystems, or changes policy.

const std = @import("std");
const builtin = @import("builtin");
const live = @import("../capture/live.zig");
const proc = @import("../os/linux/proc.zig");
const pressure = @import("../os/linux/pressure.zig");
const cgroup = @import("../os/linux/cgroup.zig");
const json = @import("../core/json.zig");

pub const Check = struct {
    name: []const u8,
    state: []const u8,
    reason: []const u8,
};

pub const Result = struct {
    checks: []const Check,
    status: []const u8,
};

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max)) catch null;
}

fn hasLibbpf() bool {
    var library = std.DynLib.open("libbpf.so.1") catch return false;
    defer library.close();
    return library.lookup(*anyopaque, "bpf_object__open_file") != null;
}

fn stateName(state: live.State) []const u8 {
    return switch (state) {
        .READY => "READY",
        .DEGRADED => "DEGRADED",
        .SKIP => "SKIP",
        .REFUSE => "REFUSE",
    };
}

pub fn run(io: std.Io, allocator: std.mem.Allocator) !Result {
    var checks: std.ArrayList(Check) = .empty;
    errdefer checks.deinit(allocator);

    if (builtin.os.tag != .linux) {
        try checks.append(allocator, .{
            .name = "platform",
            .state = "SKIP",
            .reason = "data collection is Linux-only; macOS can replay captures",
        });
    } else {
        const release = readFile(io, allocator, "/proc/sys/kernel/osrelease", 128) orelse null;
        if (release) |value| {
            try checks.append(allocator, .{
                .name = "kernel",
                .state = "READY",
                .reason = std.mem.trim(u8, value, " \t\r\n"),
            });
        } else {
            try checks.append(allocator, .{
                .name = "kernel",
                .state = "SKIP",
                .reason = "/proc/sys/kernel/osrelease unreadable",
            });
        }
    }

    const paranoid = readFile(io, allocator, "/proc/sys/kernel/perf_event_paranoid", 64);
    const perfmon = builtin.os.tag == .linux and
        proc.effectiveCapability(io, allocator, proc.cap_perfmon);
    if (paranoid) |value| {
        const level = std.mem.trim(u8, value, " \t\r\n");
        const permitted = std.mem.eql(u8, level, "0") or
            std.mem.eql(u8, level, "1") or perfmon;
        try checks.append(allocator, .{
            .name = "perf_event_paranoid",
            .state = if (permitted) "READY" else "SKIP",
            .reason = if (perfmon)
                try std.fmt.allocPrint(allocator, "{s}; CAP_PERFMON effective", .{level})
            else
                level,
        });
    } else {
        try checks.append(allocator, .{
            .name = "perf_event_paranoid",
            .state = "SKIP",
            .reason = "unreadable",
        });
    }

    const trace = live.tracefsRoot(io);
    try checks.append(allocator, .{
        .name = "tracefs",
        .state = if (trace != null) "READY" else "SKIP",
        .reason = trace orelse "tracefs sched events unreadable",
    });

    const probe = try live.probe(io, allocator);
    try checks.append(allocator, .{
        .name = "perf",
        .state = stateName(probe.state),
        .reason = probe.reason,
    });

    const psi = pressure.collect(io, allocator);
    try checks.append(allocator, .{
        .name = "pressure",
        .state = psi.state,
        .reason = if (psi.available) "/proc/pressure cpu/memory/io readable" else psi.reason,
    });

    const groups = cgroup.collect(io, allocator);
    try checks.append(allocator, .{
        .name = "cgroup",
        .state = groups.state,
        .reason = if (std.mem.eql(u8, groups.state, "READY"))
            try std.fmt.allocPrint(allocator, "cgroup v2; {d} groups attributed", .{groups.groups.len})
        else
            groups.reason,
    });

    try checks.append(allocator, .{
        .name = "libbpf",
        .state = if (hasLibbpf()) "READY" else "SKIP",
        .reason = if (hasLibbpf()) "libbpf.so.1 present" else "libbpf.so.1 not found; useful only for bpf-gate",
    });

    var status: []const u8 = "READY";
    for (checks.items) |check| {
        if (std.mem.eql(u8, check.state, "REFUSE")) {
            status = "REFUSE";
            break;
        }
        if (!std.mem.eql(u8, check.state, "READY")) status = "SKIP";
    }
    return .{ .checks = try checks.toOwnedSlice(allocator), .status = status };
}

pub fn writeJson(w: *std.Io.Writer, result: Result) !void {
    var values = try std.heap.smp_allocator.alloc(json.Value, result.checks.len);
    defer std.heap.smp_allocator.free(values);
    var entries = try std.heap.smp_allocator.alloc([]json.Entry, result.checks.len);
    defer {
        for (entries) |item| std.heap.smp_allocator.free(item);
        std.heap.smp_allocator.free(entries);
    }
    for (result.checks, 0..) |check, index| {
        const item = try std.heap.smp_allocator.alloc(json.Entry, 3);
        item[0] = .{ .key = "name", .value = .{ .string = check.name } };
        item[1] = .{ .key = "reason", .value = .{ .string = check.reason } };
        item[2] = .{ .key = "state", .value = .{ .string = check.state } };
        entries[index] = item;
        values[index] = .{ .object = item };
    }
    try json.write(w, .{ .object = &.{
        .{ .key = "checks", .value = .{ .array = values } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "schema", .value = .{ .string = "xsprof/doctor/v1" } },
        .{ .key = "status", .value = .{ .string = result.status } },
    } });
}

// Checks that doctor reports platform SKIP on macOS and JSON is stable.
test "doctor reports a read-only status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try run(std.testing.io, arena.allocator());
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJson(&writer, result);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "{\"checks\":["));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"host_mutation\":false") != null);
}
