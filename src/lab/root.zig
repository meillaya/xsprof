const std = @import("std");

pub const tuples = @import("tuples.zig");
pub const verifier = @import("verifier.zig");
pub const evidence = @import("evidence.zig");

pub const KernelTuple = struct {
    release: []const u8 = "",
    arch: []const u8 = "",
    config_sha256: []const u8 = "",
};

pub const LabTuple = struct {
    kind: []const u8 = "",
    image: []const u8 = "",
    kernel: []const u8 = "",
};

pub const VerifierLogEntry = struct {
    id: []const u8 = "",
    sha256: []const u8 = "",
    summary: []const u8 = "",
};

pub const VerifierLogIndex = struct {
    entries: []const VerifierLogEntry = &.{},
};

pub const RollbackSnapshot = struct {
    id: []const u8 = "",
    created_at: []const u8 = "",
    scope: []const u8 = "",
    state_before: []const u8 = "",
    state_after: []const u8 = "",
    ops_before: []const u8 = "",
    ops_after: []const u8 = "",
    enable_seq_before: []const u8 = "",
    enable_seq_after: []const u8 = "",
};

pub const AuditRecord = struct {
    id: []const u8 = "",
    operator: []const u8 = "",
    decision: []const u8 = "",
};

pub const ReleaseApproval = struct {
    id: []const u8 = "",
    approver: []const u8 = "",
    status: []const u8 = "",
};

pub const LabManifest = struct {
    audit_id: []const u8 = "",
    rollback_snapshot_id: []const u8 = "",
    git_sha: []const u8 = "",
    kernel_tuple: KernelTuple = .{},
    lab_tuple: LabTuple = .{},
    mutation_evidence_kind: []const u8 = "",
    verifier_log_index: VerifierLogIndex = .{},
    rollback_snapshot: RollbackSnapshot = .{},
    audit_record: AuditRecord = .{},
    release_approval: ReleaseApproval = .{},
};

pub const ValidationError = error{
    MissingAuditId,
    MissingRollbackId,
    MissingGitSha,
    MissingKernelTuple,
    NonVmMutationEvidence,
    UnboundedVerifierLog,
    SecretLikeEvidence,
    MissingSchedExtFacts,
};

pub fn validateRollbackSnapshot(snapshot: RollbackSnapshot) ValidationError!void {
    if (snapshot.id.len == 0) return error.MissingRollbackId;
    if (snapshot.state_before.len == 0 or snapshot.state_after.len == 0 or
        snapshot.ops_before.len == 0 or snapshot.ops_after.len == 0 or
        snapshot.enable_seq_before.len == 0 or snapshot.enable_seq_after.len == 0)
    {
        return error.MissingSchedExtFacts;
    }
}

