//! Read-only Linux host facts and capability probes.
//!
//! On non-Linux hosts every probe returns SKIP/REFUSE with a reason and the
//! facts snapshot stays empty. Nothing here writes to the host.

const std = @import("std");
const builtin = @import("builtin");
const json = @import("../../core/json.zig");

const Writer = std.Io.Writer;

pub const CapState = enum { ready, degraded, skip, refuse };

pub fn capStateName(state: CapState) []const u8 {
    return switch (state) {
        .ready => "READY",
        .degraded => "DEGRADED",
        .skip => "SKIP",
        .refuse => "REFUSE",
    };
}

pub const Capability = struct {
    name: []const u8,
    state: CapState = .skip,
    reason: []const u8 = "",
};

pub const CpuStat = struct {
    user: u64 = 0,
    nice: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,
    iowait: u64 = 0,
    irq: u64 = 0,
    softirq: u64 = 0,
    steal: u64 = 0,
};

pub const MemInfo = struct {
    mem_total_kb: i64 = 0,
    mem_available_kb: i64 = 0,
    huge_pages_total: i64 = 0,
    huge_pages_free: i64 = 0,
    hugepage_size_kb: i64 = 0,
};

pub const NumaNode = struct {
    id: i32 = -1,
    cpus: []const u8 = "",
};

pub const SchedExt = struct {
    present: bool = false,
    state: []const u8 = "",
    switch_all: []const u8 = "",
    nr_rejected: []const u8 = "",
    enable_seq: []const u8 = "",
    hotplug_seq: []const u8 = "",
};

pub const Facts = struct {
    hostname: []const u8 = "",
    kernel_release: []const u8 = "",
    online_cpus: u32 = 0,
    per_cpu_count: u32 = 0,
    aggregate_cpu: CpuStat = .{},
    mem: MemInfo = .{},
    buddyinfo: []const []const u8 = &.{},
    numa_nodes: []const NumaNode = &.{},
    sched_ext: SchedExt = .{},
    perf_event_paranoid: i32 = 99,
    kptr_restrict: i32 = 99,
    btf_present: bool = false,
    tracefs_present: bool = false,
    process_count: u32 = 0,
};

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn parseI64(value: []const u8, default: i64) i64 {
    return std.fmt.parseInt(i64, trim(value), 10) catch default;
}

fn readFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max: usize,
) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max)) catch null;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn readTrimmed(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max: usize,
) []const u8 {
    const value = readFile(io, allocator, path, max) orelse return "";
    return trim(value);
}

fn appendCpuLine(line: []const u8, stat: *CpuStat) bool {
    if (!std.mem.startsWith(u8, line, "cpu")) return false;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next() orelse return false;
    const fields = [_]*u64{
        &stat.user,   &stat.nice, &stat.system,  &stat.idle,
        &stat.iowait, &stat.irq,  &stat.softirq, &stat.steal,
    };
    for (fields) |field| {
        const token = it.next() orelse break;
        field.* = std.fmt.parseInt(u64, token, 10) catch 0;
    }
    return true;
}

fn collectFactsLinux(io: std.Io, allocator: std.mem.Allocator) !Facts {
    var facts: Facts = .{};
    facts.hostname = readTrimmed(io, allocator, "/proc/sys/kernel/hostname", 512);
    facts.kernel_release = readTrimmed(io, allocator, "/proc/sys/kernel/osrelease", 512);

    if (readFile(io, allocator, "/proc/stat", 1 << 20)) |contents| {
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            var stat: CpuStat = .{};
            if (!appendCpuLine(line, &stat)) continue;
            if (std.mem.startsWith(u8, line, "cpu ")) {
                facts.aggregate_cpu = stat;
            } else {
                facts.per_cpu_count += 1;
            }
        }
    }
    facts.online_cpus = facts.per_cpu_count;

    if (readFile(io, allocator, "/proc/meminfo", 1 << 20)) |contents| {
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            var it = std.mem.tokenizeAny(u8, line, " \t");
            const key = it.next() orelse continue;
            const raw = it.next() orelse continue;
            const value = std.fmt.parseInt(i64, raw, 10) catch continue;
            if (std.mem.eql(u8, key, "MemTotal:")) {
                facts.mem.mem_total_kb = value;
            } else if (std.mem.eql(u8, key, "MemAvailable:")) {
                facts.mem.mem_available_kb = value;
            } else if (std.mem.eql(u8, key, "HugePages_Total:")) {
                facts.mem.huge_pages_total = value;
            } else if (std.mem.eql(u8, key, "HugePages_Free:")) {
                facts.mem.huge_pages_free = value;
            } else if (std.mem.eql(u8, key, "Hugepagesize:")) {
                facts.mem.hugepage_size_kb = value;
            }
        }
    }

    if (readFile(io, allocator, "/proc/buddyinfo", 1 << 20)) |contents| {
        var list: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const value = trim(line);
            if (value.len != 0) try list.append(allocator, value);
        }
        facts.buddyinfo = try list.toOwnedSlice(allocator);
    }

    facts.numa_nodes = collectNuma(io, allocator) catch &.{};
    facts.sched_ext = collectSchedExt(io, allocator);
    facts.perf_event_paranoid = std.math.cast(i32, parseI64(
        readTrimmed(io, allocator, "/proc/sys/kernel/perf_event_paranoid", 64),
        99,
    )) orelse 99;
    facts.kptr_restrict = std.math.cast(i32, parseI64(
        readTrimmed(io, allocator, "/proc/sys/kernel/kptr_restrict", 64),
        99,
    )) orelse 99;
    facts.btf_present = exists(io, "/sys/kernel/btf/vmlinux");
    facts.tracefs_present = exists(io, "/sys/kernel/tracing");
    facts.process_count = countProcesses(io);
    return facts;
}

