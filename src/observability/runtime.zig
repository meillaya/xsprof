const std = @import("std");
const sched_ext = @import("../sched_ext/root.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const EventCounters = struct {
    raw: []const u8,
    nr_rejected: ?u64,
    dispatch_failed: ?u64,
};

pub const PolicyAbi = struct {
    policy_name: []const u8 = "zigsched_minimal",
    policy_version: []const u8 = "sched_ext_minimal_v1",
    struct_ops: []const u8 = "zigsched_minimal_ops",
    object_sha256: []const u8 = "unavailable",
    btf_required: bool = true,
};

pub const RuntimeSample = struct {
    state: sched_ext.TextFact,
    ops: sched_ext.TextFact,
    enable_seq: sched_ext.TextFact,
    events: sched_ext.TextFact,
    events_hash: []const u8,
    nr_rejected: sched_ext.TextFact,
    debug_dump: sched_ext.TextFact,
    policy_abi: PolicyAbi,
    cgroup_membership_digest: []const u8,
    workload_alive: bool,
};

pub fn deinit(allocator: std.mem.Allocator, sample: *RuntimeSample) void {
    sched_ext.freeFact(allocator, sample.state);
    sched_ext.freeFact(allocator, sample.ops);
    sched_ext.freeFact(allocator, sample.enable_seq);
    sched_ext.freeFact(allocator, sample.events);
    allocator.free(sample.events_hash);
    sched_ext.freeFact(allocator, sample.nr_rejected);
    sched_ext.freeFact(allocator, sample.debug_dump);
    allocator.free(sample.cgroup_membership_digest);
}

pub fn collectFromRoot(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    cgroup_path: []const u8,
    workload_pid: ?u32,
) !RuntimeSample {
    const events = try sched_ext.readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/events");
    errdefer sched_ext.freeFact(allocator, events);
    const events_hash = try hashText(allocator, events.value);
    errdefer allocator.free(events_hash);
    return .{
        .state = try sched_ext.readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/state"),
        .ops = try sched_ext.readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/root/ops"),
        .enable_seq = try sched_ext.readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/enable_seq"),
        .events = events,
        .events_hash = events_hash,
        .nr_rejected = try sched_ext.readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/nr_rejected"),
        .debug_dump = try debugDumpSummary(allocator, root_path),
        .policy_abi = .{},
        .cgroup_membership_digest = try membershipDigest(allocator, root_path, cgroup_path),
        .workload_alive = try workloadAlive(root_path, workload_pid),
    };
}

pub fn parseEventCounters(raw: []const u8) EventCounters {
    return .{
        .raw = raw,
        .nr_rejected = parseNamedCounter(raw, "nr_rejected"),
        .dispatch_failed = parseNamedCounter(raw, "dispatch_failed"),
    };
}

pub fn writeJsonLine(writer: anytype, sample: RuntimeSample, sequence: usize) !void {
    try writer.writeAll("{\"schema\":\"zig-scheduler/runtime-sample/v1\"");
    try writer.print(",\"sequence\":{}", .{sequence});
    try writeNamedFact(writer, "state", sample.state);
    try writeNamedFact(writer, "ops", sample.ops);
    try writeNamedFact(writer, "enable_seq", sample.enable_seq);
    try writeNamedFact(writer, "events", sample.events);
    try writer.writeAll(",\"events_hash\":");
    try writeJsonString(writer, sample.events_hash);
    try writeNamedFact(writer, "nr_rejected", sample.nr_rejected);
    try writeNamedFact(writer, "debug_dump", sample.debug_dump);
    try writePolicyAbi(writer, sample.policy_abi);
    try writer.writeAll(",\"cgroup_membership_digest\":");
    try writeJsonString(writer, sample.cgroup_membership_digest);
    try writer.print(",\"workload_alive\":{},\"private_command_lines_sampled\":false}}\n", .{sample.workload_alive});
}

fn writePolicyAbi(writer: anytype, abi: PolicyAbi) !void {
    try writer.writeAll(",\"policy_abi\":{\"policy_name\":");
    try writeJsonString(writer, abi.policy_name);
    try writer.writeAll(",\"policy_version\":");
    try writeJsonString(writer, abi.policy_version);
    try writer.writeAll(",\"struct_ops\":");
    try writeJsonString(writer, abi.struct_ops);
    try writer.writeAll(",\"object_sha256\":");
    try writeJsonString(writer, abi.object_sha256);
    try writer.print(",\"btf_required\":{}", .{abi.btf_required});
    try writer.writeByte('}');
}

fn writeNamedFact(writer: anytype, name: []const u8, fact: sched_ext.TextFact) !void {
    try writer.writeAll(",");
    try writeJsonString(writer, name);
    try writer.writeAll(":{\"status\":");
    try writeJsonString(writer, @tagName(fact.status));
    try writer.writeAll(",\"value\":");
    try writeJsonString(writer, fact.value);
    try writer.writeAll("}");
}

