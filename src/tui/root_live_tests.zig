//! SIZE_OK: this is the authoritative live-VM TUI contract test suite; scenarios stay in
//! one file to share transcript helpers and preserve reviewable ordering from hero/picker
//! through dashboard, incident, theme, CJK width, and control-key behavior.
const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");

const OperatorAction = root.OperatorAction;
const countRows = layout.countRows;

fn strippedAnsi(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '[') {
            index += 2;
            while (index < text.len) : (index += 1) {
                const byte = text[index];
                if (byte >= 0x40 and byte <= 0x7e) {
                    index += 1;
                    break;
                }
            }
            continue;
        }
        try out.append(allocator, text[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;
    const plain = try strippedAnsi(std.testing.allocator, haystack);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    const plain = try strippedAnsi(std.testing.allocator, haystack);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, needle) == null);
}

test "vm-live operator model renders failed stale and rollback-done states safely" {
    const cases = [_]struct {
        fixture_path: []const u8,
        expected: []const []const u8,
    }{
        .{
            .fixture_path = "fixtures/lab/run-all-vm-live-failed-boot.json",
            .expected = &.{ "microvm_boot", "unsafe_to_assume", "failed-boot", "cleanup receipt PASS", "closed" },
        },
        .{
            .fixture_path = "fixtures/lab/run-all-vm-live-stale-bundle.json",
            .expected = &.{ "validation", "unsafe_to_assume", "stale", "closed_stale_bundle", "cleanup receipt PASS but" },
        },
        .{
            .fixture_path = "fixtures/lab/run-all-vm-live-rollback-done.json",
            .expected = &.{ "rollback_done", "none after rollback", "RB-rollback-done", "cleanup receipt PASS" },
        },
    };
    for (cases) |case| {
        const frame = try root.renderSnapshot(std.testing.allocator, .{
            .snapshot = true,
            .screen = .sched_ext,
            .width = 120,
            .height = 30,
            .fixture_path = case.fixture_path,
        });
        defer std.testing.allocator.free(frame);
        try std.testing.expectEqual(@as(usize, 30), countRows(frame));
        try std.testing.expect(layout.maxLineCells(frame) <= 120);
        try expectContains(frame, "lab-only vm guest");
        try expectContains(frame, "bundle path");
        try expectContains(frame, "cleanup status");
        for (case.expected) |label| try expectContains(frame, label);
        try expectNotContains(frame, "production");
        try expectNotContains(frame, "Task Metrics");
        try expectNotContains(frame, "policy [FCFS]");
    }
}

test "vm-live lifecycle fields survive narrow supported width" {
    const frame = try root.renderSnapshot(std.testing.allocator, .{
        .snapshot = true,
        .screen = .sched_ext,
        .width = 80,
        .height = 30,
        .fixture_path = "fixtures/lab/run-all-vm-live-summary.json",
    });
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(@as(usize, 30), countRows(frame));
    try std.testing.expect(layout.maxLineCells(frame) <= 80);
    for ([_][]const u8{
        "vm-live",
        "zigsched_minimal",
        "runtime samples",
        "rollback ready/completed",
        "release eligible",
    }) |label| {
        try std.testing.expect(std.mem.indexOf(u8, frame, label) != null);
    }
}

test "vm-lab screen renders lifecycle lanes counters and rollback ledger" {
    const frame = try root.renderSnapshot(std.testing.allocator, .{
        .snapshot = true,
        .screen = .vm_lab,
        .width = 165,
        .height = 48,
        .fixture_path = "fixtures/lab/run-all-vm-live-summary.json",
    });
    defer std.testing.allocator.free(frame);

    try std.testing.expectEqual(@as(usize, 48), countRows(frame));
    try std.testing.expect(layout.maxLineCells(frame) <= 165);
    for ([_][]const u8{
        "lifecycle lanes",
        "preflight build boot",
        "marker verifier attach",
        "observe rollback audit cleanup",
        "runtime counters",
        "zigsched_minimal",
        "runtime samples x3",
        "rollback ready/completed",
        "lab-only vm guest",
        "cleanup receipt PASS",
        "AUD-vmlive-ui",
        "microvm-live-tui-demo",
    }) |label| try expectContains(frame, label);
    try expectNotContains(frame, "Task Metrics");
    try expectNotContains(frame, "completion_order");
    try expectNotContains(frame, "policy [FCFS]");
}

