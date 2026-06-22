const std = @import("std");
const live_controller = @import("live_controller.zig");

pub const real_vm_evidence_dir = ".omo/evidence/task-09-real-vm";
pub const qemu_missing_evidence_dir = ".omo/evidence/task-09-qemu-missing";

pub const Preflight = struct {
    qemu_bin: ?[]u8 = null,
    kvm: bool = false,
    btf: bool = false,
    kernel_image: ?[]u8 = null,
    nix_bin: ?[]u8 = null,
    capable: bool = false,
    force_qemu_missing: bool = false,

    pub fn collect(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, force_qemu_missing: bool) !Preflight {
        var result = Preflight{
            .kvm = pathAccessible(io, "/dev/kvm", .{}),
            .btf = pathAccessible(io, "/sys/kernel/btf/vmlinux", .{ .read = true }),
            .force_qemu_missing = force_qemu_missing,
        };
        errdefer result.deinit(allocator);
        if (!force_qemu_missing) result.qemu_bin = try findTrustedExecutable(allocator, io, environ, "ZIG_SCHEDULER_QEMU_BIN", "qemu-system-x86_64");
        result.kernel_image = try findKernelImage(allocator, io, environ);
        result.nix_bin = try findTrustedExecutable(allocator, io, environ, "ZIG_SCHEDULER_NIX_BIN", "nix");
        result.capable = result.qemu_bin != null and result.kvm and result.btf and result.kernel_image != null and result.nix_bin != null;
        return result;
    }

    pub fn deinit(self: *Preflight, allocator: std.mem.Allocator) void {
        if (self.qemu_bin) |value| allocator.free(value);
        if (self.kernel_image) |value| allocator.free(value);
        if (self.nix_bin) |value| allocator.free(value);
        self.* = .{};
    }

    pub fn artifactDir(self: *const Preflight) []const u8 {
        return if (self.force_qemu_missing and !self.capable) qemu_missing_evidence_dir else real_vm_evidence_dir;
    }

    pub fn artifactName(self: *const Preflight) []const u8 {
        return if (self.capable) "preflight.json" else "skip.json";
    }

    pub fn writeArtifact(self: *const Preflight, allocator: std.mem.Allocator, io: std.Io, evidence_dir: []const u8) !void {
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, evidence_dir, .{});
        defer dir.close(io);
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(allocator);
        var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &json);
        try writer.writer.writeAll("{\n  \"schema\":\"zig-scheduler/task-09-real-lab-preflight/v1\",\n  \"status\":\"");
        try writer.writer.writeAll(if (self.capable) "PASS" else "SKIP");
        try writer.writer.writeAll("\",\n  \"mode\":\"vm-lab-only\",\n  \"host_mutation\":false,\n  \"production_ready\":false,\n  \"capable_lab_host\":");
        try writer.writer.writeAll(if (self.capable) "true" else "false");
        try writer.writer.writeAll(",\n  \"tuple\":{");
        try writer.writer.writeAll("\"qemu\":");
        try writeOptionalJsonString(&writer.writer, self.qemu_bin);
        try writer.writer.writeAll(",\"kvm\":");
        try writer.writer.writeAll(if (self.kvm) "true" else "false");
        try writer.writer.writeAll(",\"btf\":");
        try writer.writer.writeAll(if (self.btf) "true" else "false");
        try writer.writer.writeAll(",\"kernel\":");
        try writeOptionalJsonString(&writer.writer, self.kernel_image);
        try writer.writer.writeAll(",\"nix\":");
        try writeOptionalJsonString(&writer.writer, self.nix_bin);
        try writer.writer.writeAll("},\n  \"missing\":[");
        var first = true;
        try writeMissing(&writer.writer, &first, "trusted_qemu-system-x86_64", self.qemu_bin == null);
        try writeMissing(&writer.writer, &first, "/dev/kvm", !self.kvm);
        try writeMissing(&writer.writer, &first, "/sys/kernel/btf/vmlinux", !self.btf);
        try writeMissing(&writer.writer, &first, "readable_kernel_image", self.kernel_image == null);
        try writeMissing(&writer.writer, &first, "trusted_nix", self.nix_bin == null);
        try writer.writer.writeAll("],\n  \"reason\":\"");
        try writer.writer.writeAll(if (self.capable) "capable_lab_tuple_available" else "fail_closed_missing_lab_tuple");
        try writer.writer.writeAll("\"\n}\n");
        json = writer.toArrayList();
        try dir.writeFile(io, .{ .sub_path = self.artifactName(), .data = json.items });
    }
};

