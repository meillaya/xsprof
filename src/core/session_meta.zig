//! Capture-session metadata markers: the recorder's own pid, per-CPU LLC
//! groups, and a buddyinfo snapshot. Parsing is pure and optional; a marker
//! that is absent or malformed leaves the matching signal uncollected.

const std = @import("std");
const event = @import("event.zig");

pub const max_cpus = 256;

pub const capture_owner = "capture_owner";
pub const cpu_llc = "cpu_llc";
pub const host_memory = "host_memory";

pub const Meta = struct {
    self_pid: i32 = -1,
    self_seen: bool = false,
    llc: [max_cpus]i16 = @splat(-1),
    topology_count: u16 = 0,
    buddy_fragmentation: f64 = 0,
    buddy_sampled: bool = false,

    pub fn apply(self: *Meta, entry: event.RawEvent) void {
        if (entry.kind != .marker) return;
        if (startsWithMarker(entry.detail, capture_owner)) {
            if (entry.pid > 0) {
                self.self_pid = entry.pid;
                self.self_seen = true;
            }
            return;
        }
        if (startsWithMarker(entry.detail, cpu_llc)) {
            const cpu = parseU32(entry.detail, "cpu") orelse return;
            const llc = parseU32(entry.detail, "llc") orelse return;
            if (cpu >= max_cpus or llc > std.math.maxInt(i16)) return;
            const index: usize = @intCast(cpu);
            if (self.llc[index] < 0) self.topology_count +|= 1;
            self.llc[index] = @intCast(llc);
            return;
        }
        if (startsWithMarker(entry.detail, host_memory)) {
            const ratio = parseF64(entry.detail, "buddy_fragmentation") orelse return;
            if (!std.math.isFinite(ratio) or ratio < 0 or ratio > 1) return;
            self.buddy_fragmentation = ratio;
            self.buddy_sampled = true;
        }
    }

    pub fn isSelf(self: *const Meta, pid: i32, comm: []const u8) bool {
        if (self.self_seen) return pid > 0 and pid == self.self_pid;
        return isProfilerComm(comm);
    }

    pub fn llcOf(self: *const Meta, cpu: i32) ?i16 {
        if (cpu < 0 or cpu >= max_cpus) return null;
        const value = self.llc[@intCast(cpu)];
        return if (value < 0) null else value;
    }

    pub fn topologyComplete(self: *const Meta, cpu_count: usize) bool {
        if (cpu_count == 0 or self.topology_count == 0) return false;
        const count = @min(cpu_count, max_cpus);
        var cpu: usize = 0;
        while (cpu < count) : (cpu += 1) {
            if (self.llc[cpu] < 0) return false;
        }
        return true;
    }

    pub fn llcDomainCount(self: *const Meta) i32 {
        var count: i32 = 0;
        for (self.llc, 0..) |value, index| {
            if (value < 0) continue;
            var seen = false;
            var prior: usize = 0;
            while (prior < index) : (prior += 1) {
                if (self.llc[prior] == value) {
                    seen = true;
                    break;
                }
            }
            if (!seen) count += 1;
        }
        return @max(1, count);
    }
};

fn startsWithMarker(detail: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, detail, name)) return false;
    return detail.len == name.len or detail[name.len] == ' ';
}

fn parseU32(detail: []const u8, key: []const u8) ?u32 {
    var tokens = std.mem.tokenizeScalar(u8, detail, ' ');
    while (tokens.next()) |token| {
        if (token.len <= key.len + 1) continue;
        if (!std.mem.eql(u8, token[0..key.len], key)) continue;
        if (token[key.len] != '=') continue;
        return std.fmt.parseInt(u32, token[key.len + 1 ..], 10) catch null;
    }
    return null;
}

fn parseF64(detail: []const u8, key: []const u8) ?f64 {
    var tokens = std.mem.tokenizeScalar(u8, detail, ' ');
    while (tokens.next()) |token| {
        if (token.len <= key.len + 1) continue;
        if (!std.mem.eql(u8, token[0..key.len], key)) continue;
        if (token[key.len] != '=') continue;
        return std.fmt.parseFloat(f64, token[key.len + 1 ..]) catch null;
    }
    return null;
}