test "interactive live daemon output renders transcript-visible VM state" {
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_started\",\"action\":\"run_lab_microvm_live\",\"state\":\"vm_only_pending\",\"status\":\"queued\",\"reason\":\"microvm_live_runner_start\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-test\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"microvm_boot\",\"action\":\"run_lab_microvm_live\",\"state\":\"vm_live\",\"status\":\"PASS\",\"reason\":\"vm marker present\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-test/summary.json\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"bpf_register\",\"action\":\"run_lab_microvm_live\",\"state\":\"zigsched_minimal\",\"status\":\"PASS\",\"reason\":\"runtime ops observed\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-test/partial-attach/partial-attach-evidence.json\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"runtime_sample\",\"action\":\"run_lab_microvm_live\",\"state\":\"observing\",\"status\":\"PASS\",\"reason\":\"runtime samples accepted\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-test/observe-partial/runtime-samples.jsonl\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"rollback\",\"action\":\"run_lab_microvm_live\",\"state\":\"rolled_back\",\"status\":\"PASS\",\"reason\":\"PASS\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-test/rollback-drill/audit-ledger.jsonl\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"cleanup\",\"action\":\"run_lab_microvm_live\",\"state\":\"clean\",\"status\":\"PASS\",\"reason\":\"process scan clean\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-test/summary.json\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"validation\",\"action\":\"run_lab_microvm_live\",\"state\":\"vm_live_validated\",\"status\":\"PASS\",\"reason\":\"live bundle freshness accepted\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-test/summary.json\",\"host_mutation\":false}\n";
    const frame = try root.renderInteractiveDaemonOutput(std.testing.allocator, .{
        .interactive = true,
        .screen = .vm_lab,
        .width = 165,
        .height = 30,
    }, raw, "daemon completed read-only action");
    defer std.testing.allocator.free(frame);
    for ([_][]const u8{
        "tui-vm-lab-test",
        "runtime_sample",
        "accepted",
        "ops recorded",
        "zigsched_minimal",
        "rollback ready/completed",
        "cleanup receipt PASS",
        "live bundle freshness",
        "lab-only vm guest",
        "not release eligible",
    }) |label| try expectContains(frame, label);
    try expectNotContains(frame, "production");
    try expectNotContains(frame, "host mutation");
}

test "live VM interactive mode starts on hero before attach target picker" {
    const control_state = root.interaction.ControlState{};
    try std.testing.expectEqual(root.interaction.UiMode.hero, control_state.ui_mode);

    const frame = try root.renderInteractiveMode(std.testing.allocator, .{
        .interactive = true,
        .screen = .vm_lab,
        .width = 120,
        .height = 30,
    }, control_state.ui_mode, "");
    defer std.testing.allocator.free(frame);

    try expectContains(frame, "live microVM lab");
    try expectContains(frame, "fail-closed Linux scheduler operator");
    try expectContains(frame, "enter ▸ launch live run");
    try expectContains(frame, "$ zig build tui-live-vm");
    try expectNotContains(frame, "ATTACH TARGET");
}

test "live VM hero matches authoritative landing density before picker" {
    const frame = try root.renderInteractiveMode(std.testing.allocator, .{
        .interactive = true,
        .screen = .vm_lab,
        .width = 197,
        .height = 62,
    }, .hero, "");
    defer std.testing.allocator.free(frame);

    for ([_][]const u8{
        "local daemon · read-only · disposable VM lab",
        "v1 · sched_ext readiness",
        "live microVM lab",
        "fail-closed Linux scheduler operator",
        "Boots a disposable microVM and registers a zigsched_minimal sched_ext scheduler inside the guest.",
        "Per-vCPU sched_switch lanes, utilization, runqueue-latency histogram — observed, descriptive, no perf claim.",
        "Every lifecycle step arrives as a zig-scheduler/daemon-event/v1 record, filterable in real time.",
        "host_mutation=false on every event. load · attach · enable · mutate · apply are refused on the host.",
        "$ zig build tui-live-vm",
        "target · 6.12.0-sched-ext-lab · x86_64",
        "enter ▸ launch live run",
        "press ⏎ or m to continue | ? key map · w theme | FAIL-CLOSED",
    }) |label| try expectContains(frame, label);

    try expectNotContains(frame, "ATTACH TARGET");
    try expectNotContains(frame, "Task Metrics");
    try expectNotContains(frame, "policy [FCFS]");
}

