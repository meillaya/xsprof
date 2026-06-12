const std = @import("std");

pub const action_journal_schema = "zig-scheduler/action-journal/v1";
pub const daemon_event_journal_schema = "zig-scheduler/daemon-event-journal/v1";
pub const vm_transcript_index_schema = "zig-scheduler/vm-transcript-index/v1";
pub const live_attach_proof_schema = "zig-scheduler/live-attach-proof/v1";
pub const live_behavior_proof_schema = "zig-scheduler/live-behavior-proof/v1";
pub const rollback_result_schema = "zig-scheduler/rollback-result/v1";
pub const tui_session_transcript_schema = "zig-scheduler/tui-session-transcript/v1";
pub const vm_marker_path = "/run/zig-scheduler-vm-lab.marker";

pub const EvidenceMode = enum {
    host_safe_surrogate,
    vm_configured_skip,
    vm_live,
};

pub const LiveGate = struct {
    evidence_mode: EvidenceMode,
    vm_kind: []const u8 = "",
    vm_marker_present: bool = false,
    vm_marker_path_value: []const u8 = "",
    host_mutation: bool = true,
};

pub const EvidenceError = error{
    NotLiveEvidence,
    NotVmEvidence,
    VmMarkerMissing,
    HostMutationEvidence,
};

pub fn validateVmLiveGate(gate: LiveGate) EvidenceError!void {
    if (gate.host_mutation) return error.HostMutationEvidence;
    if (gate.evidence_mode != .vm_live) return error.NotLiveEvidence;
    if (!std.mem.eql(u8, gate.vm_kind, "qemu-vm")) return error.NotVmEvidence;
    if (!gate.vm_marker_present or !std.mem.eql(u8, gate.vm_marker_path_value, vm_marker_path)) {
        return error.VmMarkerMissing;
    }
}

test "live evidence gate rejects surrogate as vm live" {
    try std.testing.expectError(error.NotVmEvidence, validateVmLiveGate(.{
        .evidence_mode = .vm_live,
        .vm_kind = "host-safe-surrogate",
        .vm_marker_present = false,
        .vm_marker_path_value = "",
        .host_mutation = false,
    }));
}

test "live evidence gate requires marker and no host mutation" {
    try std.testing.expectError(error.HostMutationEvidence, validateVmLiveGate(.{
        .evidence_mode = .vm_live,
        .vm_kind = "qemu-vm",
        .vm_marker_present = true,
        .vm_marker_path_value = vm_marker_path,
        .host_mutation = true,
    }));
    try std.testing.expectError(error.VmMarkerMissing, validateVmLiveGate(.{
        .evidence_mode = .vm_live,
        .vm_kind = "qemu-vm",
        .vm_marker_present = false,
        .vm_marker_path_value = vm_marker_path,
        .host_mutation = false,
    }));
    try validateVmLiveGate(.{
        .evidence_mode = .vm_live,
        .vm_kind = "qemu-vm",
        .vm_marker_present = true,
        .vm_marker_path_value = vm_marker_path,
        .host_mutation = false,
    });
}
