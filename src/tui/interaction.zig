const std = @import("std");
const linux = @import("linux_scheduler");
const actions = @import("actions.zig");

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
    warm_theme: bool = false,
};

pub const ControlResult = union(enum) {
    action: protocol.OperatorAction,
    status: []const u8,
};

pub fn controlForKey(key: u8, state: *ControlState, _: bool) ?ControlResult {
    const binding = actions.bindingForKey(key) orelse return null;
    return switch (binding.kind) {
        .quit, .help, .home => .{ .status = actions.statusForUi(binding.kind).? },
        .theme => toggleTheme(state),
        .run_vm_lab => armVmLab(state),
        .rollback_lab => rollbackControl(state),
        .stop_lab => stopControl(state),
        else => if (actionForKey(key)) |action| .{ .action = action } else null,
    };
}

pub fn actionForKey(key: u8) ?protocol.OperatorAction {
    const kind = actions.actionKindForKey(key) orelse return null;
    return switch (kind) {
        .run_lab_host_safe => .{ .kind = .run_lab_host_safe, .run_id = "tui-test-run" },
        .verifier_only => .{ .kind = .verifier_only, .run_id = "tui-test-verifier" },
        .partial_attach => .{ .kind = .partial_attach, .run_id = "tui-test-partial" },
        .observe => .{ .kind = .observe, .run_id = "tui-test-observe" },
        .incident_drill => .{ .kind = .incident_drill, .run_id = "tui-incident" },
        else => null,
    };
}

fn toggleTheme(state: *ControlState) ControlResult {
    state.warm_theme = !state.warm_theme;
    return .{ .status = if (state.warm_theme) "THEME warm dark" else "THEME cool dark" };
}

fn armVmLab(state: *ControlState) ControlResult {
    if (hasRollbackTarget(state) and !state.rollback_sent and !state.stop_sent) {
        state.rollback_confirm_pending = false;
        state.stop_confirm_pending = false;
        return .{ .status = "live VM already armed rollback ready" };
    }
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

fn rollbackControl(state: *ControlState) ControlResult {
    if (!hasRollbackTarget(state)) return .{ .status = "rollback refused missing audit/rollback id" };
    if (!state.rollback_confirm_pending and !state.rollback_sent) {
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

fn stopControl(state: *ControlState) ControlResult {
    if (!hasRollbackTarget(state)) return .{ .status = "stop refused missing audit/rollback id" };
    if (!state.stop_confirm_pending and !state.stop_sent) {
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
        .run_lab_microvm_live => "ACTION queued run_lab_microvm_live rollback ready",
        .verifier_only => "ACTION queued verifier_only",
        .partial_attach => "ACTION queued partial_attach",
        .observe => "ACTION queued observe",
        .stop, .stop_lab_run => "ACTION queued stop target rollback id",
        .rollback, .rollback_lab_run => "ACTION queued rollback target rollback id",
        .incident_drill => "ACTION queued incident_drill",
    };
}

test "interactive TUI maps r to typed host-safe lab action" {
    const action = actionForKey('r') orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(protocol.ActionKind.run_lab_host_safe, action.kind);
    try std.testing.expectEqualStrings("ACTION queued run_lab_host_safe", statusForAction(action));
}

test "interactive TUI ignores unknown keys instead of executing commands" {
    var state = ControlState{};
    try std.testing.expect(actionForKey('!') == null);
    try std.testing.expect(controlForKey('!', &state, true) == null);
}

test "navigation and theme keys produce deterministic statuses" {
    var state = ControlState{};
    try std.testing.expectEqualStrings("HELP open help", controlForKey('?', &state, true).?.status);
    try std.testing.expectEqualStrings("HOME dashboard", controlForKey('h', &state, true).?.status);
    try std.testing.expectEqualStrings("THEME warm dark", controlForKey('w', &state, true).?.status);
    try std.testing.expectEqualStrings("THEME cool dark", controlForKey('w', &state, true).?.status);
}

test "duplicate live VM arm is refused without dispatching another action" {
    var state = ControlState{};
    const first = controlForKey('m', &state, true).?;
    try std.testing.expectEqual(protocol.ActionKind.run_lab_vm, first.action.kind);
    const second = controlForKey('m', &state, true).?;
    try std.testing.expectEqualStrings("live VM already armed rollback ready", second.status);
}

test "operator_key_registry_handles_every_advertised_interactive_key" {
    var state = ControlState{};
    var buffer: [actions.bindings.len]u8 = undefined;
    for (actions.advertisedKeys(&buffer)) |key| {
        try std.testing.expect(controlForKey(key, &state, true) != null);
    }
}

test "operator_key_registry_does_not_duplicate_active_keys" {
    var buffer: [actions.bindings.len]u8 = undefined;
    const advertised = actions.advertisedKeys(&buffer);
    var seen = [_]bool{false} ** 256;
    for (advertised) |key| {
        try std.testing.expect(!seen[key]);
        seen[key] = true;
    }
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

test "stop key refuses before lab ids and confirms before dispatch" {
    var state = ControlState{};
    const missing = controlForKey('s', &state, true).?;
    try std.testing.expectEqualStrings("stop refused missing audit/rollback id", missing.status);
    _ = controlForKey('m', &state, true).?;
    const confirm = controlForKey('s', &state, true).?;
    try std.testing.expectEqualStrings("CONFIRM stop press s again", confirm.status);
    const dispatch = controlForKey('s', &state, true).?;
    try std.testing.expectEqual(protocol.ActionKind.stop_lab_run, dispatch.action.kind);
    try std.testing.expectEqualStrings(tui_lab_action_id, dispatch.action.target_action_id);
    try std.testing.expectEqualStrings(tui_rollback_id, dispatch.action.rollback_id);
}

test "normal interactive mode also requires rollback and stop confirmation" {
    var rollback_state = ControlState{};
    _ = controlForKey('m', &rollback_state, false).?;
    const rollback_confirm = controlForKey('b', &rollback_state, false).?;
    try std.testing.expectEqualStrings("CONFIRM rollback press b again", rollback_confirm.status);
    const rollback_dispatch = controlForKey('b', &rollback_state, false).?;
    try std.testing.expectEqual(protocol.ActionKind.rollback_lab_run, rollback_dispatch.action.kind);

    var stop_state = ControlState{};
    _ = controlForKey('m', &stop_state, false).?;
    const stop_confirm = controlForKey('s', &stop_state, false).?;
    try std.testing.expectEqualStrings("CONFIRM stop press s again", stop_confirm.status);
    const stop_dispatch = controlForKey('s', &stop_state, false).?;
    try std.testing.expectEqual(protocol.ActionKind.stop_lab_run, stop_dispatch.action.kind);
}