pub fn ownerPid(entry: event.RawEvent) ?i32 {
    if (entry.kind != .marker) return null;
    if (!startsWithMarker(entry.detail, capture_owner)) return null;
    return if (entry.pid > 0) entry.pid else null;
}

pub fn isMetadata(entry: event.RawEvent) bool {
    if (entry.kind != .marker) return false;
    return startsWithMarker(entry.detail, capture_owner) or
        startsWithMarker(entry.detail, cpu_llc) or
        startsWithMarker(entry.detail, host_memory);
}

pub fn isProfilerComm(comm: []const u8) bool {
    if (std.mem.eql(u8, comm, "xsprof")) return true;
    return std.mem.startsWith(u8, comm, "xsprof-");
}

test "capture owner, topology, and buddy markers parse" {
    var meta: Meta = .{};
    meta.apply(.{ .kind = .marker, .pid = 1768, .detail = "capture_owner" });
    meta.apply(.{ .kind = .marker, .detail = "cpu_llc cpu=0 llc=0" });
    meta.apply(.{ .kind = .marker, .detail = "cpu_llc cpu=1 llc=0" });
    meta.apply(.{ .kind = .marker, .detail = "cpu_llc cpu=2 llc=2" });
    meta.apply(.{ .kind = .marker, .detail = "cpu_llc cpu=3 llc=2" });
    meta.apply(.{ .kind = .marker, .detail = "host_memory buddy_fragmentation=0.75" });

    try std.testing.expect(meta.self_seen);
    try std.testing.expectEqual(@as(i32, 1768), meta.self_pid);
    try std.testing.expectEqual(@as(i16, 0), meta.llcOf(1).?);
    try std.testing.expectEqual(@as(i16, 2), meta.llcOf(3).?);
    try std.testing.expectEqual(@as(u16, 4), meta.topology_count);
    try std.testing.expect(meta.topologyComplete(4));
    try std.testing.expectEqual(@as(i32, 2), meta.llcDomainCount());
    try std.testing.expect(meta.buddy_sampled);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), meta.buddy_fragmentation, 0.0001);
    try std.testing.expect(meta.isSelf(1768, "anything"));
    try std.testing.expect(!meta.isSelf(1769, "xsprof"));
}

test "legacy profiler names are identified only without an owner marker" {
    var meta: Meta = .{};
    try std.testing.expect(meta.isSelf(0, "xsprof"));
    try std.testing.expect(meta.isSelf(0, "xsprof-observe"));
    try std.testing.expect(!meta.isSelf(0, "worker"));
    meta.apply(.{ .kind = .marker, .pid = 7, .detail = "capture_owner" });
    try std.testing.expect(meta.isSelf(7, "worker"));
    try std.testing.expect(!meta.isSelf(8, "xsprof"));
}

test "partial and malformed topology stays uncollected" {
    var meta: Meta = .{};
    meta.apply(.{ .kind = .marker, .detail = "cpu_llc cpu=0 llc=0" });
    meta.apply(.{ .kind = .marker, .detail = "cpu_llc cpu=1 llc=oops" });
    meta.apply(.{ .kind = .marker, .detail = "cpu_llc cpu=999 llc=0" });
    try std.testing.expect(!meta.topologyComplete(2));
    try std.testing.expect(meta.topologyComplete(1));
    try std.testing.expect(meta.llcOf(0) != null);
    try std.testing.expect(meta.llcOf(1) == null);
    meta.apply(.{ .kind = .marker, .detail = "host_memory buddy_fragmentation=nope" });
    meta.apply(.{ .kind = .marker, .detail = "host_memory buddy_fragmentation=1.5" });
    try std.testing.expect(!meta.buddy_sampled);
}

test "metadata classifies session markers only" {
    try std.testing.expect(isMetadata(.{ .kind = .marker, .detail = "capture_owner" }));
    try std.testing.expect(isMetadata(.{ .kind = .marker, .detail = "cpu_llc cpu=0 llc=0" }));
    try std.testing.expect(isMetadata(.{ .kind = .marker, .detail = "host_memory buddy_fragmentation=0.1" }));
    try std.testing.expect(!isMetadata(.{ .kind = .marker, .detail = "session_start" }));
    try std.testing.expect(!isMetadata(.{ .kind = .sched_switch, .detail = "capture_owner" }));
}
