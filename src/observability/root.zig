const std = @import("std");
const builtin = @import("builtin");
const sched_ext = @import("../sched_ext/root.zig");
const readiness = @import("readiness.zig");
pub const runtime = @import("runtime.zig");

pub const FactStatus = sched_ext.FactStatus;
pub const TextFact = sched_ext.TextFact;

const proc_text_limit = 256 * 1024;

pub const CgroupFacts = struct {
    status: FactStatus,
    controllers: []const u8,
};

pub const CapabilityFacts = struct {
    effective_hex: []const u8,
    status: FactStatus,
};

pub const PreflightReport = struct {
    allocator: std.mem.Allocator,
    kernel_release: []const u8,
    arch: []const u8,
    sched_ext: sched_ext.SchedExtFacts,
    btf: TextFact,
    cgroup_v2: CgroupFacts,
    capabilities: CapabilityFacts,
    readiness: readiness.ReadinessFacts,
    safety_summary: []const u8,

    pub fn deinit(self: *PreflightReport) void {
        self.allocator.free(self.kernel_release);
        sched_ext.deinit(&self.sched_ext, self.allocator);
        sched_ext.freeFact(self.allocator, self.btf);
        if (self.cgroup_v2.controllers.len != 0) self.allocator.free(self.cgroup_v2.controllers);
        if (self.capabilities.effective_hex.len != 0) self.allocator.free(self.capabilities.effective_hex);
        readiness.deinit(&self.readiness, self.allocator);
    }
};

pub fn collectPreflight(allocator: std.mem.Allocator) !PreflightReport {
    return collectPreflightFromRoot(allocator, "");
}

pub fn collectPreflightFromRoot(allocator: std.mem.Allocator, root_path: []const u8) !PreflightReport {
    const kernel_release = try readTrimmedOrUnknownFromRoot(allocator, root_path, "/proc/sys/kernel/osrelease");
    errdefer allocator.free(kernel_release);
    const caps = try capabilityFactsFromRoot(allocator, root_path);
    errdefer if (caps.effective_hex.len != 0) allocator.free(caps.effective_hex);
    return .{
        .allocator = allocator,
        .kernel_release = kernel_release,
        .arch = @tagName(builtin.cpu.arch),
        .sched_ext = try sched_ext.collectFromRoot(allocator, root_path),
        .btf = try btfFactFromRoot(allocator, root_path),
        .cgroup_v2 = try cgroupFactsFromRoot(allocator, root_path),
        .capabilities = caps,
        .readiness = try readiness.collectFromRoot(allocator, root_path, kernel_release, caps.effective_hex),
        .safety_summary = "read-only preflight; mutation, attach, enable, and BPF load paths are intentionally absent",
    };
}

pub fn writeJson(writer: anytype, report: PreflightReport) !void {
    try writer.writeAll("{\"schema\":\"zig-scheduler/linux-preflight\",\"version\":1");
    try writer.writeAll(",\"kernel\":{");
    try writer.writeAll("\"release\":");
    try writeJsonString(writer, report.kernel_release);
    try writer.writeAll(",\"arch\":");
    try writeJsonString(writer, report.arch);
    try readiness.writeKernelReadinessJson(writer, report.readiness.kernel);
    try writer.writeAll("}");
    try writer.writeAll(",\"sched_ext\":{");
    try writeNamedFact(writer, "state", report.sched_ext.state);
    try writer.writeAll(",");
    try writeNamedFact(writer, "root_ops", report.sched_ext.root_ops);
    try writer.writeAll(",");
    try writeNamedFact(writer, "enable_seq", report.sched_ext.enable_seq);
    try writer.writeAll(",");
    try writeNamedFact(writer, "events", report.sched_ext.events);
    try writer.writeAll(",");
    try writeNamedFact(writer, "policy_metadata", report.sched_ext.policy_metadata);
    try writer.writeAll(",");
    try writeNamedFact(writer, "rollback_state", report.sched_ext.rollback_state);
    try writer.writeAll(",");
    try writeNamedFact(writer, "switch_all", report.sched_ext.switch_all);
    try writer.writeAll(",");
    try writeNamedFact(writer, "nr_rejected", report.sched_ext.nr_rejected);
    try writer.writeAll("}");
    try writer.writeAll(",\"btf\":");
    try writeFact(writer, report.btf);
    try writer.writeAll(",\"cgroup_v2\":{");
    try writer.writeAll("\"status\":");
    try writeJsonString(writer, @tagName(report.cgroup_v2.status));
    try writer.writeAll(",\"controllers\":");
    try writeJsonString(writer, report.cgroup_v2.controllers);
    try writer.writeAll("}");
    try writer.writeAll(",\"capabilities\":{");
    try writer.writeAll("\"status\":");
    try writeJsonString(writer, @tagName(report.capabilities.status));
    try writer.writeAll(",\"effective\":");
    try writeJsonString(writer, report.capabilities.effective_hex);
    try writer.writeAll("}");
    try writer.writeAll(",\"kernel_config\":");
    try readiness.writeKernelConfigJson(writer, report.readiness.kernel_config);
    try writer.writeAll(",\"bpf_jit_sysctls\":");
    try readiness.writeBpfJitSysctlsJson(writer, report.readiness.bpf_jit_sysctls);
    try writer.writeAll(",\"toolchain\":");
    try readiness.writeToolchainJson(writer, report.readiness.toolchain);
    try writer.writeAll(",\"privileges\":");
    try readiness.writePrivilegesJson(writer, report.readiness.privileges);
    try writer.writeAll(",\"safety\":{");
    try writer.writeAll("\"mode\":\"read_only_fail_closed\",\"mutation_paths\":false,\"summary\":");
    try writeJsonString(writer, report.safety_summary);
    try writer.writeAll("}}");
}

