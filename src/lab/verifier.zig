const std = @import("std");

pub const VerifierOnlyEvidence = struct {
    schema: []const u8 = "",
    status: []const u8 = "",
    vm_marker: []const u8 = "",
    object_sha256: []const u8 = "",
    bpf_metadata_path: []const u8 = "",
    bpf_metadata_object_sha256: []const u8 = "",
    parsed_verifier_status: []const u8 = "",
    parsed_verifier_reason: []const u8 = "",
    verifier_log_path: []const u8 = "",
    verifier_parse_path: []const u8 = "",
    sched_ext_state_before: []const u8 = "",
    sched_ext_state_after: []const u8 = "",
    enable_seq_before: []const u8 = "",
    enable_seq_after: []const u8 = "",
    cgroup_membership_before: []const u8 = "",
    cgroup_membership_after: []const u8 = "",
    host_mutation: bool = true,
};

pub const ValidationError = error{
    WrongSchema,
    NotVmEvidence,
    MissingObjectHash,
    MissingBpfMetadata,
    MissingParsedVerifierStatus,
    MissingVerifierLog,
    MissingVerifierParse,
    SchedExtStateChanged,
    CgroupMembershipChanged,
    HostMutationEvidence,
};

pub fn parseVerifierOnlyEvidence(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(VerifierOnlyEvidence) {
    return std.json.parseFromSlice(VerifierOnlyEvidence, allocator, source, .{ .allocate = .alloc_always });
}

pub fn parseAndValidateVerifierOnlyEvidence(allocator: std.mem.Allocator, source: []const u8) !void {
    var parsed = try parseVerifierOnlyEvidence(allocator, source);
    defer parsed.deinit();
    try validateVerifierOnlyEvidence(parsed.value);
}

pub fn validateVerifierOnlyEvidence(evidence: VerifierOnlyEvidence) ValidationError!void {
    if (!std.mem.eql(u8, evidence.schema, "zig-scheduler/verifier-only-evidence/v1")) return error.WrongSchema;
    if (!std.mem.eql(u8, evidence.vm_marker, "/run/zig-scheduler-vm-lab.marker")) return error.NotVmEvidence;
    if (evidence.object_sha256.len != 64) return error.MissingObjectHash;
    if (evidence.bpf_metadata_object_sha256.len != 64) return error.MissingBpfMetadata;
    if (!std.mem.endsWith(u8, evidence.bpf_metadata_path, "zigsched_minimal.bpf.meta.json")) return error.MissingBpfMetadata;
    if (evidence.parsed_verifier_status.len == 0 or evidence.parsed_verifier_reason.len == 0) return error.MissingParsedVerifierStatus;
    if (!std.mem.endsWith(u8, evidence.verifier_log_path, "bpf-verifier.log")) return error.MissingVerifierLog;
    if (!std.mem.endsWith(u8, evidence.verifier_parse_path, "verifier-parsed.json")) return error.MissingVerifierParse;
    if (!std.mem.eql(u8, evidence.sched_ext_state_before, evidence.sched_ext_state_after)) return error.SchedExtStateChanged;
    if (!std.mem.eql(u8, evidence.enable_seq_before, evidence.enable_seq_after)) return error.SchedExtStateChanged;
    if (!std.mem.eql(u8, evidence.cgroup_membership_before, evidence.cgroup_membership_after)) return error.CgroupMembershipChanged;
    if (evidence.host_mutation) return error.HostMutationEvidence;
}

test "verifier-only evidence fixture validates no state or cgroup delta" {
    const source = try readFixture(std.testing.allocator, "fixtures/lab/verifier-only-evidence.json");
    defer std.testing.allocator.free(source);
    try parseAndValidateVerifierOnlyEvidence(std.testing.allocator, source);
}

test "verifier-only evidence rejects host and mutation deltas" {
    try std.testing.expectError(error.NotVmEvidence, parseAndValidateVerifierOnlyEvidence(std.testing.allocator,
        \\{"schema":"zig-scheduler/verifier-only-evidence/v1","vm_marker":"host","object_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","bpf_metadata_path":"zig-out/bpf/zigsched_minimal.bpf.meta.json","bpf_metadata_object_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","parsed_verifier_status":"PASS","parsed_verifier_reason":"VERIFIER_ACCEPTED","verifier_log_path":"evidence/lab/verifier-dev/bpf-verifier.log","verifier_parse_path":"evidence/lab/verifier-dev/verifier-parsed.json","sched_ext_state_before":"enabled","sched_ext_state_after":"enabled","enable_seq_before":"1","enable_seq_after":"1","cgroup_membership_before":"aaa","cgroup_membership_after":"aaa","host_mutation":false}
    ));
    try std.testing.expectError(error.SchedExtStateChanged, parseAndValidateVerifierOnlyEvidence(std.testing.allocator,
        \\{"schema":"zig-scheduler/verifier-only-evidence/v1","vm_marker":"/run/zig-scheduler-vm-lab.marker","object_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","bpf_metadata_path":"zig-out/bpf/zigsched_minimal.bpf.meta.json","bpf_metadata_object_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","parsed_verifier_status":"PASS","parsed_verifier_reason":"VERIFIER_ACCEPTED","verifier_log_path":"evidence/lab/verifier-dev/bpf-verifier.log","verifier_parse_path":"evidence/lab/verifier-dev/verifier-parsed.json","sched_ext_state_before":"enabled","sched_ext_state_after":"disabled","enable_seq_before":"1","enable_seq_after":"1","cgroup_membership_before":"aaa","cgroup_membership_after":"aaa","host_mutation":false}
    ));
    try std.testing.expectError(error.CgroupMembershipChanged, parseAndValidateVerifierOnlyEvidence(std.testing.allocator,
        \\{"schema":"zig-scheduler/verifier-only-evidence/v1","vm_marker":"/run/zig-scheduler-vm-lab.marker","object_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","bpf_metadata_path":"zig-out/bpf/zigsched_minimal.bpf.meta.json","bpf_metadata_object_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","parsed_verifier_status":"PASS","parsed_verifier_reason":"VERIFIER_ACCEPTED","verifier_log_path":"evidence/lab/verifier-dev/bpf-verifier.log","verifier_parse_path":"evidence/lab/verifier-dev/verifier-parsed.json","sched_ext_state_before":"enabled","sched_ext_state_after":"enabled","enable_seq_before":"1","enable_seq_after":"1","cgroup_membership_before":"aaa","cgroup_membership_after":"bbb","host_mutation":false}
    ));
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}