fn debugDumpSummary(allocator: std.mem.Allocator, root_path: []const u8) !sched_ext.TextFact {
    const fact = try sched_ext.readSmallFactFromRoot(allocator, root_path, "/sys/kernel/debug/sched_ext/dump");
    defer sched_ext.freeFact(allocator, fact);
    if (fact.status != .present) return .{ .status = fact.status, .value = try allocator.dupe(u8, "") };
    const digest = try sha256Hex(allocator, fact.value);
    defer allocator.free(digest);
    return .{ .status = .present, .value = try std.fmt.allocPrint(allocator, "sha256:{s};bytes:{d}", .{ digest, fact.value.len }) };
}

fn membershipDigest(allocator: std.mem.Allocator, root_path: []const u8, cgroup_path: []const u8) ![]const u8 {
    const procs_path = try joinCgroupFile(allocator, cgroup_path);
    defer allocator.free(procs_path);
    const fact = try sched_ext.readSmallFactFromRoot(allocator, root_path, procs_path);
    defer sched_ext.freeFact(allocator, fact);
    if (fact.status != .present) return sha256Hex(allocator, @tagName(fact.status));
    return sha256Hex(allocator, fact.value);
}

fn hashText(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return sha256Hex(allocator, value);
}

fn sha256Hex(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(value, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn joinCgroupFile(allocator: std.mem.Allocator, cgroup_path: []const u8) ![]const u8 {
    defer {}
    if (std.mem.endsWith(u8, cgroup_path, "/")) return std.fmt.allocPrint(allocator, "{s}cgroup.procs", .{cgroup_path});
    return std.fmt.allocPrint(allocator, "{s}/cgroup.procs", .{cgroup_path});
}

fn workloadAlive(root_path: []const u8, pid: ?u32) !bool {
    const value = pid orelse return false;
    var path_buf: [128]u8 = undefined;
    const proc_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}", .{value});
    if (root_path.len == 0) {
        var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), proc_path, .{}) catch return false;
        dir.close(std.Io.Threaded.global_single_threaded.io());
        return true;
    }
    var rooted_buf: [256]u8 = undefined;
    const rooted = try std.fmt.bufPrint(&rooted_buf, "{s}{s}", .{ root_path, proc_path });
    var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), rooted, .{}) catch return false;
    dir.close(std.Io.Threaded.global_single_threaded.io());
    return true;
}

fn parseNamedCounter(raw: []const u8, name: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, name)) continue;
        var parts = std.mem.tokenizeAny(u8, trimmed[name.len..], " :=\t");
        const value = parts.next() orelse return null;
        return std.fmt.parseUnsigned(u64, value, 10) catch null;
    }
    return null;
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u{x:0>4}", .{byte}) else try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

test "runtime observer parses known and unknown sched_ext event counters" {
    const counters = parseEventCounters("nr_rejected: 7\ndispatch_failed=2\nunknown_counter 99\n");
    try std.testing.expectEqual(@as(?u64, 7), counters.nr_rejected);
    try std.testing.expectEqual(@as(?u64, 2), counters.dispatch_failed);
    try std.testing.expect(std.mem.indexOf(u8, counters.raw, "unknown_counter") != null);
}

test "runtime observer samples disabled state missing ops and workload liveness without command lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try makePath(&tmp.dir, "sys/kernel/sched_ext/root");
    try makePath(&tmp.dir, "sys/kernel/debug/sched_ext");
    try makePath(&tmp.dir, "sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope");
    try makePath(&tmp.dir, "proc/1234");
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/state", .data = "disabled\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/enable_seq", .data = "42\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/events", .data = "nr_rejected: 0\nunknown_counter: 9\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/nr_rejected", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/debug/sched_ext/dump", .data = "dump" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs", .data = "1234\n" });
    const root_path = try tmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root_path);
    var sample = try collectFromRoot(std.testing.allocator, root_path, "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope", 1234);
    defer deinit(std.testing.allocator, &sample);
    try std.testing.expectEqual(sched_ext.FactStatus.present, sample.state.status);
    try std.testing.expectEqualStrings("disabled", sample.state.value);
    try std.testing.expectEqual(sched_ext.FactStatus.missing, sample.ops.status);
    try std.testing.expect(sample.workload_alive);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &list);
    try writeJsonLine(&writer.writer, sample, 0);
    list = writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, list.items, "private_command_lines_sampled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\"events_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\"policy_abi\"") != null);
    try std.testing.expectEqual(@as(usize, 64), sample.events_hash.len);
    try std.testing.expectEqual(@as(usize, 64), sample.cgroup_membership_digest.len);
}

fn makePath(dir: *std.Io.Dir, sub_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var child = try dir.createDirPathOpen(io, sub_path, .{});
    child.close(io);
}

fn tmpPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, sub_path: []const u8) ![:0]u8 {
    const relative = if (std.mem.eql(u8, sub_path, "."))
        try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path})
    else
        try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, sub_path });
    defer allocator.free(relative);
    return std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), relative, allocator);
}
