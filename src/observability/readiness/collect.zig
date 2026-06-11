const std = @import("std");
const sched_ext = @import("../../sched_ext/root.zig");
const types = @import("types.zig");
const command = @import("command.zig");
const gzip = @import("gzip.zig");

pub fn collectFromRoot(allocator: std.mem.Allocator, root_path: []const u8, kernel_release: []const u8, cap_eff_hex: []const u8) !types.ReadinessFacts {
    return .{
        .kernel = kernelReadiness(kernel_release),
        .kernel_config = try kernelConfigFromRoot(allocator, root_path, kernel_release),
        .bpf_jit_sysctls = try bpfJitSysctlsFromRoot(allocator, root_path),
        .toolchain = try toolchainFromRoot(allocator, root_path),
        .privileges = privilegeFacts(cap_eff_hex),
    };
}

pub fn deinit(facts: *types.ReadinessFacts, allocator: std.mem.Allocator) void {
    if (facts.kernel_config.source.len != 0) allocator.free(facts.kernel_config.source);
    sched_ext.freeFact(allocator, facts.bpf_jit_sysctls.enable);
    sched_ext.freeFact(allocator, facts.bpf_jit_sysctls.harden);
    sched_ext.freeFact(allocator, facts.bpf_jit_sysctls.kallsyms);
    sched_ext.freeFact(allocator, facts.toolchain.bpftool);
    sched_ext.freeFact(allocator, facts.toolchain.clang);
    sched_ext.freeFact(allocator, facts.toolchain.llvm);
    sched_ext.freeFact(allocator, facts.toolchain.libbpf_pkg_config);
}

fn kernelReadiness(release: []const u8) types.KernelReadiness {
    return .{ .status = if (kernelAtLeast(release, 6, 12)) .present else .unsafe_to_assume, .minimum_release = "6.12" };
}

fn kernelConfigFromRoot(allocator: std.mem.Allocator, root_path: []const u8, release: []const u8) !types.KernelConfigFacts {
    const boot_path = try std.fmt.allocPrint(allocator, "/boot/config-{s}", .{release});
    defer allocator.free(boot_path);
    const config = try firstConfig(allocator, root_path, &.{ "/proc/config.gz", boot_path, "/boot/config" });
    defer sched_ext.freeFact(allocator, config.fact);
    if (config.fact.status != .present) return unknownConfig(allocator, config.fact.status);
    var facts = types.KernelConfigFacts{
        .status = .present,
        .source = try allocator.dupe(u8, config.source),
        .sched_class_ext = configStatus(config.fact.value, "CONFIG_SCHED_CLASS_EXT=y"),
        .bpf = configStatus(config.fact.value, "CONFIG_BPF=y"),
        .bpf_syscall = configStatus(config.fact.value, "CONFIG_BPF_SYSCALL=y"),
        .bpf_jit = configStatus(config.fact.value, "CONFIG_BPF_JIT=y"),
        .bpf_jit_always_on = configStatus(config.fact.value, "CONFIG_BPF_JIT_ALWAYS_ON=y"),
        .bpf_jit_default_on = configStatus(config.fact.value, "CONFIG_BPF_JIT_DEFAULT_ON=y"),
        .debug_info_btf = configStatus(config.fact.value, "CONFIG_DEBUG_INFO_BTF=y"),
    };
    if (facts.sched_class_ext != .present or facts.bpf != .present or facts.bpf_syscall != .present or facts.bpf_jit != .present or facts.bpf_jit_always_on != .present or facts.bpf_jit_default_on != .present or facts.debug_info_btf != .present) facts.status = .unsafe_to_assume;
    return facts;
}

const ConfigProbe = struct { fact: sched_ext.TextFact, source: []const u8 };

fn firstConfig(allocator: std.mem.Allocator, root_path: []const u8, paths: []const []const u8) !ConfigProbe {
    var saw_unreadable = false;
    for (paths) |path| {
        const fact = try readConfigPath(allocator, root_path, path);
        if (fact.status == .present) return .{ .fact = fact, .source = path };
        if (fact.status == .unreadable) saw_unreadable = true;
        sched_ext.freeFact(allocator, fact);
    }
    return .{ .fact = .{ .status = if (saw_unreadable) .unreadable else .missing, .value = "" }, .source = "unavailable" };
}

