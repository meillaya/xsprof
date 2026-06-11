const std = @import("std");

pub const SupportedTuple = struct {
    minimum_kernel_major: u16,
    minimum_kernel_minor: u16,
    arch: []const u8,
    require_btf: bool,
    require_bpf_jit: bool,
    require_sched_class_ext: bool,

    pub fn labDefault() SupportedTuple {
        return .{
            .minimum_kernel_major = 6,
            .minimum_kernel_minor = 12,
            .arch = "x86_64",
            .require_btf = true,
            .require_bpf_jit = true,
            .require_sched_class_ext = true,
        };
    }
};

pub const CandidateTuple = struct {
    kernel_release: []const u8,
    arch: []const u8,
    btf: bool,
    bpf_jit: bool,
    sched_class_ext: bool,
};

pub fn isSupported(candidate: CandidateTuple, supported: SupportedTuple) bool {
    if (!std.mem.eql(u8, candidate.arch, supported.arch)) return false;
    if (!kernelAtLeast(candidate.kernel_release, supported.minimum_kernel_major, supported.minimum_kernel_minor)) return false;
    if (supported.require_btf and !candidate.btf) return false;
    if (supported.require_bpf_jit and !candidate.bpf_jit) return false;
    if (supported.require_sched_class_ext and !candidate.sched_class_ext) return false;
    return true;
}

fn kernelAtLeast(release: []const u8, min_major: u16, min_minor: u16) bool {
    var parts = std.mem.splitScalar(u8, release, '.');
    const major_text = parts.next() orelse return false;
    const minor_text = parts.next() orelse return false;
    const major = std.fmt.parseUnsigned(u16, trimKernelPart(major_text), 10) catch return false;
    const minor = std.fmt.parseUnsigned(u16, trimKernelPart(minor_text), 10) catch return false;
    return major > min_major or (major == min_major and minor >= min_minor);
}

fn trimKernelPart(part: []const u8) []const u8 {
    var end: usize = 0;
    while (end < part.len and std.ascii.isDigit(part[end])) : (end += 1) {}
    return part[0..end];
}

test "kernel release parser handles suffixes and rejects malformed" {
    try std.testing.expect(kernelAtLeast("6.12.0-lab", 6, 12));
    try std.testing.expect(kernelAtLeast("7.0.11-1-cachyos", 6, 12));
    try std.testing.expect(!kernelAtLeast("6.11.9", 6, 12));
    try std.testing.expect(!kernelAtLeast("not-a-kernel", 6, 12));
}
