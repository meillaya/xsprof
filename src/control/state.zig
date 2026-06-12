const std = @import("std");
const audit = @import("../audit/root.zig");
const protocol = @import("protocol.zig");

pub const ControlState = enum {
    read_only,
    verifier_only,
    partial_switch_lab,
    rollback_pending,
    rolled_back,
    refused_host,
    incident,
};

const MutationLock = enum { none, partial_attach, rollback };

pub const StateError = error{
    HostMutationRefused,
    InvalidTransition,
    InvalidAuditId,
    MutationAlreadyRunning,
    RollbackSnapshotRequired,
    StaleScope,
    TargetAllowlistRequired,
};

pub const Transition = struct {
    action: protocol.ActionKind,
    vm_marker: bool = false,
    target_allowlisted: bool = false,
    audit_id: []const u8 = "",
    rollback_id: []const u8 = "",
    stale_scope: bool = false,
};

pub const Lifecycle = struct {
    state: ControlState = .read_only,
    mutation_lock: MutationLock = .none,
    audit_id: []const u8 = "",
    rollback_id: []const u8 = "",

    pub fn init() Lifecycle {
        return .{};
    }

    pub fn apply(self: *Lifecycle, transition: Transition) StateError!void {
        return switch (transition.action) {
            .preflight, .run_lab_host_safe, .observe, .incident_drill => self.applyReadOnly(),
            .run_lab_vm, .verifier_only => self.enterVerifierOnly(transition),
            .partial_attach => self.enterPartialSwitch(transition),
            .stop, .rollback, .stop_lab_run, .rollback_lab_run => self.enterRollback(transition.rollback_id),
        };
    }

    pub fn finishRollback(self: *Lifecycle, rollback_id: []const u8) StateError!void {
        if (self.state != .rollback_pending or self.mutation_lock != .rollback) return error.InvalidTransition;
        if (rollback_id.len == 0) return error.RollbackSnapshotRequired;
        if (!std.mem.eql(u8, rollback_id, self.rollback_id)) return error.RollbackSnapshotRequired;
        self.state = .rolled_back;
        self.mutation_lock = .none;
    }

    fn applyReadOnly(self: *Lifecycle) StateError!void {
        if (self.state == .rollback_pending) return error.InvalidTransition;
    }

    fn enterVerifierOnly(self: *Lifecycle, transition: Transition) StateError!void {
        if (!transition.vm_marker) {
            self.state = .refused_host;
            return error.HostMutationRefused;
        }
        if (self.mutation_lock != .none) return error.MutationAlreadyRunning;
        self.state = .verifier_only;
    }

    fn enterPartialSwitch(self: *Lifecycle, transition: Transition) StateError!void {
        if (!transition.vm_marker) {
            self.state = .refused_host;
            return error.HostMutationRefused;
        }
        if (self.mutation_lock != .none) return error.MutationAlreadyRunning;
        if (!transition.target_allowlisted) return error.TargetAllowlistRequired;
        if (transition.stale_scope) {
            self.state = .incident;
            return error.StaleScope;
        }
        if (!audit.validateAuditId(transition.audit_id)) return error.InvalidAuditId;
        if (transition.rollback_id.len == 0) return error.RollbackSnapshotRequired;
        self.state = .partial_switch_lab;
        self.mutation_lock = .partial_attach;
        self.audit_id = transition.audit_id;
        self.rollback_id = transition.rollback_id;
    }

    fn enterRollback(self: *Lifecycle, rollback_id: []const u8) StateError!void {
        if (rollback_id.len == 0) return error.RollbackSnapshotRequired;
        if (self.state != .partial_switch_lab or self.mutation_lock != .partial_attach) {
            if (self.mutation_lock != .none) return error.MutationAlreadyRunning;
            return error.InvalidTransition;
        }
        if (!std.mem.eql(u8, rollback_id, self.rollback_id)) return error.RollbackSnapshotRequired;
        self.state = .rollback_pending;
        self.mutation_lock = .rollback;
    }
};

test "daemon state machine refuses host attach and duplicate mutation" {
    var machine = Lifecycle.init();
    try std.testing.expectEqual(ControlState.read_only, machine.state);

    try std.testing.expectError(error.HostMutationRefused, machine.apply(.{
        .action = .partial_attach,
        .vm_marker = false,
        .target_allowlisted = true,
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-demo",
    }));
    try std.testing.expectEqual(ControlState.refused_host, machine.state);

    machine = Lifecycle.init();
    try machine.apply(.{
        .action = .partial_attach,
        .vm_marker = true,
        .target_allowlisted = true,
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-demo",
    });
    try std.testing.expectEqual(ControlState.partial_switch_lab, machine.state);
    try std.testing.expectError(error.MutationAlreadyRunning, machine.apply(.{
        .action = .partial_attach,
        .vm_marker = true,
        .target_allowlisted = true,
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-demo-2",
    }));
}

test "daemon state machine rolls back a partial switch with matching id" {
    var machine = Lifecycle.init();
    try machine.apply(.{
        .action = .partial_attach,
        .vm_marker = true,
        .target_allowlisted = true,
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-demo",
    });
    try machine.apply(.{ .action = .rollback, .rollback_id = "RB-demo" });
    try std.testing.expectEqual(ControlState.rollback_pending, machine.state);
    try std.testing.expectError(error.MutationAlreadyRunning, machine.apply(.{ .action = .rollback, .rollback_id = "RB-demo" }));
    try machine.finishRollback("RB-demo");
    try std.testing.expectEqual(ControlState.rolled_back, machine.state);
}

test "daemon state machine rejects invalid rollback and stale scope" {
    var machine = Lifecycle.init();
    try std.testing.expectError(error.RollbackSnapshotRequired, machine.apply(.{ .action = .rollback }));
    try std.testing.expectError(error.InvalidTransition, machine.apply(.{ .action = .rollback, .rollback_id = "RB-demo" }));
    try std.testing.expectError(error.HostMutationRefused, machine.apply(.{ .action = .verifier_only }));

    machine = Lifecycle.init();
    try std.testing.expectError(error.StaleScope, machine.apply(.{
        .action = .partial_attach,
        .vm_marker = true,
        .target_allowlisted = true,
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
        .rollback_id = "RB-demo",
        .stale_scope = true,
    }));
    try std.testing.expectEqual(ControlState.incident, machine.state);
}