fn collectNuma(io: std.Io, allocator: std.mem.Allocator) ![]NumaNode {
    var list: std.ArrayList(NumaNode) = .empty;
    const dir = std.Io.Dir.openDirAbsolute(io, "/sys/devices/system/node", .{ .iterate = true }) catch
        return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "node")) continue;
        const id = std.fmt.parseInt(i32, entry.name[4..], 10) catch continue;
        var path_buffer: [256]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "/sys/devices/system/node/{s}/cpulist",
            .{entry.name},
        ) catch continue;
        try list.append(allocator, .{
            .id = id,
            .cpus = readTrimmed(io, allocator, path, 4096),
        });
    }
    return list.toOwnedSlice(allocator);
}

fn collectSchedExt(io: std.Io, allocator: std.mem.Allocator) SchedExt {
    if (!exists(io, "/sys/kernel/sched_ext")) return .{};
    return .{
        .present = true,
        .state = readTrimmed(io, allocator, "/sys/kernel/sched_ext/state", 128),
        .switch_all = readTrimmed(io, allocator, "/sys/kernel/sched_ext/switch_all", 128),
        .nr_rejected = readTrimmed(io, allocator, "/sys/kernel/sched_ext/nr_rejected", 128),
        .enable_seq = readTrimmed(io, allocator, "/sys/kernel/sched_ext/enable_seq", 128),
        .hotplug_seq = readTrimmed(io, allocator, "/sys/kernel/sched_ext/hotplug_seq", 128),
    };
}

fn countProcesses(io: std.Io) u32 {
    var count: u32 = 0;
    const dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0) continue;
        var numeric = entry.name.len != 0;
        for (entry.name) |c| {
            if (!std.ascii.isDigit(c)) {
                numeric = false;
                break;
            }
        }
        if (numeric) {
            var path_buffer: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buffer, "/proc/{s}/stat", .{entry.name}) catch continue;
            if (exists(io, path)) count += 1;
            if (count >= 1_000_000) break;
        }
    }
    return count;
}

fn collectFactsNonLinux() Facts {
    return .{};
}

pub fn collectFacts(io: std.Io, allocator: std.mem.Allocator) !Facts {
    if (builtin.os.tag != .linux) return collectFactsNonLinux();
    return collectFactsLinux(io, allocator);
}

fn capsNonLinux(allocator: std.mem.Allocator) ![]Capability {
    const caps = try allocator.alloc(Capability, 5);
    caps[0] = .{
        .name = "perf_event",
        .state = .skip,
        .reason = "non-Linux host: perf_event_paranoid unavailable",
    };
    caps[1] = .{
        .name = "sched_tracepoints",
        .state = .refuse,
        .reason = "non-Linux host: tracefs unavailable",
    };
    caps[2] = .{
        .name = "btf",
        .state = .skip,
        .reason = "non-Linux host: no kernel BTF",
    };
    caps[3] = .{
        .name = "sched_ext",
        .state = .skip,
        .reason = "non-Linux host: sched_ext unavailable",
    };
    caps[4] = .{
        .name = "pmu",
        .state = .skip,
        .reason = "non-Linux host: no PMU devices",
    };
    return caps;
}

fn pmuCapability(io: std.Io, allocator: std.mem.Allocator) !Capability {
    const dir = std.Io.Dir.openDirAbsolute(
        io,
        "/sys/bus/event_source/devices",
        .{ .iterate = true },
    ) catch return .{ .name = "pmu", .state = .skip, .reason = "no PMU devices found" };
    defer dir.close(io);
    var names: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (count != 0) try names.append(allocator, ',');
        try names.appendSlice(allocator, entry.name);
        count += 1;
    }
    if (count == 0) {
        return .{ .name = "pmu", .state = .skip, .reason = "no PMU devices found" };
    }
    const joined = try names.toOwnedSlice(allocator);
    return .{
        .name = "pmu",
        .state = .ready,
        .reason = try std.fmt.allocPrint(
            allocator,
            "{d} PMU devices: {s}",
            .{ count, joined },
        ),
    };
}

