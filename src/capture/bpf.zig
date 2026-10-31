//! VM-only BPF lane. The host is always refused before any BPF syscall.
//! Inside a detected VM, load a verifier-safe no-op tracepoint program and
//! attach it to sched_switch through perf_event_open; no host state changes.

const std = @import("std");
const builtin = @import("builtin");
const bpf = std.os.linux.BPF;

pub const State = enum { READY, DEGRADED, SKIP, REFUSE };

pub const Result = struct {
    state: State,
    reason: []const u8 = "",
    vm_marker: []const u8 = "",
    libbpf: bool = false,
    program_loaded: bool = false,
    attached: bool = false,
};

const tracefs_candidates = [_][]const u8{
    "/sys/kernel/tracing",
    "/sys/kernel/debug/tracing",
};

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max)) catch null;
}

pub fn isVmMarker(text: []const u8) bool {
    inline for ([_][]const u8{
        "QEMU", "KVM", "Virtual", "virtual", "VMware", "Xen", "Hyper-V",
    }) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

fn detectVm(io: std.Io, allocator: std.mem.Allocator) ?[]const u8 {
    inline for ([_][]const u8{
        "/sys/class/dmi/id/product_name",
        "/sys/class/dmi/id/sys_vendor",
        "/sys/hypervisor/type",
    }) |path| {
        if (readFile(io, allocator, path, 256)) |text| {
            if (isVmMarker(text)) return std.mem.trim(u8, text, " \t\r\n");
        }
    }
    return null;
}

fn libbpfPresent() bool {
    var library = std.DynLib.open("libbpf.so.1") catch return false;
    defer library.close();
    return library.lookup(*anyopaque, "bpf_object__open_file") != null;
}

pub fn probe(io: std.Io, allocator: std.mem.Allocator) !Result {
    if (builtin.os.tag != .linux) {
        return .{ .state = .SKIP, .reason = "non-Linux host: BPF is Linux-only" };
    }
    const marker = detectVm(io, allocator) orelse
        return .{ .state = .REFUSE, .reason = "BPF is VM-marker-gated; host refused" };
    return .{
        .state = .SKIP,
        .reason = "VM detected; run the bpf command to load the no-op probe",
        .vm_marker = marker,
        .libbpf = libbpfPresent(),
    };
}

fn tracefsRoot(io: std.Io) ?[]const u8 {
    for (tracefs_candidates) |base| {
        var path_buffer: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/events/sched/sched_switch/id", .{base}) catch continue;
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch continue;
        file.close(io);
        return base;
    }
    return null;
}

pub fn run(io: std.Io, allocator: std.mem.Allocator) !Result {
    const result = try probe(io, allocator);
    if (builtin.os.tag != .linux) return result;
    if (result.state != .SKIP and result.state != .READY) return result;
    if (comptime builtin.os.tag == .linux) return runLinux(io, allocator, result);
    return result;
}

fn runLinux(io: std.Io, allocator: std.mem.Allocator, start: Result) !Result {
    var result = start;
    const root = tracefsRoot(io) orelse {
        result.state = .SKIP;
        result.reason = "tracefs sched_switch id unavailable";
        return result;
    };
    var path_buffer: [256]u8 = undefined;
    const id_path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/events/sched/sched_switch/id",
        .{root},
    );
    const id_text = readFile(io, allocator, id_path, 64) orelse {
        result.state = .SKIP;
        result.reason = "cannot read sched_switch id";
        return result;
    };
    const trace_id = std.fmt.parseInt(u64, std.mem.trim(u8, id_text, " \t\r\n"), 10) catch {
        result.state = .SKIP;
        result.reason = "invalid sched_switch id";
        return result;
    };

    const program = [_]bpf.Insn{
        bpf.Insn.mov(.r0, 0),
        bpf.Insn.exit(),
    };
    var log_buffer: [4096]u8 = undefined;
    var log = bpf.Log{ .level = 1, .buf = &log_buffer };
    const program_fd = bpf.prog_load(
        .tracepoint,
        &program,
        &log,
        "GPL",
        0,
        0,
    ) catch {
        result.state = .REFUSE;
        result.reason = "BPF_PROG_LOAD refused by kernel privileges/verifier";
        return result;
    };
    defer _ = std.os.linux.close(program_fd);
    result.program_loaded = true;

    var attr: std.os.linux.perf_event_attr = .{
        .type = .TRACEPOINT,
        .config = trace_id,
        .sample_period_or_freq = 0,
        .flags = .{ .disabled = true },
    };
    const perf_fd_raw = std.os.linux.perf_event_open(
        &attr,
        -1,
        0,
        -1,
        std.os.linux.PERF.FLAG.FD_CLOEXEC,
    );
    if (std.os.linux.errno(perf_fd_raw) != .SUCCESS) {
        result.state = .SKIP;
        result.reason = "perf_event_open for BPF attachment failed";
        return result;
    }
    const perf_fd: i32 = @intCast(perf_fd_raw);
    defer _ = std.os.linux.close(perf_fd);

    const set_rc = std.os.linux.ioctl(perf_fd, perfEventIocSetBpf, @intCast(program_fd));
    if (std.os.linux.errno(set_rc) != .SUCCESS) {
        result.state = .SKIP;
        result.reason = "PERF_EVENT_IOC_SET_BPF failed";
        return result;
    }
    const enable_rc = std.os.linux.ioctl(perf_fd, perfEventIocEnable, 0);
    if (std.os.linux.errno(enable_rc) != .SUCCESS) {
        result.state = .SKIP;
        result.reason = "PERF_EVENT_IOC_ENABLE failed";
        return result;
    }
    std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    _ = std.os.linux.ioctl(perf_fd, perfEventIocDisable, 0);
    result.state = .READY;
    result.reason = "no-op tracepoint program attached for 200 ms";
    result.attached = true;
    return result;
}

const perfEventIocSetBpf: u32 = 0x40042408;
const perfEventIocEnable: u32 = 0x2400;
const perfEventIocDisable: u32 = 0x2401;

test "VM marker detection is explicit" {
    try std.testing.expect(isVmMarker("Apple Virtualization Generic Platform\n"));
    try std.testing.expect(isVmMarker("QEMU Standard PC"));
    try std.testing.expect(isVmMarker("KVM"));
    try std.testing.expect(!isVmMarker("MacBookPro18,3"));
    try std.testing.expect(!isVmMarker("Dell Inc."));
}