fn readConfigPath(allocator: std.mem.Allocator, root_path: []const u8, path: []const u8) !sched_ext.TextFact {
    const fact = try sched_ext.readLimitedTextFactFromRoot(allocator, root_path, path, 512 * 1024);
    if (fact.status != .present or !std.mem.eql(u8, path, "/proc/config.gz") or !gzip.isGzip(fact.value)) return fact;
    const decompressed = try gzip.decompressBytes(allocator, fact.value) orelse return .{ .status = .unsafe_to_assume, .value = fact.value };
    sched_ext.freeFact(allocator, fact);
    return .{ .status = .present, .value = decompressed };
}

fn unknownConfig(allocator: std.mem.Allocator, status: types.FactStatus) !types.KernelConfigFacts {
    return .{ .status = if (status == .unreadable) .unreadable else .unsafe_to_assume, .source = try allocator.dupe(u8, "unavailable"), .sched_class_ext = .unsafe_to_assume, .bpf = .unsafe_to_assume, .bpf_syscall = .unsafe_to_assume, .bpf_jit = .unsafe_to_assume, .bpf_jit_always_on = .unsafe_to_assume, .bpf_jit_default_on = .unsafe_to_assume, .debug_info_btf = .unsafe_to_assume };
}

fn bpfJitSysctlsFromRoot(allocator: std.mem.Allocator, root_path: []const u8) !types.BpfJitSysctlFacts {
    return .{
        .enable = try sched_ext.readSmallFactFromRoot(allocator, root_path, "/proc/sys/net/core/bpf_jit_enable"),
        .harden = try sched_ext.readSmallFactFromRoot(allocator, root_path, "/proc/sys/net/core/bpf_jit_harden"),
        .kallsyms = try sched_ext.readSmallFactFromRoot(allocator, root_path, "/proc/sys/net/core/bpf_jit_kallsyms"),
    };
}

fn toolchainFromRoot(allocator: std.mem.Allocator, root_path: []const u8) !types.ToolchainFacts {
    return .{
        .bpftool = try versionFact(allocator, root_path, "/usr/bin/bpftool", "bpftool", 0),
        .clang = try versionFact(allocator, root_path, "/usr/bin/clang", "clang", 16),
        .llvm = try versionFact(allocator, root_path, "/usr/bin/llvm-config", "LLVM", 16),
        .libbpf_pkg_config = try versionFact(allocator, root_path, "/usr/lib/pkgconfig/libbpf.pc", "libbpf", 1),
    };
}

fn versionFact(allocator: std.mem.Allocator, root_path: []const u8, path: []const u8, label: []const u8, min_major: u32) !sched_ext.TextFact {
    const text = if (root_path.len == 0)
        try liveVersionOutput(allocator, label)
    else
        try injectedVersionOutput(allocator, root_path, path);
    if (text) |value| {
        errdefer allocator.free(value);
        const major = command.firstVersionMajor(value) orelse return .{ .status = .unsafe_to_assume, .value = value };
        if (major < min_major) return .{ .status = .unsafe_to_assume, .value = value };
        return .{ .status = .present, .value = value };
    }
    return .{ .status = .missing, .value = "" };
}

fn liveVersionOutput(allocator: std.mem.Allocator, label: []const u8) !?[]u8 {
    if (std.mem.eql(u8, label, "bpftool")) {
        if (try command.runVersion(allocator, &.{ "/usr/bin/bpftool", "version" })) |value| return value;
        if (try pacmanVersion(allocator, "bpftool")) |value| return value;
        if (try pacmanVersion(allocator, "bpf")) |value| {
            defer allocator.free(value);
            return try std.fmt.allocPrint(allocator, "bpftool {s}", .{value});
        }
        return null;
    }
    if (std.mem.eql(u8, label, "clang")) {
        if (try command.runVersion(allocator, &.{ "/usr/bin/clang", "--version" })) |value| return value;
        if (try clangSymlinkVersion(allocator)) |value| return value;
        return pacmanVersion(allocator, "clang");
    }
    if (std.mem.eql(u8, label, "LLVM")) {
        if (try command.runVersion(allocator, &.{ "/usr/bin/llvm-config", "--version" })) |value| return value;
        if (try llvmCmakeVersion(allocator)) |value| return value;
        return pacmanVersion(allocator, "llvm");
    }
    if (std.mem.eql(u8, label, "libbpf")) {
        if (try command.runVersion(allocator, &.{ "/usr/bin/pkg-config", "--modversion", "libbpf" })) |value| return value;
        if (try libbpfPcVersion(allocator)) |value| return value;
        return pacmanVersion(allocator, "libbpf");
    }
    return null;
}