pub fn parseRollbackSnapshot(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(RollbackSnapshot) {
    return std.json.parseFromSlice(RollbackSnapshot, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn parseLabManifest(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(LabManifest) {
    return std.json.parseFromSlice(LabManifest, allocator, source, .{ .allocate = .alloc_always });
}

pub fn parseAndValidateLabManifest(allocator: std.mem.Allocator, source: []const u8) !void {
    var parsed = try parseLabManifest(allocator, source);
    defer parsed.deinit();
    try validateLabManifest(parsed.value);
}

pub fn validateLabManifest(manifest: LabManifest) ValidationError!void {
    if (!hasPrefix(manifest.audit_id, "AUD-")) return error.MissingAuditId;
    if (manifest.rollback_snapshot_id.len == 0 or manifest.rollback_snapshot.id.len == 0) return error.MissingRollbackId;
    if (manifest.git_sha.len == 0) return error.MissingGitSha;
    if (manifest.kernel_tuple.release.len == 0 or manifest.kernel_tuple.arch.len == 0 or manifest.kernel_tuple.config_sha256.len == 0) {
        return error.MissingKernelTuple;
    }
    if (!std.mem.eql(u8, manifest.mutation_evidence_kind, "vm-only") or !std.mem.eql(u8, manifest.lab_tuple.kind, "qemu-vm")) {
        return error.NonVmMutationEvidence;
    }
    try validateRollbackSnapshot(manifest.rollback_snapshot);
    if (manifest.verifier_log_index.entries.len > 32) return error.UnboundedVerifierLog;
    for (manifest.verifier_log_index.entries) |entry| {
        if (entry.summary.len > 256 or containsSecretLikeLabel(entry.summary)) return error.SecretLikeEvidence;
    }
}

fn hasPrefix(value: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, value, prefix) and value.len > prefix.len;
}

fn containsSecretLikeLabel(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "secret") != null or
        std.mem.indexOf(u8, value, "password") != null or
        std.mem.indexOf(u8, value, "token") != null or
        std.mem.indexOf(u8, value, "hostname") != null;
}

test "valid lab manifest fixture parses and validates" {
    const source = try readFixture(std.testing.allocator, "fixtures/lab/valid-manifest.json");
    defer std.testing.allocator.free(source);
    var parsed = try parseLabManifest(std.testing.allocator, source);
    defer parsed.deinit();
    try validateLabManifest(parsed.value);
    try std.testing.expectEqualStrings("AUD-2026-0001", parsed.value.audit_id);
}

test "lab manifest rejects missing audit id" {
    try std.testing.expectError(error.MissingAuditId, parseAndValidateLabManifest(std.testing.allocator,
        \\{
        \\  "rollback_snapshot_id":"RB-2026-0001",
        \\  "git_sha":"f58efb8a10a8d18eaf05967b15513095ef3f2b79",
        \\  "kernel_tuple":{"release":"6.12.0-lab","arch":"x86_64","config_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
        \\  "lab_tuple":{"kind":"qemu-vm","image":"sched-ext-lab","kernel":"6.12.0-lab"},
        \\  "mutation_evidence_kind":"vm-only",
        \\  "verifier_log_index":{"entries":[]},
        \\  "rollback_snapshot":{"id":"RB-2026-0001","created_at":"2026-06-11T00:00:00Z","scope":"allowlisted-cgroup"},
        \\  "audit_record":{"id":"AUD-2026-0001","operator":"lab-operator","decision":"approved-for-lab"},
        \\  "release_approval":{"id":"REL-2026-0001","approver":"release-guardian","status":"lab-only"}
        \\}
    ));
}

test "lab manifest rejects missing rollback id" {
    try std.testing.expectError(error.MissingRollbackId, parseAndValidateLabManifest(std.testing.allocator,
        \\{"audit_id":"AUD-2026-0001","rollback_snapshot_id":"","git_sha":"f58efb8a10a8d18eaf05967b15513095ef3f2b79","kernel_tuple":{"release":"6.12.0-lab","arch":"x86_64","config_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"lab_tuple":{"kind":"qemu-vm","image":"sched-ext-lab","kernel":"6.12.0-lab"},"mutation_evidence_kind":"vm-only","verifier_log_index":{"entries":[]},"rollback_snapshot":{"id":"","created_at":"2026-06-11T00:00:00Z","scope":"allowlisted-cgroup"},"audit_record":{"id":"AUD-2026-0001","operator":"lab-operator","decision":"approved-for-lab"},"release_approval":{"id":"REL-2026-0001","approver":"release-guardian","status":"lab-only"}}
    ));
}

test "lab manifest rejects missing kernel tuple and git sha" {
    try std.testing.expectError(error.MissingGitSha, parseAndValidateLabManifest(std.testing.allocator,
        \\{"audit_id":"AUD-2026-0001","rollback_snapshot_id":"RB-2026-0001","git_sha":"","kernel_tuple":{"release":"","arch":"x86_64","config_sha256":""},"lab_tuple":{"kind":"qemu-vm","image":"sched-ext-lab","kernel":"6.12.0-lab"},"mutation_evidence_kind":"vm-only","verifier_log_index":{"entries":[]},"rollback_snapshot":{"id":"RB-2026-0001","created_at":"2026-06-11T00:00:00Z","scope":"allowlisted-cgroup"},"audit_record":{"id":"AUD-2026-0001","operator":"lab-operator","decision":"approved-for-lab"},"release_approval":{"id":"REL-2026-0001","approver":"release-guardian","status":"lab-only"}}
    ));
}

test "lab manifest rejects missing kernel tuple" {
    try std.testing.expectError(error.MissingKernelTuple, parseAndValidateLabManifest(std.testing.allocator,
        \\{"audit_id":"AUD-2026-0001","rollback_snapshot_id":"RB-2026-0001","git_sha":"f58efb8a10a8d18eaf05967b15513095ef3f2b79","kernel_tuple":{"release":"","arch":"x86_64","config_sha256":""},"lab_tuple":{"kind":"qemu-vm","image":"sched-ext-lab","kernel":"6.12.0-lab"},"mutation_evidence_kind":"vm-only","verifier_log_index":{"entries":[]},"rollback_snapshot":{"id":"RB-2026-0001","created_at":"2026-06-11T00:00:00Z","scope":"allowlisted-cgroup"},"audit_record":{"id":"AUD-2026-0001","operator":"lab-operator","decision":"approved-for-lab"},"release_approval":{"id":"REL-2026-0001","approver":"release-guardian","status":"lab-only"}}
    ));
}

test "lab manifest rejects non VM mutation evidence" {
    try std.testing.expectError(error.NonVmMutationEvidence, parseAndValidateLabManifest(std.testing.allocator,
        \\{"audit_id":"AUD-2026-0001","rollback_snapshot_id":"RB-2026-0001","git_sha":"f58efb8a10a8d18eaf05967b15513095ef3f2b79","kernel_tuple":{"release":"6.12.0-lab","arch":"x86_64","config_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"lab_tuple":{"kind":"bare-metal","image":"host","kernel":"6.12.0-lab"},"mutation_evidence_kind":"host","verifier_log_index":{"entries":[]},"rollback_snapshot":{"id":"RB-2026-0001","created_at":"2026-06-11T00:00:00Z","scope":"allowlisted-cgroup"},"audit_record":{"id":"AUD-2026-0001","operator":"lab-operator","decision":"approved-for-lab"},"release_approval":{"id":"REL-2026-0001","approver":"release-guardian","status":"lab-only"}}
    ));
}

test "supported tuple matcher rejects missing readiness facts" {
    const supported = tuples.SupportedTuple.labDefault();
    try std.testing.expect(tuples.isSupported(.{
        .kernel_release = "6.12.0-lab",
        .arch = "x86_64",
        .btf = true,
        .bpf_jit = true,
        .sched_class_ext = true,
    }, supported));
    try std.testing.expect(!tuples.isSupported(.{
        .kernel_release = "6.11.9-lab",
        .arch = "x86_64",
        .btf = true,
        .bpf_jit = true,
        .sched_class_ext = true,
    }, supported));
    try std.testing.expect(!tuples.isSupported(.{
        .kernel_release = "6.12.0-lab",
        .arch = "x86_64",
        .btf = false,
        .bpf_jit = true,
        .sched_class_ext = true,
    }, supported));
    try std.testing.expect(!tuples.isSupported(.{
        .kernel_release = "6.12.0-lab",
        .arch = "x86_64",
        .btf = true,
        .bpf_jit = false,
        .sched_class_ext = true,
    }, supported));
    try std.testing.expect(!tuples.isSupported(.{
        .kernel_release = "6.12.0-lab",
        .arch = "x86_64",
        .btf = true,
        .bpf_jit = true,
        .sched_class_ext = false,
    }, supported));
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

test "rollback snapshot validation requires before and after sched_ext facts" {
    try std.testing.expectError(error.MissingRollbackId, validateRollbackSnapshot(.{}));
    try std.testing.expectError(error.MissingSchedExtFacts, validateRollbackSnapshot(.{
        .id = "RB-demo",
        .created_at = "2026-06-11T00:00:00Z",
        .scope = "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
    }));
    try validateRollbackSnapshot(.{
        .id = "RB-demo",
        .created_at = "2026-06-11T00:00:00Z",
        .scope = "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        .state_before = "enabled",
        .state_after = "disabled",
        .ops_before = "zigsched_minimal",
        .ops_after = "none",
        .enable_seq_before = "42",
        .enable_seq_after = "42",
    });
}

test "generated rollback snapshot JSON validates against lab schema fields" {
    var parsed = try parseRollbackSnapshot(std.testing.allocator,
        \\{
        \\  "schema": "zig-scheduler/rollback-snapshot/v1",
        \\  "id": "RB-demo",
        \\  "created_at": "2026-06-11T00:00:00Z",
        \\  "scope": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        \\  "audit_id": "AUD-20990101T000000Z-deadbee-abc123",
        \\  "rollback_id": "RB-demo",
        \\  "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        \\  "state_before": "enabled",
        \\  "state_after": "disabled",
        \\  "ops_before": "zigsched_minimal",
        \\  "ops_after": "none",
        \\  "enable_seq_before": "42",
        \\  "enable_seq_after": "42",
        \\  "workload_alive": true
        \\}
    );
    defer parsed.deinit();
    try validateRollbackSnapshot(parsed.value);
}