fn capsLinux(io: std.Io, allocator: std.mem.Allocator) ![]Capability {
    const caps = try allocator.alloc(Capability, 5);

    const paranoid_raw = readTrimmed(io, allocator, "/proc/sys/kernel/perf_event_paranoid", 64);
    if (paranoid_raw.len == 0) {
        caps[0] = .{ .name = "perf_event", .state = .skip, .reason = "perf_event_paranoid unreadable" };
    } else {
        const paranoid = parseI64(paranoid_raw, 99);
        if (paranoid <= 1) {
            caps[0] = .{
                .name = "perf_event",
                .state = .ready,
                .reason = try std.fmt.allocPrint(
                    allocator,
                    "perf_event_paranoid={d} (PMU/tracepoint collection permitted)",
                    .{paranoid},
                ),
            };
        } else {
            caps[0] = .{
                .name = "perf_event",
                .state = .skip,
                .reason = try std.fmt.allocPrint(
                    allocator,
                    "perf_event_paranoid={d} (need CAP_PERFMON or paranoid<=1; fail-closed SKIP)",
                    .{paranoid},
                ),
            };
        }
    }

    const sched_format = "/sys/kernel/tracing/events/sched/sched_switch/format";
    if (exists(io, sched_format)) {
        caps[1] = .{
            .name = "sched_tracepoints",
            .state = .ready,
            .reason = "sched:sched_switch format readable",
        };
    } else if (exists(io, "/sys/kernel/tracing")) {
        caps[1] = .{
            .name = "sched_tracepoints",
            .state = .skip,
            .reason = "tracefs mounted but /sys/kernel/tracing/events/sched " ++
                "permission denied (fail-closed SKIP)",
        };
    } else {
        caps[1] = .{
            .name = "sched_tracepoints",
            .state = .refuse,
            .reason = "tracefs not mounted",
        };
    }

    caps[2] = if (exists(io, "/sys/kernel/btf/vmlinux"))
        .{
            .name = "btf",
            .state = .ready,
            .reason = "/sys/kernel/btf/vmlinux present (CO-RE BPF possible)",
        }
    else
        .{ .name = "btf", .state = .skip, .reason = "no kernel BTF" };

    caps[3] = if (exists(io, "/sys/kernel/sched_ext"))
        .{
            .name = "sched_ext",
            .state = .ready,
            .reason = "/sys/kernel/sched_ext present (read-only observation; load is VM-lab-only)",
        }
    else
        .{ .name = "sched_ext", .state = .skip, .reason = "sched_ext not present" };

    caps[4] = try pmuCapability(io, allocator);
    return caps;
}

pub fn probeCapabilities(io: std.Io, allocator: std.mem.Allocator) ![]Capability {
    if (builtin.os.tag != .linux) return capsNonLinux(allocator);
    return capsLinux(io, allocator);
}

fn writeCapability(w: *Writer, cap: Capability) Writer.Error!void {
    try json.write(w, .{ .object = &.{
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "name", .value = .{ .string = cap.name } },
        .{ .key = "reason", .value = .{ .string = cap.reason } },
        .{ .key = "state", .value = .{ .string = capStateName(cap.state) } },
    } });
}

pub fn writeCapabilities(w: *Writer, caps: []const Capability) Writer.Error!void {
    try w.writeByte('[');
    for (caps, 0..) |cap, i| {
        if (i != 0) try w.writeByte(',');
        try writeCapability(w, cap);
    }
    try w.writeByte(']');
}

fn writeCpu(w: *Writer, stats: CpuStat, per_cpu_count: u32) Writer.Error!void {
    try json.write(w, .{ .object = &.{
        .{ .key = "idle", .value = .{ .unsigned = stats.idle } },
        .{ .key = "iowait", .value = .{ .unsigned = stats.iowait } },
        .{ .key = "irq", .value = .{ .unsigned = stats.irq } },
        .{ .key = "nice", .value = .{ .unsigned = stats.nice } },
        .{ .key = "per_cpu_count", .value = .{ .unsigned = per_cpu_count } },
        .{ .key = "softirq", .value = .{ .unsigned = stats.softirq } },
        .{ .key = "steal", .value = .{ .unsigned = stats.steal } },
        .{ .key = "system", .value = .{ .unsigned = stats.system } },
        .{ .key = "user", .value = .{ .unsigned = stats.user } },
    } });
}

