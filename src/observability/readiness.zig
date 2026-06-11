const std = @import("std");
const sched_ext = @import("../sched_ext/root.zig");
const collect = @import("readiness/collect.zig");
const command = @import("readiness/command.zig");
const gzip = @import("readiness/gzip.zig");
const json = @import("readiness/json.zig");
const types = @import("readiness/types.zig");

pub const FactStatus = types.FactStatus;
pub const KernelReadiness = types.KernelReadiness;
pub const KernelConfigFacts = types.KernelConfigFacts;
pub const BpfJitSysctlFacts = types.BpfJitSysctlFacts;
pub const ToolchainFacts = types.ToolchainFacts;
pub const PrivilegeFacts = types.PrivilegeFacts;
pub const ReadinessFacts = types.ReadinessFacts;

pub const collectFromRoot = collect.collectFromRoot;
pub const deinit = collect.deinit;
pub const writeKernelReadinessJson = json.writeKernelReadinessJson;
pub const writeKernelConfigJson = json.writeKernelConfigJson;
pub const writeBpfJitSysctlsJson = json.writeBpfJitSysctlsJson;
pub const writeToolchainJson = json.writeToolchainJson;
pub const writePrivilegesJson = json.writePrivilegesJson;

test "readiness collection from injected root reports proc config jit sysctls tool versions and privileges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try testingMakePath(&tmp.dir, "proc/sys/net/core");
    try testingMakePath(&tmp.dir, "usr/bin");
    try testingMakePath(&tmp.dir, "usr/lib/pkgconfig");
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/config.gz", .data = &.{ 0x1f, 0x8b, 0x08, 0x00, 0x48, 0x25, 0x2a, 0x6a, 0x02, 0xff, 0x65, 0xcd, 0xb1, 0x0e, 0x80, 0x20, 0x0c, 0x84, 0xe1, 0xdd, 0x77, 0x72, 0x28, 0xa5, 0x45, 0x4c, 0x03, 0x26, 0x85, 0x28, 0xd3, 0x3d, 0x87, 0x6f, 0x6f, 0x8c, 0x13, 0x71, 0xbc, 0xff, 0x1b, 0x8e, 0x6b, 0xd1, 0x9c, 0xe0, 0xbc, 0x49, 0x04, 0x1b, 0xb9, 0x43, 0xae, 0xb6, 0xde, 0x0b, 0x7f, 0x10, 0x0e, 0x9d, 0x06, 0x7c, 0x38, 0x93, 0xd9, 0x1c, 0xf7, 0xdc, 0x7e, 0x01, 0x64, 0x27, 0x0d, 0x47, 0x2d, 0x7f, 0x8a, 0xa2, 0xd4, 0xad, 0x4d, 0x16, 0x25, 0xf4, 0x84, 0x5c, 0xb4, 0x22, 0xb4, 0xf7, 0xf4, 0x01, 0xb0, 0xf4, 0xc1, 0x05, 0x9b, 0x00, 0x00, 0x00 } });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/sys/net/core/bpf_jit_enable", .data = "1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/sys/net/core/bpf_jit_harden", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/sys/net/core/bpf_jit_kallsyms", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/bpftool", .data = "bpftool v7.4.0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/clang", .data = "clang version 18.1.0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/llvm-config", .data = "18.1.0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/lib/pkgconfig/libbpf.pc", .data = "Version: 1.4.0\n" });
    const root_path = try testingTmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root_path);

    var facts = try collectFromRoot(std.testing.allocator, root_path, "6.12.1-lab", "000000c000200000");
    defer deinit(&facts, std.testing.allocator);
    try std.testing.expectEqual(FactStatus.present, facts.kernel.status);
    try std.testing.expectEqualStrings("/proc/config.gz", facts.kernel_config.source);
    try std.testing.expectEqual(FactStatus.present, facts.kernel_config.bpf_jit_always_on);
    try std.testing.expectEqualStrings("1", facts.bpf_jit_sysctls.enable.value);
    try std.testing.expectEqual(FactStatus.present, facts.toolchain.clang.status);
    try std.testing.expect(facts.privileges.cap_bpf);
    try std.testing.expect(facts.privileges.cap_perfmon);
    try std.testing.expect(facts.privileges.cap_sys_admin);
}

test "readiness collection uses boot config fallback and fails closed on too old tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try testingMakePath(&tmp.dir, "boot");
    try testingMakePath(&tmp.dir, "usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "boot/config-6.12.1-lab", .data = "CONFIG_SCHED_CLASS_EXT=y\nCONFIG_BPF=y\nCONFIG_BPF_SYSCALL=y\nCONFIG_BPF_JIT=y\nCONFIG_DEBUG_INFO_BTF=y\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/clang", .data = "clang version 15.0.0\n" });
    const root_path = try testingTmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root_path);

    var facts = try collectFromRoot(std.testing.allocator, root_path, "6.12.1-lab", "0");
    defer deinit(&facts, std.testing.allocator);
    try std.testing.expectEqualStrings("/boot/config-6.12.1-lab", facts.kernel_config.source);
    try std.testing.expectEqual(FactStatus.unsafe_to_assume, facts.kernel_config.status);
    try std.testing.expectEqual(FactStatus.unsafe_to_assume, facts.toolchain.clang.status);
    try std.testing.expectEqual(FactStatus.missing, facts.bpf_jit_sysctls.enable.status);
}

test "readiness collection reports unreadable config path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try testingMakePath(&tmp.dir, "proc");
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/config.gz", .data = "CONFIG_SCHED_CLASS_EXT=y\n" });
    try tmp.dir.setFilePermissions(io, "proc/config.gz", std.Io.File.Permissions.fromMode(0), .{});
    const root_path = try testingTmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root_path);

    var facts = try collectFromRoot(std.testing.allocator, root_path, "6.12.1-lab", "0");
    defer deinit(&facts, std.testing.allocator);
    try std.testing.expectEqual(FactStatus.unreadable, facts.kernel_config.status);
    try std.testing.expectEqual(FactStatus.missing, facts.toolchain.clang.status);
}

test "readiness collection fails closed for too old kernel missing config and malformed capabilities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try testingTmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root_path);

    var facts = try collectFromRoot(std.testing.allocator, root_path, "6.11.9", "not-hex");
    defer deinit(&facts, std.testing.allocator);
    try std.testing.expectEqual(FactStatus.unsafe_to_assume, facts.kernel.status);
    try std.testing.expectEqual(FactStatus.unsafe_to_assume, facts.kernel_config.status);
    try std.testing.expectEqual(FactStatus.unknown, facts.privileges.status);
    try std.testing.expectEqual(FactStatus.missing, facts.toolchain.clang.status);
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

test "readiness module pulls command and gzip helper tests" {
    std.testing.refAllDecls(command);
    std.testing.refAllDecls(gzip);
}

test "readiness collection fails closed on no digit bpftool output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try testingMakePath(&tmp.dir, "usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/bpftool", .data = "bpftool unknown\n" });
    const root_path = try testingTmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root_path);

    var facts = try collectFromRoot(std.testing.allocator, root_path, "6.12.1-lab", "0");
    defer deinit(&facts, std.testing.allocator);
    try std.testing.expectEqual(FactStatus.unsafe_to_assume, facts.toolchain.bpftool.status);
}