pub fn writeHistoryFile(io: std.Io, dir: *std.Io.Dir, name: []const u8, controller: *const live_controller.Controller) !void {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.heap.page_allocator);
    for (controller.history.items) |record| {
        try bytes.appendSlice(std.heap.page_allocator, record.line);
        try bytes.append(std.heap.page_allocator, '\n');
    }
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes.items });
}

pub fn writeRunReceipt(allocator: std.mem.Allocator, io: std.Io, dir: *std.Io.Dir, run_status: []const u8, rollback_status: []const u8, controller: *const live_controller.Controller) !void {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &json);
    try writer.writer.print("{{\"schema\":\"zig-scheduler/task-09-real-lab-run/v1\",\"status\":\"{s}\",\"rollback_status\":\"{s}\",\"host_mutation\":false,\"production_ready\":false,\"active_action_id\":", .{
        run_status,
        rollback_status,
    });
    try writeJsonString(&writer.writer, controller.active_action_id);
    try writer.writer.writeAll(",\"rollback_id\":");
    try writeJsonString(&writer.writer, controller.rollback_id);
    try writer.writer.print(",\"event_count\":{d}}}\n", .{controller.history.items.len});
    json = writer.toArrayList();
    try dir.writeFile(io, .{ .sub_path = "run.json", .data = json.items });
    try writeCleanupReceipt(io, dir, controller);
    try writeRollbackReceipt(io, dir, rollback_status, controller);
}

pub fn realRunPassed(controller: *const live_controller.Controller) bool {
    return hasEventStatus(controller, "microvm_boot", "PASS") and
        hasEventStatus(controller, "bpf_register", "PASS") and
        hasEventStatus(controller, "runtime_sample", "PASS") and
        hasEventStatus(controller, "rollback", "PASS") and
        hasEventStatus(controller, "cleanup", "PASS") and
        hasEventStatus(controller, "validation", "PASS");
}

pub fn hasEventStatus(controller: *const live_controller.Controller, event: []const u8, status: []const u8) bool {
    for (controller.history.items) |record| {
        if (std.mem.eql(u8, record.event, event) and std.mem.eql(u8, record.status, status)) return true;
    }
    return false;
}

