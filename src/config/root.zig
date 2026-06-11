const std = @import("std");
const audit = @import("../audit/root.zig");

pub const RootConfig = struct {
    scheduler_name: []const u8,
    cgroup_target: ?[]const u8 = null,
    target_path: ?[]const u8 = null,
    mutation_profile: bool = false,
    audit_id: ?[]const u8 = null,

    pub fn deinit(self: *RootConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.scheduler_name);
        if (self.cgroup_target) |path| allocator.free(path);
        if (self.target_path) |path| allocator.free(path);
        if (self.audit_id) |id| allocator.free(id);
        self.* = undefined;
    }
};

const RawConfig = struct {
    scheduler_name: []const u8,
    cgroup_target: ?[]const u8 = null,
    target_path: ?[]const u8 = null,
    mutation_profile: bool = false,
    audit_id: ?[]const u8 = null,
};

pub fn parseRootConfig(allocator: std.mem.Allocator, source: []const u8) !RootConfig {
    var parsed = try std.json.parseFromSlice(RawConfig, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const raw = parsed.value;
    try validateSchedulerName(raw.scheduler_name);
    if (raw.mutation_profile and raw.audit_id == null) return error.AuditIdRequired;

    var config = RootConfig{
        .scheduler_name = try allocator.dupe(u8, raw.scheduler_name),
        .mutation_profile = raw.mutation_profile,
    };
    errdefer config.deinit(allocator);

    if (raw.cgroup_target) |path| config.cgroup_target = normalizeCgroupTarget(allocator, path) catch |err| switch (err) {
        error.UnsafePath => return error.UnsafeCgroupTarget,
        else => return err,
    };
    if (raw.target_path) |path| config.target_path = try normalizeSafeAbsolutePath(allocator, path);
    if (raw.audit_id) |id| {
        if (!audit.validateAuditId(id)) return error.InvalidAuditId;
        config.audit_id = try allocator.dupe(u8, id);
    }
    return config;
}

pub fn validateSchedulerName(name: []const u8) !void {
    if (name.len == 0) return error.UnsafeSchedulerName;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.')) {
            return error.UnsafeSchedulerName;
        }
    }
}

pub fn normalizeSafeAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    try validateSafeAbsolutePath(path);
    return allocator.dupe(u8, path);
}

pub fn normalizeCgroupTarget(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!isUnderCgroupRoot(path)) return error.UnsafePath;
    return normalizeSafeAbsolutePath(allocator, path);
}

fn validateSafeAbsolutePath(path: []const u8) !void {
    if (path.len == 0 or path[0] != '/') return error.UnsafePath;
    if (path.len > 1 and path[path.len - 1] == '/') return error.UnsafePath;
    var component_start: usize = 1;
    var index: usize = 1;
    while (index <= path.len) : (index += 1) {
        if (index == path.len or path[index] == '/') {
            const component = path[component_start..index];
            if (component.len == 0) return error.UnsafePath;
            if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.UnsafePath;
            component_start = index + 1;
        } else if (!isSafePathByte(path[index])) return error.UnsafePath;
    }
}

fn isUnderCgroupRoot(path: []const u8) bool {
    return std.mem.eql(u8, path, "/sys/fs/cgroup") or std.mem.startsWith(u8, path, "/sys/fs/cgroup/");
}

fn isSafePathByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == '/';
}

test "typed root config rejects unknown JSON fields" {
    try std.testing.expectError(error.UnknownField, parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"scx_safe","unexpected":true}
    ));
}

test "typed root config accepts safe normalized paths and mutation audit id" {
    var cfg = try parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"scx_safe","cgroup_target":"/sys/fs/cgroup/team.slice","target_path":"/sys/fs/cgroup/team.slice/workload","mutation_profile":true,"audit_id":"AUD-20260610T210305Z-deadbee-a1b2c3"}
    );
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("scx_safe", cfg.scheduler_name);
    try std.testing.expectEqualStrings("/sys/fs/cgroup/team.slice", cfg.cgroup_target.?);
    try std.testing.expectEqualStrings("/sys/fs/cgroup/team.slice/workload", cfg.target_path.?);
    try std.testing.expect(cfg.mutation_profile);
}

test "typed root config rejects unsafe scheduler names paths and mutation without audit" {
    try std.testing.expectError(error.UnsafeSchedulerName, parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"","mutation_profile":false}
    ));
    try std.testing.expectError(error.UnsafeSchedulerName, parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"scx;rm","mutation_profile":false}
    ));
    try std.testing.expectError(error.InvalidAuditId, parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"scx_safe","audit_id":"not-audit"}
    ));
    try std.testing.expectError(error.UnsafeCgroupTarget, parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"scx_safe","cgroup_target":"relative/path"}
    ));
    try std.testing.expectError(error.UnsafeCgroupTarget, parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"scx_safe","cgroup_target":"/tmp/not-cgroup"}
    ));
    try std.testing.expectError(error.UnsafeCgroupTarget, parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"scx_safe","cgroup_target":"/sys/fs/cgroup/../escape"}
    ));
    try std.testing.expectError(error.UnsafePath, parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"scx_safe","target_path":"/sys/fs/cgroup//bad"}
    ));
    try std.testing.expectError(error.UnsafePath, parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"scx_safe","target_path":"/sys/fs/cgroup/bad;rm"}
    ));
    try std.testing.expectError(error.AuditIdRequired, parseRootConfig(std.testing.allocator,
        \\{"scheduler_name":"scx_safe","mutation_profile":true}
    ));
}