test "live VM picker follows continue with authoritative target and preflight density" {
    const frame = try root.renderInteractiveMode(std.testing.allocator, .{
        .interactive = true,
        .screen = .vm_lab,
        .width = 197,
        .height = 62,
    }, .picker, "MODE picker attach target");
    defer std.testing.allocator.free(frame);

    for ([_][]const u8{
        "ATTACH TARGET",
        "disposable microVM · VM-only path",
        "The host stays fail-closed. load · attach · enable · mutate · apply are refused on the host.",
        "PICK A TUPLE",
        "↵ / m to arm",
        "6.12.0-sched-ext-lab · x86_64",
        "disposable microVM · BTF present · approved tuple",
        "READY",
        "6.11.0-rc6-zigsched · x86_64",
        "6.12.0-sched-ext-lab · aarch64",
        "no kvm on host → fail-closed SKIP",
        "SKIP",
        "m ▸ request live microVM run",
        "arms rollback + audit ids before any attach",
        "PREFLIGHT",
        "read-only host facts",
        "sched_ext",
        "host fail-closed",
        "no BPF load on host",
        "cgroup v2",
        "no cgroup writes",
        "capabilities",
        "refuse unsafe verbs",
        "BTF",
        "lab gate required",
        "FAIL-CLOSED OUTCOMES",
        "every refusal keeps host_mutation=false",
    }) |label| try expectContains(frame, label);
}

test "live VM continue flow moves hero to picker then arming moves live" {
    var control_state = root.interaction.ControlState{};

    const first_continue = root.interaction.controlForKey('\r', &control_state, true).?;
    try std.testing.expectEqual(root.interaction.UiMode.picker, control_state.ui_mode);
    try std.testing.expectEqualStrings("MODE picker attach target", first_continue.status);

    const picker_frame = try root.renderInteractiveMode(std.testing.allocator, .{
        .interactive = true,
        .screen = .vm_lab,
        .width = 120,
        .height = 30,
    }, control_state.ui_mode, first_continue.status);
    defer std.testing.allocator.free(picker_frame);
    try expectContains(picker_frame, "ATTACH TARGET");
    try expectContains(picker_frame, "m ▸ request live microVM run");

    const arm = root.interaction.controlForKey('m', &control_state, true).?;
    try std.testing.expectEqual(root.interaction.UiMode.live, control_state.ui_mode);
    try std.testing.expectEqual(OperatorAction{
        .kind = .run_lab_microvm_live,
        .action_id = "tui-vm-lab",
        .run_id = "tui-vm-lab",
        .audit_id = "AUD-tui-vm-lab",
        .rollback_id = "RB-tui-vm-lab",
    }, arm.action);

    var store = root.live_store.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.appendControlStatus(.queued, "[queued] VM run queued", arm.action.action_id);
    const live_frame = try root.renderInteractiveLiveStoreMode(std.testing.allocator, .{
        .interactive = true,
        .screen = .vm_lab,
        .width = 120,
        .height = 30,
    }, control_state.ui_mode, &store, "RUNNING live VM queued");
    defer std.testing.allocator.free(live_frame);
    try expectContains(live_frame, "VCPU RUNTIME");
    try expectContains(live_frame, "[queued] VM run queued");
}

test "live VM dashboard exposes authoritative three-column panes and event affordances" {
    var store = root.live_store.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"stage_started\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"tui-vm-lab\",\"status\":\"queued\",\"reason\":\"microvm_live_runner_start\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab\",\"host_mutation\":false}", .test_fixture);
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"runtime_sample\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"tui-vm-lab\",\"state\":\"observing\",\"status\":\"PASS\",\"reason\":\"runtime samples accepted\",\"sample_sequence\":1,\"host_mutation\":false}", .test_fixture);

    const frame = try root.renderInteractiveLiveStoreMode(std.testing.allocator, .{
        .interactive = true,
        .screen = .vm_lab,
        .width = 197,
        .height = 62,
    }, .live, &store, "RUNNING live VM observing");
    defer std.testing.allocator.free(frame);
    const plain = try strippedAnsi(std.testing.allocator, frame);
    defer std.testing.allocator.free(plain);

    try std.testing.expectEqual(@as(usize, 62), countRows(plain));
    try std.testing.expect(layout.maxLineCells(plain) <= 197);
    for ([_][]const u8{
        "LIFECYCLE",
        "GATE LEDGER",
        "ALERT STRIP",
        "VCPU RUNTIME",
        "PER-VCPU UTILIZATION",
        "RUNQUEUE LATENCY",
        "RUNTIME COUNTERS",
        "DAEMON EVENT STREAM",
        "all lifecycle runtime_sample rollback incident",
        "cursor",
        "scroll j/k",
        "observed — no perf claim",
    }) |label| try expectContains(plain, label);
    try expectNotContains(plain, "Task Metrics");
    try expectNotContains(plain, "Gantt");
    try expectNotContains(plain, "policy [FCFS]");
}