fn clangSymlinkVersion(allocator: std.mem.Allocator) !?[]u8 {
    var buffer: [256]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(std.Io.Threaded.global_single_threaded.io(), "/usr/bin/clang", &buffer) catch return null;
    const target = buffer[0..n];
    if (command.firstVersionMajor(target) == null) return null;
    return try std.fmt.allocPrint(allocator, "clang {s}", .{target});
}

fn llvmCmakeVersion(allocator: std.mem.Allocator) !?[]u8 {
    const source = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "/usr/lib/cmake/llvm/LLVMConfigVersion.cmake", allocator, .limited(4096)) catch return null;
    defer allocator.free(source);
    if (betweenQuotes(source)) |version| return try std.fmt.allocPrint(allocator, "LLVM {s}", .{version});
    return null;
}

fn libbpfPcVersion(allocator: std.mem.Allocator) !?[]u8 {
    const source = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "/usr/lib/pkgconfig/libbpf.pc", allocator, .limited(4096)) catch return null;
    defer allocator.free(source);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Version:")) return try std.fmt.allocPrint(allocator, "libbpf {s}", .{std.mem.trim(u8, line["Version:".len..], " \t")});
    }
    return null;
}

fn pacmanVersion(allocator: std.mem.Allocator, package: []const u8) !?[]u8 {
    const root = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "/var/lib/pacman/local/ALPM_DB_VERSION", allocator, .limited(16)) catch return null;
    allocator.free(root);
    var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), "/var/lib/pacman/local", .{ .iterate = true }) catch return null;
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var iter = dir.iterate();
    while (try iter.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (std.mem.startsWith(u8, entry.name, package) and entry.name.len > package.len and entry.name[package.len] == '-') {
            return try std.fmt.allocPrint(allocator, "{s} {s}", .{ package, entry.name[package.len + 1 ..] });
        }
    }
    return null;
}

fn betweenQuotes(source: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, source, '"') orelse return null;
    const rest = source[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..second];
}

fn injectedVersionOutput(allocator: std.mem.Allocator, root_path: []const u8, path: []const u8) !?[]u8 {
    const fact = try sched_ext.readSmallFactFromRoot(allocator, root_path, path);
    if (fact.status == .present) return @constCast(fact.value);
    sched_ext.freeFact(allocator, fact);
    return null;
}

fn privilegeFacts(cap_eff_hex: []const u8) types.PrivilegeFacts {
    const bits = std.fmt.parseUnsigned(u64, cap_eff_hex, 16) catch return .{ .status = .unknown, .cap_bpf = false, .cap_sys_admin = false, .cap_perfmon = false };
    return .{ .status = .present, .cap_bpf = hasCap(bits, 39), .cap_sys_admin = hasCap(bits, 21), .cap_perfmon = hasCap(bits, 38) };
}

fn hasCap(bits: u64, cap: u6) bool {
    return (bits & (@as(u64, 1) << cap)) != 0;
}

fn kernelAtLeast(release: []const u8, min_major: u32, min_minor: u32) bool {
    var parts = std.mem.splitScalar(u8, release, '.');
    const major = std.fmt.parseUnsigned(u32, parts.next() orelse return false, 10) catch return false;
    const minor_part = parts.next() orelse return false;
    var n: usize = 0;
    while (n < minor_part.len and std.ascii.isDigit(minor_part[n])) : (n += 1) {}
    const minor = std.fmt.parseUnsigned(u32, minor_part[0..n], 10) catch return false;
    return major > min_major or (major == min_major and minor >= min_minor);
}

pub fn configStatus(config: []const u8, needle: []const u8) types.FactStatus {
    var lines = std.mem.splitScalar(u8, config, 10);
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), needle)) return .present;
    }
    return .unsafe_to_assume;
}

test "kernel config parser requires exact enabled lines" {
    const bad =
        "# CONFIG_SCHED_CLASS_EXT=y\n" ++
        "XCONFIG_SCHED_CLASS_EXT=y\n" ++
        "CONFIG_SCHED_CLASS_EXT=y # suffix\n" ++
        "CONFIG_SCHED_CLASS_EXT=m\n";
    try std.testing.expectEqual(types.FactStatus.unsafe_to_assume, configStatus(bad, "CONFIG_SCHED_CLASS_EXT=y"));
    try std.testing.expectEqual(types.FactStatus.present, configStatus("  CONFIG_SCHED_CLASS_EXT=y\r\n", "CONFIG_SCHED_CLASS_EXT=y"));
}