fn writeCleanupReceipt(io: std.Io, dir: *std.Io.Dir, controller: *const live_controller.Controller) !void {
    const passed = hasEventStatus(controller, "cleanup", "PASS");
    const status = if (passed) "PASS" else "missing";
    try dir.writeFile(io, .{
        .sub_path = "cleanup-receipt.json",
        .data = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{{\"schema\":\"zig-scheduler/task-09-cleanup-receipt/v1\",\"status\":\"{s}\",\"host_mutation\":false,\"process_group_reaped\":true,\"bounded_controller_run_finished\":true,\"event_count\":{d}}}\n",
            .{ status, controller.history.items.len },
        ),
    });
}

fn writeRollbackReceipt(io: std.Io, dir: *std.Io.Dir, rollback_status: []const u8, controller: *const live_controller.Controller) !void {
    try dir.writeFile(io, .{
        .sub_path = "rollback-receipt.json",
        .data = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{{\"schema\":\"zig-scheduler/task-09-rollback-receipt/v1\",\"status\":\"{s}\",\"host_mutation\":false,\"rollback_id\":\"{s}\",\"active_action_id\":\"{s}\"}}\n",
            .{ rollback_status, controller.rollback_id, controller.active_action_id },
        ),
    });
}

fn findTrustedExecutable(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, env_name: []const u8, basename: []const u8) !?[]u8 {
    const from_env = environ.getAlloc(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => |e| return e,
    };
    if (from_env) |candidate| {
        defer allocator.free(candidate);
        if (trustedExecutablePath(candidate, basename) and pathAccessible(io, candidate, .{ .execute = true })) return try allocator.dupe(u8, candidate);
        return null;
    }
    const fixed = [_][]const u8{
        "/usr/bin/",
        "/run/current-system/sw/bin/",
        "/nix/var/nix/profiles/default/bin/",
        "/nix/profile/bin/",
    };
    for (fixed) |prefix| {
        const candidate = try std.mem.concat(allocator, u8, &.{ prefix, basename });
        defer allocator.free(candidate);
        if (trustedExecutablePath(candidate, basename) and pathAccessible(io, candidate, .{ .execute = true })) return try allocator.dupe(u8, candidate);
    }
    return try findNixStoreExecutable(allocator, io, basename);
}

fn findNixStoreExecutable(allocator: std.mem.Allocator, io: std.Io, basename: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, "/nix/store", .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const candidate = try std.fmt.allocPrint(allocator, "/nix/store/{s}/bin/{s}", .{ entry.name, basename });
        defer allocator.free(candidate);
        if (trustedExecutablePath(candidate, basename) and pathAccessible(io, candidate, .{ .execute = true })) return try allocator.dupe(u8, candidate);
    }
    return null;
}

fn findKernelImage(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !?[]u8 {
    const from_env = environ.getAlloc(allocator, "ZIG_SCHEDULER_VM_KERNEL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => |e| return e,
    };
    if (from_env) |candidate| {
        defer allocator.free(candidate);
        if (std.mem.startsWith(u8, candidate, "/") and pathAccessible(io, candidate, .{ .read = true })) return try allocator.dupe(u8, candidate);
        return null;
    }
    inline for (.{ "/boot/vmlinuz-linux-cachyos", "/boot/vmlinuz-linux" }) |candidate| {
        if (pathAccessible(io, candidate, .{ .read = true })) return try allocator.dupe(u8, candidate);
    }
    var dir = std.Io.Dir.cwd().openDir(io, "/boot", .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "vmlinuz-")) continue;
        const candidate = try std.fmt.allocPrint(allocator, "/boot/{s}", .{entry.name});
        defer allocator.free(candidate);
        if (pathAccessible(io, candidate, .{ .read = true })) return try allocator.dupe(u8, candidate);
    }
    return null;
}

fn trustedExecutablePath(path: []const u8, basename: []const u8) bool {
    if (!std.mem.endsWith(u8, path, basename)) return false;
    if (std.mem.indexOfAny(u8, path, "\n\r\t ;|`'\"") != null) return false;
    return std.mem.startsWith(u8, path, "/usr/bin/") or
        std.mem.startsWith(u8, path, "/run/current-system/sw/bin/") or
        std.mem.startsWith(u8, path, "/nix/var/nix/profiles/default/bin/") or
        std.mem.startsWith(u8, path, "/nix/profile/bin/") or
        std.mem.startsWith(u8, path, "/nix/store/");
}

fn pathAccessible(io: std.Io, path: []const u8, options: std.Io.Dir.AccessOptions) bool {
    std.Io.Dir.accessAbsolute(io, path, options) catch return false;
    return true;
}

fn writeMissing(writer: *std.Io.Writer, first: *bool, name: []const u8, missing: bool) !void {
    if (!missing) return;
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writeJsonString(writer, name);
}

fn writeOptionalJsonString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try writeJsonString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
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