fn writeMemory(w: *Writer, mem: MemInfo) Writer.Error!void {
    try json.write(w, .{ .object = &.{
        .{ .key = "huge_pages_free", .value = .{ .integer = mem.huge_pages_free } },
        .{ .key = "huge_pages_total", .value = .{ .integer = mem.huge_pages_total } },
        .{ .key = "hugepage_size_kb", .value = .{ .integer = mem.hugepage_size_kb } },
        .{ .key = "mem_available_kb", .value = .{ .integer = mem.mem_available_kb } },
        .{ .key = "mem_total_kb", .value = .{ .integer = mem.mem_total_kb } },
    } });
}

fn writeSchedExt(w: *Writer, state: SchedExt) Writer.Error!void {
    try json.write(w, .{ .object = &.{
        .{ .key = "enable_seq", .value = .{ .string = state.enable_seq } },
        .{ .key = "hotplug_seq", .value = .{ .string = state.hotplug_seq } },
        .{ .key = "nr_rejected", .value = .{ .string = state.nr_rejected } },
        .{ .key = "present", .value = .{ .boolean = state.present } },
        .{ .key = "state", .value = .{ .string = state.state } },
        .{ .key = "switch_all", .value = .{ .string = state.switch_all } },
    } });
}

pub fn writeFacts(w: *Writer, facts: Facts) Writer.Error!void {
    try w.writeByte('{');
    try w.writeAll("\"btf_present\":");
    try json.write(w, .{ .boolean = facts.btf_present });
    try w.writeAll(",\"buddyinfo\":[");
    for (facts.buddyinfo, 0..) |line, i| {
        if (i != 0) try w.writeByte(',');
        try json.write(w, .{ .string = line });
    }
    try w.writeAll("],\"cpu\":");
    try writeCpu(w, facts.aggregate_cpu, facts.per_cpu_count);
    try w.writeAll(",\"host_mutation\":false,\"hostname\":");
    try json.write(w, .{ .string = facts.hostname });
    try w.writeAll(",\"kernel_release\":");
    try json.write(w, .{ .string = facts.kernel_release });
    try w.writeAll(",\"kptr_restrict\":");
    try json.write(w, .{ .integer = facts.kptr_restrict });
    try w.writeAll(",\"memory\":");
    try writeMemory(w, facts.mem);
    try w.writeAll(",\"numa_nodes\":[");
    for (facts.numa_nodes, 0..) |node, i| {
        if (i != 0) try w.writeByte(',');
        try json.write(w, .{ .object = &.{
            .{ .key = "cpus", .value = .{ .string = node.cpus } },
            .{ .key = "id", .value = .{ .integer = node.id } },
        } });
    }
    try w.writeAll("],\"online_cpus\":");
    try json.write(w, .{ .unsigned = facts.online_cpus });
    try w.writeAll(",\"perf_event_paranoid\":");
    try json.write(w, .{ .integer = facts.perf_event_paranoid });
    try w.writeAll(",\"process_count\":");
    try json.write(w, .{ .unsigned = facts.process_count });
    try w.writeAll(",\"sched_ext\":");
    try writeSchedExt(w, facts.sched_ext);
    try w.writeAll(",\"tracefs_present\":");
    try json.write(w, .{ .boolean = facts.tracefs_present });
    try w.writeByte('}');
}

pub fn writePreflight(
    w: *Writer,
    caps: []const Capability,
    facts: Facts,
) Writer.Error!void {
    try w.writeAll("{\"capabilities\":");
    try writeCapabilities(w, caps);
    try w.writeAll(",\"facts\":");
    try writeFacts(w, facts);
    try w.writeAll(",\"host_mutation\":false,\"schema\":\"xsprof/preflight/v1\"," ++
        "\"tool\":\"xsprof\"}\n");
}

test "non-Linux probes fail closed with reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const caps = try probeCapabilities(std.testing.io, arena.allocator());
    try std.testing.expectEqual(@as(usize, 5), caps.len);
    for (caps) |cap| {
        try std.testing.expect(cap.state == .skip or cap.state == .refuse);
        try std.testing.expect(cap.reason.len != 0);
    }
    const facts = try collectFacts(std.testing.io, arena.allocator());
    try std.testing.expectEqual(@as(u32, 0), facts.online_cpus);
    try std.testing.expectEqual(@as(i32, 99), facts.perf_event_paranoid);
}

test "preflight serialization carries host_mutation=false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const caps = try probeCapabilities(std.testing.io, arena.allocator());
    const facts = try collectFacts(std.testing.io, arena.allocator());
    var buf: [8192]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writePreflight(&w, caps, facts);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"schema\":\"xsprof/preflight/v1\"") != null);
}
