const std = @import("std");
const builtin = @import("builtin");
const sched_ext = @import("../sched_ext/root.zig");

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
    safety_summary: []const u8,

    pub fn deinit(self: *PreflightReport) void {
        self.allocator.free(self.kernel_release);
        sched_ext.deinit(&self.sched_ext, self.allocator);
        sched_ext.freeFact(self.allocator, self.btf);
        if (self.cgroup_v2.controllers.len != 0) self.allocator.free(self.cgroup_v2.controllers);
        if (self.capabilities.effective_hex.len != 0) self.allocator.free(self.capabilities.effective_hex);
    }
};

pub fn collectPreflight(allocator: std.mem.Allocator) !PreflightReport {
    return .{
        .allocator = allocator,
        .kernel_release = try readTrimmedOrUnknown(allocator, "/proc/sys/kernel/osrelease"),
        .arch = @tagName(builtin.cpu.arch),
        .sched_ext = try sched_ext.collect(allocator),
        .btf = try btfFact(allocator),
        .cgroup_v2 = try cgroupFacts(allocator),
        .capabilities = try capabilityFacts(allocator),
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
    try writer.writeAll("}");
    try writer.writeAll(",\"sched_ext\":{");
    try writeNamedFact(writer, "state", report.sched_ext.state);
    try writer.writeAll(",");
    try writeNamedFact(writer, "enable_seq", report.sched_ext.enable_seq);
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

fn btfFact(allocator: std.mem.Allocator) !TextFact {
    return sched_ext.presenceFact(allocator, "/sys/kernel/btf/vmlinux", "/sys/kernel/btf/vmlinux");
}

fn cgroupFacts(allocator: std.mem.Allocator) !CgroupFacts {
    const mountinfo = try sched_ext.readLimitedTextFact(allocator, "/proc/self/mountinfo", proc_text_limit);
    defer sched_ext.freeFact(allocator, mountinfo);
    if (mountinfo.status != .present) return .{
        .status = mountinfo.status,
        .controllers = try allocator.dupe(u8, ""),
    };
    if (!hasCgroup2Mount(mountinfo.value)) return .{
        .status = .missing,
        .controllers = try allocator.dupe(u8, ""),
    };
    const controllers = try sched_ext.readSmallFact(allocator, "/sys/fs/cgroup/cgroup.controllers");
    defer sched_ext.freeFact(allocator, controllers);
    return .{ .status = controllers.status, .controllers = try allocator.dupe(u8, controllers.value) };
}

fn capabilityFacts(allocator: std.mem.Allocator) !CapabilityFacts {
    const status = try sched_ext.readLimitedTextFact(allocator, "/proc/self/status", proc_text_limit);
    defer sched_ext.freeFact(allocator, status);
    if (status.status != .present) return .{ .effective_hex = try allocator.dupe(u8, ""), .status = status.status };
    if (capEffValue(status.value)) |value| return .{ .effective_hex = try allocator.dupe(u8, value), .status = .present };
    return .{ .effective_hex = try allocator.dupe(u8, ""), .status = .unknown };
}

fn readTrimmedOrUnknown(allocator: std.mem.Allocator, absolute_path: []const u8) ![]u8 {
    const fact = try sched_ext.readSmallFact(allocator, absolute_path);
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
