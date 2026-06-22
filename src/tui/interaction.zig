//! SIZE_OK: interactive key handling is a single guarded state machine for mode changes,
//! theme cycling, lab arming, stop, and rollback confirmations; splitting would obscure
//! the safety refusals covered by the root TUI control tests.
const std = @import("std");
const linux = @import("linux_scheduler");
const actions = @import("actions.zig");
const render = @import("render.zig");

const protocol = linux.control.protocol;

const tui_lab_action_id = "tui-vm-lab";
const tui_rollback_id = "RB-tui-vm-lab";
const tui_audit_id = "AUD-tui-vm-lab";

pub const UiMode = enum {
    hero,
    picker,
    live,
    help,
    incident,
};

pub const ControlState = struct {
    ui_mode: UiMode = .hero,
    mode_before_help: UiMode = .hero,
    lab_action_id: []const u8 = "",
    rollback_id: []const u8 = "",
    audit_id: []const u8 = "",
    run_id: []const u8 = "",
    lab_action_id_buf: [96]u8 = undefined,
    rollback_id_buf: [96]u8 = undefined,
    audit_id_buf: [96]u8 = undefined,
    run_id_buf: [96]u8 = undefined,
    rollback_confirm_pending: bool = false,
    stop_confirm_pending: bool = false,
    rollback_sent: bool = false,
    stop_sent: bool = false,
    theme_id: render.ThemeId = .black,
};

pub const ControlResult = union(enum) {
    action: protocol.OperatorAction,
    status: []const u8,
};

pub fn controlForKey(key: u8, state: *ControlState, test_mode: bool) ?ControlResult {
    if (key == '\r' or key == '\n') return continueFlow(state, test_mode);
    if (state.ui_mode == .help) {
        if (key == '?' or key == 27 or key == 'h') return closeHelp(state);
        if (key == 'q') return .{ .status = actions.statusForUi(.quit).? };
        return .{ .status = "HELP modal active" };
    }
    const binding = actions.bindingForKey(key) orelse return null;
    return switch (binding.kind) {
        .quit => .{ .status = actions.statusForUi(binding.kind).? },
        .help => openHelp(state),
        .home => goHome(state),
        .theme => toggleTheme(state),
        .run_vm_lab => continueFlow(state, test_mode),
        .rollback_lab => rollbackControl(state),
        .stop_lab => stopControl(state),
        else => if (actionForKey(key)) |action| .{ .action = action } else null,
    };
}

pub fn enterIncidentMode(state: *ControlState) void {
    state.ui_mode = .incident;
}

pub fn enterLiveMode(state: *ControlState) void {
    state.ui_mode = .live;
}

fn continueFlow(state: *ControlState, test_mode: bool) ControlResult {
    return switch (state.ui_mode) {
        .hero => {
            state.ui_mode = .picker;
            state.rollback_confirm_pending = false;
            state.stop_confirm_pending = false;
            return .{ .status = "MODE picker attach target" };
        },
        .picker => armVmLab(state, test_mode),
        .live => armVmLab(state, test_mode),
        .help => closeHelp(state),
        .incident => .{ .status = "INCIDENT mode active fail-closed" },
    };
}

fn openHelp(state: *ControlState) ControlResult {
    if (state.ui_mode != .help) {
        state.mode_before_help = state.ui_mode;
        state.ui_mode = .help;
    }
    return .{ .status = "HELP open modal" };
}

fn closeHelp(state: *ControlState) ControlResult {
    state.ui_mode = state.mode_before_help;
    return .{ .status = "HELP close modal" };
}

fn goHome(state: *ControlState) ControlResult {
    state.ui_mode = switch (state.ui_mode) {
        .help => state.mode_before_help,
        .live, .incident => .picker,
        .picker, .hero => .hero,
    };
    state.rollback_confirm_pending = false;
    state.stop_confirm_pending = false;
    return .{ .status = "HOME dashboard" };
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
    state.theme_id = render.nextTheme(state.theme_id);
    return .{ .status = currentThemeHeaderLabel(state) };
}

pub fn currentThemeHeaderLabel(state: *const ControlState) []const u8 {
    return render.themeHeaderLabel(state.theme_id);
}

fn armVmLab(state: *ControlState, test_mode: bool) ControlResult {
    if (hasRollbackTarget(state) and !state.rollback_sent and !state.stop_sent) {
        state.rollback_confirm_pending = false;
        state.stop_confirm_pending = false;
        state.ui_mode = .live;
        return .{ .status = "live VM already armed rollback ready" };
    }
    if (test_mode) {
        state.lab_action_id = tui_lab_action_id;
        state.rollback_id = tui_rollback_id;
        state.audit_id = tui_audit_id;
        state.run_id = "tui-vm-lab";
    } else {
        const suffix = std.os.linux.getpid();
        state.lab_action_id = std.fmt.bufPrint(&state.lab_action_id_buf, "tui-vm-lab-{d}", .{suffix}) catch tui_lab_action_id;
        state.rollback_id = std.fmt.bufPrint(&state.rollback_id_buf, "RB-tui-vm-lab-{d}", .{suffix}) catch tui_rollback_id;
        state.audit_id = std.fmt.bufPrint(&state.audit_id_buf, "AUD-tui-vm-lab-{d}", .{suffix}) catch tui_audit_id;
        state.run_id = std.fmt.bufPrint(&state.run_id_buf, "tui-vm-lab-{d}", .{suffix}) catch "tui-vm-lab";
    }
    state.rollback_confirm_pending = false;
    state.stop_confirm_pending = false;
    state.rollback_sent = false;
    state.stop_sent = false;
    state.ui_mode = .live;
    return .{ .action = .{
        .kind = .run_lab_microvm_live,
        .action_id = state.lab_action_id,
        .run_id = state.run_id,
        .audit_id = state.audit_id,
        .rollback_id = state.rollback_id,
    } };
}