test "live VM help overlay is modal and preserves live store contents" {
    var control_state = root.interaction.ControlState{};
    _ = root.interaction.controlForKey('\r', &control_state, true).?;
    _ = root.interaction.controlForKey('m', &control_state, true).?;
    try std.testing.expectEqual(root.interaction.UiMode.live, control_state.ui_mode);

    var store = root.live_store.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"stage_started\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"tui-vm-lab\",\"status\":\"queued\",\"reason\":\"microvm_live_runner_start\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab\",\"host_mutation\":false}", .test_fixture);
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"runtime_sample\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"tui-vm-lab\",\"state\":\"observing\",\"status\":\"PASS\",\"reason\":\"runtime samples accepted\",\"sample_sequence\":1,\"host_mutation\":false}", .test_fixture);
    const events_before_help = store.events.items.len;

    const open_help = root.interaction.controlForKey('?', &control_state, true).?;
    try std.testing.expectEqual(root.interaction.UiMode.help, control_state.ui_mode);
    try std.testing.expectEqualStrings("HELP open modal", open_help.status);

    const help_frame = try root.renderInteractiveLiveStoreMode(std.testing.allocator, .{
        .interactive = true,
        .screen = .vm_lab,
        .width = 120,
        .height = 30,
    }, control_state.ui_mode, &store, open_help.status);
    defer std.testing.allocator.free(help_frame);
    try expectContains(help_frame, "HELP OVERLAY");
    try expectContains(help_frame, "runtime samples accepted");
    try std.testing.expectEqual(events_before_help, store.events.items.len);

    const close_help = root.interaction.controlForKey('?', &control_state, true).?;
    try std.testing.expectEqual(root.interaction.UiMode.live, control_state.ui_mode);
    try std.testing.expectEqualStrings("HELP close modal", close_help.status);
    try std.testing.expectEqual(events_before_help, store.events.items.len);
}

test "live VM incident mode can be represented without host mutation" {
    var control_state = root.interaction.ControlState{};
    root.interaction.enterIncidentMode(&control_state);
    try std.testing.expectEqual(root.interaction.UiMode.incident, control_state.ui_mode);

    var store = root.live_store.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.appendControlStatus(.incident, "INCIDENT qemu_unavailable", "tui-vm-lab");
    const frame = try root.renderInteractiveLiveStoreMode(std.testing.allocator, .{
        .interactive = true,
        .screen = .vm_lab,
        .width = 120,
        .height = 30,
    }, control_state.ui_mode, &store, "INCIDENT qemu_unavailable");
    defer std.testing.allocator.free(frame);

    try expectContains(frame, "INCIDENT qemu_unavailable");
    try expectContains(frame, "host_mutation=false");
    try expectNotContains(frame, "host mutation");
}

test "live VM incident labels render in status alert event stream and transcript" {
    const labels = [_][]const u8{
        "INCIDENT qemu_unavailable",
        "INCIDENT verifier_reject",
        "INCIDENT lost_stream",
        "INCIDENT malformed_line",
        "INCIDENT timeout",
        "INCIDENT rollback_failure",
        "INCIDENT cleanup_residue",
        "REFUSED duplicate action id: dup",
        "REFUSED stale action id: rb-old",
    };

    for (labels) |label| {
        var store = root.live_store.Store.init(std.testing.allocator);
        defer store.deinit();
        try store.appendControlStatus(.incident, label, "tui-vm-lab");
        const frame = try root.renderInteractiveLiveStoreMode(std.testing.allocator, .{
            .interactive = true,
            .screen = .vm_lab,
            .width = 197,
            .height = 62,
        }, .incident, &store, label);
        defer std.testing.allocator.free(frame);

        try expectContains(frame, label);
        try expectContains(frame, "ALERT STRIP");
        try expectContains(frame, "• incident");
        try expectContains(frame, "latest ·");
        try expectContains(frame, "current incident:");
        try expectContains(frame, "host_mutation=false");
        try expectNotContains(frame, "unsafe_to_assume only");
    }
}