fn writeNamedFact(writer: anytype, name: []const u8, fact: TextFact) !void {
    try writeJsonString(writer, name);
    try writer.writeAll(":");
    try writeFact(writer, fact);
}

fn writeFact(writer: anytype, fact: TextFact) !void {
    try writer.writeAll("{\"status\":");
    try writeJsonString(writer, @tagName(fact.status));
    try writer.writeAll(",\"value\":");
    try writeJsonString(writer, fact.value);
    try writer.writeAll("}");
}

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
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

fn btfFactFromRoot(allocator: std.mem.Allocator, root_path: []const u8) !TextFact {
    return sched_ext.presenceFactFromRoot(allocator, root_path, "/sys/kernel/btf/vmlinux", "/sys/kernel/btf/vmlinux");
}

fn cgroupFactsFromRoot(allocator: std.mem.Allocator, root_path: []const u8) !CgroupFacts {
    const mountinfo = try sched_ext.readLimitedTextFactFromRoot(allocator, root_path, "/proc/self/mountinfo", proc_text_limit);
    defer sched_ext.freeFact(allocator, mountinfo);
    if (mountinfo.status != .present) return .{
        .status = mountinfo.status,
        .controllers = try allocator.dupe(u8, ""),
    };
    if (!hasCgroup2Mount(mountinfo.value)) return .{
        .status = .missing,
        .controllers = try allocator.dupe(u8, ""),
    };
    const controllers = try sched_ext.readSmallFactFromRoot(allocator, root_path, "/sys/fs/cgroup/cgroup.controllers");
    defer sched_ext.freeFact(allocator, controllers);
    return .{ .status = controllers.status, .controllers = try allocator.dupe(u8, controllers.value) };
}

fn capabilityFactsFromRoot(allocator: std.mem.Allocator, root_path: []const u8) !CapabilityFacts {
    const status = try sched_ext.readLimitedTextFactFromRoot(allocator, root_path, "/proc/self/status", proc_text_limit);
    defer sched_ext.freeFact(allocator, status);
    if (status.status != .present) return .{ .effective_hex = try allocator.dupe(u8, ""), .status = status.status };
    if (capEffValue(status.value)) |value| return .{ .effective_hex = try allocator.dupe(u8, value), .status = .present };
    return .{ .effective_hex = try allocator.dupe(u8, ""), .status = .unknown };
}

fn readTrimmedOrUnknownFromRoot(allocator: std.mem.Allocator, root_path: []const u8, absolute_path: []const u8) ![]u8 {
    const fact = try sched_ext.readSmallFactFromRoot(allocator, root_path, absolute_path);
    defer sched_ext.freeFact(allocator, fact);
    if (fact.status != .present) return try allocator.dupe(u8, @tagName(fact.status));
    return try allocator.dupe(u8, fact.value);
}

fn hasCgroup2Mount(mountinfo: []const u8) bool {
    return std.mem.indexOf(u8, mountinfo, " - cgroup2 ") != null;
}

fn capEffValue(status: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "CapEff:")) return std.mem.trim(u8, line["CapEff:".len..], " \t");
    }
    return null;
}

test "json string escaping is deterministic" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buffer);
    try writeJsonString(&writer.writer, "a\"b\\c\x01");
    buffer = writer.toArrayList();
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\u0001\"", buffer.items);
}