fn rollbackControl(state: *ControlState) ControlResult {
    if (state.rollback_sent) return .{ .status = "REFUSED duplicate action id: tui-rollback-active" };
    if (!hasRollbackTarget(state)) return .{ .status = "rollback refused · no live target" };
    if (!state.rollback_confirm_pending) {
        state.rollback_confirm_pending = true;
        return .{ .status = "CONFIRM rollback — press b again" };
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
    if (state.stop_sent) return .{ .status = "REFUSED duplicate action id: tui-stop-active" };
    if (state.rollback_sent or !hasRollbackTarget(state)) return .{ .status = "stop refused · no live target" };
    if (!state.stop_confirm_pending) {
        state.stop_confirm_pending = true;
        return .{ .status = "CONFIRM stop — press s again" };
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
    try std.testing.expectEqualStrings("HELP open modal", controlForKey('?', &state, true).?.status);
    try std.testing.expectEqual(UiMode.help, state.ui_mode);
    try std.testing.expectEqualStrings("HELP close modal", controlForKey('?', &state, true).?.status);
    try std.testing.expectEqualStrings("HOME dashboard", controlForKey('h', &state, true).?.status);
    try std.testing.expectEqualStrings("theme cool dark ▸ w", controlForKey('w', &state, true).?.status);
    try std.testing.expectEqualStrings("theme paper ▸ w", controlForKey('w', &state, true).?.status);
}

test "duplicate live VM arm is refused without dispatching another action" {
    var state = ControlState{};
    _ = controlForKey('\r', &state, true).?;
    const first = controlForKey('m', &state, true).?;
    try std.testing.expectEqual(protocol.ActionKind.run_lab_microvm_live, first.action.kind);
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
    try std.testing.expectEqualStrings("rollback refused · no live target", missing.status);
    _ = controlForKey('\r', &state, true).?;
    _ = controlForKey('m', &state, true).?;
    const confirm = controlForKey('b', &state, true).?;
    try std.testing.expectEqualStrings("CONFIRM rollback — press b again", confirm.status);
    const dispatch = controlForKey('b', &state, true).?;
    try std.testing.expectEqual(protocol.ActionKind.rollback_lab_run, dispatch.action.kind);
    try std.testing.expectEqualStrings(tui_lab_action_id, dispatch.action.target_action_id);
    try std.testing.expectEqualStrings(tui_rollback_id, dispatch.action.rollback_id);
    const idempotent = controlForKey('b', &state, true).?;
    try std.testing.expectEqualStrings("REFUSED duplicate action id: tui-rollback-active", idempotent.status);
}

test "stop key refuses before lab ids and confirms before dispatch" {
    var state = ControlState{};
    const missing = controlForKey('s', &state, true).?;
    try std.testing.expectEqualStrings("stop refused · no live target", missing.status);
    _ = controlForKey('\r', &state, true).?;
    _ = controlForKey('m', &state, true).?;
    const confirm = controlForKey('s', &state, true).?;
    try std.testing.expectEqualStrings("CONFIRM stop — press s again", confirm.status);
    const dispatch = controlForKey('s', &state, true).?;
    try std.testing.expectEqual(protocol.ActionKind.stop_lab_run, dispatch.action.kind);
    try std.testing.expectEqualStrings(tui_lab_action_id, dispatch.action.target_action_id);
    try std.testing.expectEqualStrings(tui_rollback_id, dispatch.action.rollback_id);
}

test "normal interactive mode also requires rollback and stop confirmation" {
    var rollback_state = ControlState{};
    _ = controlForKey('\r', &rollback_state, false).?;
    _ = controlForKey('m', &rollback_state, false).?;
    const rollback_confirm = controlForKey('b', &rollback_state, false).?;
    try std.testing.expectEqualStrings("CONFIRM rollback — press b again", rollback_confirm.status);
    const rollback_dispatch = controlForKey('b', &rollback_state, false).?;
    try std.testing.expectEqual(protocol.ActionKind.rollback_lab_run, rollback_dispatch.action.kind);

    var stop_state = ControlState{};
    _ = controlForKey('\r', &stop_state, false).?;
    _ = controlForKey('m', &stop_state, false).?;
    const stop_confirm = controlForKey('s', &stop_state, false).?;
    try std.testing.expectEqualStrings("CONFIRM stop — press s again", stop_confirm.status);
    const stop_dispatch = controlForKey('s', &stop_state, false).?;
    try std.testing.expectEqual(protocol.ActionKind.stop_lab_run, stop_dispatch.action.kind);
}