test "authoritative live VM theme cycle labels wrap and old warm stub is gone" {
    var control_state = root.interaction.ControlState{};
    const expected = [_][]const u8{
        "theme black ▸ w",
        "theme cool dark ▸ w",
        "theme paper ▸ w",
        "theme catppuccin mocha ▸ w",
        "theme catppuccin latte ▸ w",
        "theme black ▸ w",
    };

    try std.testing.expectEqualStrings(expected[0], root.interaction.currentThemeHeaderLabel(&control_state));
    for (expected[1..]) |label| {
        const result = root.interaction.controlForKey('w', &control_state, true).?;
        try std.testing.expectEqualStrings(label, result.status);
        try std.testing.expectEqualStrings(label, root.interaction.currentThemeHeaderLabel(&control_state));
    }
    try std.testing.expect(std.mem.indexOf(u8, root.interaction.currentThemeHeaderLabel(&control_state), "warm") == null);
}

test "authoritative theme label renders on every live VM mode header" {
    var control_state = root.interaction.ControlState{};
    _ = root.interaction.controlForKey('w', &control_state, true).?;
    _ = root.interaction.controlForKey('w', &control_state, true).?;
    try std.testing.expectEqualStrings("theme paper ▸ w", root.interaction.currentThemeHeaderLabel(&control_state));

    var store = root.live_store.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.appendControlStatus(.queued, "[queued] VM run queued", "tui-vm-lab");
    try store.appendControlStatus(.incident, "INCIDENT qemu_unavailable", "tui-vm-lab");

    for ([_]root.interaction.UiMode{ .hero, .picker, .live, .help, .incident }) |mode| {
        const frame = try root.renderInteractiveLiveStoreModeWithTheme(std.testing.allocator, .{
            .interactive = true,
            .screen = .vm_lab,
            .width = 120,
            .height = 30,
        }, mode, &store, if (mode == .incident) "INCIDENT qemu_unavailable" else "", control_state.theme_id);
        defer std.testing.allocator.free(frame);
        try expectContains(frame, "theme paper ▸ w");
    }
}

test "CJK lifecycle fixture stays within requested terminal widths" {
    for ([_]u16{ 80, 100, 120 }) |width| {
        const frame = try root.renderSnapshot(std.testing.allocator, .{
            .snapshot = true,
            .screen = .sched_ext,
            .width = width,
            .height = 30,
            .fixture_path = "fixtures/lab/run-all-summary-cjk.json",
        });
        defer std.testing.allocator.free(frame);
        try std.testing.expectEqual(@as(usize, 30), countRows(frame));
        try std.testing.expect(layout.maxLineCells(frame) <= width);
        try std.testing.expect(std.unicode.utf8ValidateSlice(frame));
    }
}
test "interactive TUI control state maps rollback key with confirmation" {
    var control_state = root.interaction.ControlState{};
    const missing = root.interaction.controlForKey('b', &control_state, true).?;
    try std.testing.expectEqualStrings("rollback refused · no live target", missing.status);
    _ = root.interaction.controlForKey('\r', &control_state, true).?;
    const arm = root.interaction.controlForKey('m', &control_state, true).?;
    try std.testing.expectEqual(OperatorAction{
        .kind = .run_lab_microvm_live,
        .action_id = "tui-vm-lab",
        .run_id = "tui-vm-lab",
        .audit_id = "AUD-tui-vm-lab",
        .rollback_id = "RB-tui-vm-lab",
    }, arm.action);
    const confirm = root.interaction.controlForKey('b', &control_state, true).?;
    try std.testing.expectEqualStrings("CONFIRM rollback — press b again", confirm.status);
    const rollback = root.interaction.controlForKey('b', &control_state, true).?;
    try std.testing.expectEqualStrings("tui-vm-lab", rollback.action.target_action_id);
    try std.testing.expectEqualStrings("RB-tui-vm-lab", rollback.action.rollback_id);
}

test "interactive TUI action module tests are linked" {
    std.testing.refAllDecls(root.actions);
    std.testing.refAllDecls(root.interaction);
    std.testing.refAllDecls(root.daemon_adapter);
    std.testing.refAllDecls(@import("render.zig"));
}