test "preflight parsers handle large proc-style text" {
    const prefix = "0 0 0:0 / / rw - proc proc rw\n" ** 200;
    const mountinfo = prefix ++ "42 24 0:29 / /sys/fs/cgroup rw,nosuid,nodev,noexec,relatime - cgroup2 cgroup rw\n";
    try std.testing.expect(hasCgroup2Mount(mountinfo));

    const status = prefix ++ "CapEff:\t0000000000000000\n";
    try std.testing.expectEqualStrings("0000000000000000", capEffValue(status).?);
}

test "preflight can collect from injected host root fixtures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try testingMakePath(&tmp.dir, "proc/sys/kernel");
    try testingMakePath(&tmp.dir, "proc/self");
    try testingMakePath(&tmp.dir, "sys/kernel/sched_ext");
    try testingMakePath(&tmp.dir, "sys/kernel/sched_ext/root");
    try testingMakePath(&tmp.dir, "sys/kernel/btf");
    try testingMakePath(&tmp.dir, "sys/fs/cgroup");
    try testingMakePath(&tmp.dir, "run/zig-scheduler");
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/sys/kernel/osrelease", .data = "6.12.0-test\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/self/mountinfo", .data = "42 24 0:29 / /sys/fs/cgroup rw - cgroup2 cgroup rw\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/self/status", .data = "Name:\ttest\nCapEff:\t0000000000001234\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/state", .data = "enabled\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/root/ops", .data = "zigsched_minimal\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/enable_seq", .data = "7\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/events", .data = "nr_rejected: 0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/switch_all", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/nr_rejected", .data = "2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "run/zig-scheduler/policy-metadata.json", .data = "{\"policy\":\"minimal\"}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "run/zig-scheduler/rollback-state.json", .data = "{\"rollback\":\"clean\"}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/btf/vmlinux", .data = "btf" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/fs/cgroup/cgroup.controllers", .data = "cpu memory\n" });
    const root_path = try testingTmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root_path);

    var report = try collectPreflightFromRoot(std.testing.allocator, root_path);
    defer report.deinit();
    try std.testing.expectEqualStrings("6.12.0-test", report.kernel_release);
    try std.testing.expectEqualStrings("enabled", report.sched_ext.state.value);
    try std.testing.expectEqualStrings("zigsched_minimal", report.sched_ext.root_ops.value);
    try std.testing.expectEqualStrings("nr_rejected: 0", report.sched_ext.events.value);
    try std.testing.expectEqual(FactStatus.present, report.sched_ext.policy_metadata.status);
    try std.testing.expectEqual(FactStatus.present, report.sched_ext.rollback_state.status);
    try std.testing.expectEqualStrings("cpu memory", report.cgroup_v2.controllers);
    try std.testing.expectEqualStrings("0000000000001234", report.capabilities.effective_hex);
    try std.testing.expectEqual(FactStatus.present, report.btf.status);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buffer);
    try writeJson(&writer.writer, report);
    buffer = writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"root_ops\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"policy_metadata\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"rollback_state\"") != null);
}

test "injected preflight fails closed on malformed proc and missing cgroup controllers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try testingMakePath(&tmp.dir, "proc/sys/kernel");
    try testingMakePath(&tmp.dir, "proc/self");
    try testingMakePath(&tmp.dir, "sys/kernel/sched_ext");
    try testingMakePath(&tmp.dir, "sys/kernel/sched_ext/root");
    try testingMakePath(&tmp.dir, "sys/kernel/btf");
    try testingMakePath(&tmp.dir, "sys/fs/cgroup");
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/sys/kernel/osrelease", .data = "6.12.0-test\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/self/mountinfo", .data = "malformed mountinfo without cgroup2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/self/status", .data = "Name:\ttest\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/state", .data = "disabled\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/enable_seq", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/switch_all", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/nr_rejected", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/btf/vmlinux", .data = "btf" });
    const root_path = try testingTmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root_path);

    var report = try collectPreflightFromRoot(std.testing.allocator, root_path);
    defer report.deinit();
    try std.testing.expectEqual(FactStatus.missing, report.cgroup_v2.status);
    try std.testing.expectEqual(FactStatus.unknown, report.capabilities.status);
}

fn testingMakePath(dir: *std.Io.Dir, sub_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var child = try dir.createDirPathOpen(io, sub_path, .{});
    child.close(io);
}

fn testingTmpPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, sub_path: []const u8) ![:0]u8 {
    const relative = if (std.mem.eql(u8, sub_path, "."))
        try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path})
    else
        try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, sub_path });
    defer allocator.free(relative);
    return std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), relative, allocator);
}

test "observability module pulls readiness tests" {
    std.testing.refAllDecls(readiness);
}
