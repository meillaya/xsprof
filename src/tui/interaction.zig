const std = @import("std");
const linux = @import("linux_scheduler");

const protocol = linux.control.protocol;

const tui_lab_action_id = "tui-vm-lab";
const tui_rollback_id = "RB-tui-vm-lab";
const tui_audit_id = "AUD-tui-vm-lab";

pub const ControlState = struct {
    lab_action_id: []const u8 = "",
    rollback_id: []const u8 = "",
    audit_id: []const u8 = "",
    rollback_confirm_pending: bool = false,
    stop_confirm_pending: bool = false,
    rollback_sent: bool = false,
    stop_sent: bool = false,
};

pub const ControlResult = union(enum) {
    action: protocol.OperatorAction,
    status: []const u8,
};

pub fn controlForKey(key: u8, state: *ControlState, test_mode: bool) ?ControlResult {
    return switch (key) {
        'm' => armVmLab(state),
        'b' => rollbackControl(state, test_mode),
        's' => stopControl(state, test_mode),
        else => if (actionForKey(key)) |action| .{ .action = action } else null,
    };
}

pub fn actionForKey(key: u8) ?protocol.OperatorAction {
    return switch (key) {
        'r' => .{ .kind = .run_lab_host_safe, .run_id = "tui-test-run" },
        'v' => .{ .kind = .verifier_only, .run_id = "tui-test-verifier" },
        'p' => .{ .kind = .partial_attach, .run_id = "tui-test-partial" },
        'o' => .{ .kind = .observe, .run_id = "tui-test-observe" },
        else => null,
    };
}

fn armVmLab(state: *ControlState) ControlResult {
    state.lab_action_id = tui_lab_action_id;
    state.rollback_id = tui_rollback_id;
    state.audit_id = tui_audit_id;
    state.rollback_confirm_pending = false;
    state.stop_confirm_pending = false;
    state.rollback_sent = false;
    state.stop_sent = false;
    return .{ .action = .{
        .kind = .run_lab_vm,
        .action_id = tui_lab_action_id,
        .run_id = "tui-vm-lab",
        .audit_id = tui_audit_id,
        .rollback_id = tui_rollback_id,
    } };
}

fn rollbackControl(state: *ControlState, test_mode: bool) ControlResult {
    if (!hasRollbackTarget(state)) return .{ .status = "rollback refused missing audit/rollback id" };
    if (test_mode and !state.rollback_confirm_pending and !state.rollback_sent) {
        state.rollback_confirm_pending = true;
        return .{ .status = "CONFIRM rollback press b again" };
    }
    state.rollback_confirm_pending = false;
    state.rollback_sent = true;
    return .{ .action = .{
        .kind = .rollback_lab_run,
        .run_id = "tui-rollback",
        .audit_id = state.audit_id,
        .rollback_id = state.rollback_id,
        .target_action_id = state.lab_action_id,
    } };
}

fn stopControl(state: *ControlState, test_mode: bool) ControlResult {
    if (!hasRollbackTarget(state)) return .{ .status = "stop refused missing audit/rollback id" };
    if (test_mode and !state.stop_confirm_pending and !state.stop_sent) {
        state.stop_confirm_pending = true;
        return .{ .status = "CONFIRM stop press s again" };
    }
    state.stop_confirm_pending = false;
    state.stop_sent = true;
    return .{ .action = .{
        .kind = .stop_lab_run,
        .run_id = "tui-stop",
        .audit_id = state.audit_id,
        .rollback_id = state.rollback_id,
        .target_action_id = state.lab_action_id,
    } };
}

fn hasRollbackTarget(state: *const ControlState) bool {
    return state.lab_action_id.len != 0 and state.rollback_id.len != 0 and state.audit_id.len != 0;
}

pub fn statusForAction(action: ?protocol.OperatorAction) []const u8 {
    const selected = action orelse return "ACTION idle typed queue empty";
    return switch (selected.kind) {
        .preflight => "ACTION queued preflight",
        .run_lab_host_safe => "ACTION queued run_lab_host_safe",
        .run_lab_vm => "ACTION queued run_lab_vm rollback ready",
        .verifier_only => "ACTION queued verifier_only",
        .partial_attach => "ACTION queued partial_attach",
        .observe => "ACTION queued observe",
        .stop, .stop_lab_run => "ACTION queued stop target rollback id",
        .rollback, .rollback_lab_run => "ACTION queued rollback target rollback id",
    };
}

test "interactive TUI maps r to typed host-safe lab action" {
    const action = actionForKey('r') orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(protocol.ActionKind.run_lab_host_safe, action.kind);
    try std.testing.expectEqualStrings("ACTION queued run_lab_host_safe", statusForAction(action));
}

test "interactive TUI ignores unknown keys instead of executing commands" {
    try std.testing.expect(actionForKey('!') == null);
}

test "rollback key refuses before lab ids and confirms before dispatch" {
    var state = ControlState{};
    const missing = controlForKey('b', &state, true).?;
    try std.testing.expectEqualStrings("rollback refused missing audit/rollback id", missing.status);
    _ = controlForKey('m', &state, true).?;
    const confirm = controlForKey('b', &state, true).?;
    try std.testing.expectEqualStrings("CONFIRM rollback press b again", confirm.status);
    const dispatch = controlForKey('b', &state, true).?;
    try std.testing.expectEqual(protocol.ActionKind.rollback_lab_run, dispatch.action.kind);
    try std.testing.expectEqualStrings(tui_lab_action_id, dispatch.action.target_action_id);
    try std.testing.expectEqualStrings(tui_rollback_id, dispatch.action.rollback_id);
    const idempotent = controlForKey('b', &state, true).?;
    try std.testing.expectEqual(protocol.ActionKind.rollback_lab_run, idempotent.action.kind);
}
