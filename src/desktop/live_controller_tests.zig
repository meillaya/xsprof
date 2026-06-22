const std = @import("std");
const live_controller = @import("live_controller.zig");

const Controller = live_controller.Controller;
const DispatchStatus = live_controller.DispatchStatus;
const buildDaemonArgv = live_controller.buildDaemonArgv;
const isValidDaemonPath = live_controller.isValidDaemonPath;

test "desktop controller accepts run event and owns rollback id" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    controller.active_action_id = try std.testing.allocator.dupe(u8, "desktop-run-1");
    controller.rollback_id = try std.testing.allocator.dupe(u8, "RB-desktop-run-1");
    controller.audit_id = try std.testing.allocator.dupe(u8, "AUD-desktop-1");
    controller.daemon_alive = true;
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"runtime_sample","action_id":"desktop-run-1","status":"PASS","host_mutation":false}
    );
    try std.testing.expectEqual(@as(usize, 1), controller.history.items.len);
    try std.testing.expectEqualStrings("RB-desktop-run-1", controller.rollback_id);
}

test "desktop controller quarantines mismatched daemon action id before validation" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    controller.active_action_id = try std.testing.allocator.dupe(u8, "desktop-run-1");
    controller.rollback_id = try std.testing.allocator.dupe(u8, "RB-desktop-run-1");
    controller.audit_id = try std.testing.allocator.dupe(u8, "AUD-desktop-1");
    controller.daemon_alive = true;
    controller.expected_event_action_id = "desktop-run-1";
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"validation","action_id":"tui-vm-lab","status":"PASS","host_mutation":false}
    );
    try std.testing.expectEqual(@as(usize, 1), controller.history.items.len);
    try std.testing.expectEqualStrings("incident", controller.history.items[0].event);
    try std.testing.expectEqualStrings("stale_or_unknown_target_action_id", controller.history.items[0].reason);
    try std.testing.expect(!controller.daemon_alive);
}

test "desktop controller quarantines mismatched target action id before cleanup" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    controller.active_action_id = try std.testing.allocator.dupe(u8, "desktop-run-1");
    controller.rollback_id = try std.testing.allocator.dupe(u8, "RB-desktop-run-1");
    controller.audit_id = try std.testing.allocator.dupe(u8, "AUD-desktop-1");
    controller.daemon_alive = true;
    controller.expected_event_action_id = "desktop-run-1";
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"cleanup","action_id":"desktop-run-1","target_action_id":"tui-vm-lab","status":"PASS","host_mutation":false}
    );
    try std.testing.expectEqual(@as(usize, 1), controller.history.items.len);
    try std.testing.expectEqualStrings("incident", controller.history.items[0].event);
    try std.testing.expectEqualStrings("stale_or_unknown_target_action_id", controller.history.items[0].reason);
    try std.testing.expect(!controller.daemon_alive);
}

test "desktop controller marks malformed stream inactive for future run" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    controller.active_action_id = try std.testing.allocator.dupe(u8, "desktop-run-1");
    controller.rollback_id = try std.testing.allocator.dupe(u8, "RB-desktop-run-1");
    controller.daemon_alive = true;
    try controller.appendLine("not-json");
    try std.testing.expectEqualStrings("incident", controller.history.items[0].event);
    try std.testing.expectEqualStrings("lost_stream_non_json", controller.history.items[0].reason);
    try std.testing.expect(!controller.daemon_alive);
}

test "desktop controller refuses duplicate run while active" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    controller.active_action_id = try std.testing.allocator.dupe(u8, "desktop-run-1");
    controller.rollback_id = try std.testing.allocator.dupe(u8, "RB-desktop-run-1");
    controller.daemon_alive = true;
    const status = try controller.run(std.Io.Threaded.global_single_threaded.io());
    try std.testing.expectEqual(DispatchStatus.refused, status);
    try std.testing.expectEqualStrings("duplicate_action_id", controller.history.items[0].reason);
}

test "desktop controller refuses rollback without target" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    const status = try controller.rollback(std.Io.Threaded.global_single_threaded.io(), "missing");
    try std.testing.expectEqual(DispatchStatus.refused, status);
    try std.testing.expectEqualStrings("stale_or_unknown_target_action_id", controller.history.items[0].reason);
}

test "desktop controller refuses stale rollback target" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    controller.active_action_id = try std.testing.allocator.dupe(u8, "desktop-run-1");
    controller.rollback_id = try std.testing.allocator.dupe(u8, "RB-desktop-run-1");
    controller.audit_id = try std.testing.allocator.dupe(u8, "AUD-desktop-1");
    const status = try controller.rollback(std.Io.Threaded.global_single_threaded.io(), "desktop-run-stale");
    try std.testing.expectEqual(DispatchStatus.refused, status);
    try std.testing.expectEqualStrings("stale_or_unknown_target_action_id", controller.history.items[0].reason);
}

test "desktop controller converts non-json stream to incident" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    try controller.appendLine("{not-json");
    try std.testing.expectEqualStrings("incident", controller.history.items[0].event);
    try std.testing.expectEqualStrings("lost_stream_non_json", controller.history.items[0].reason);
}

test "desktop controller converts host_mutation true to incident" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"runtime_sample","action_id":"desktop-run-1","status":"PASS","host_mutation":true}
    );
    try std.testing.expectEqualStrings("incident", controller.history.items[0].event);
    try std.testing.expectEqualStrings("host_mutation_not_false", controller.history.items[0].reason);
    try std.testing.expect(std.mem.indexOf(u8, controller.history.items[0].line, "\"host_mutation\":false") != null);
}

test "desktop controller keeps incident latched after later validation pass" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    controller.active_action_id = try std.testing.allocator.dupe(u8, "desktop-run-1");
    try controller.appendLine("not-json");
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"validation","action_id":"desktop-run-1","status":"PASS","host_mutation":false}
    );
    try std.testing.expectEqual(DispatchStatus.incident, controller.dispatch_status_latch.?);
    try std.testing.expectEqualStrings("incident", controller.history.items[0].event);
    try std.testing.expectEqualStrings("validation", controller.history.items[1].event);
}

test "desktop controller keeps schema violation latched after later validation pass" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v0","event":"runtime_sample","action_id":"desktop-run-1","status":"PASS","host_mutation":false}
    );
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"validation","action_id":"desktop-run-1","status":"PASS","host_mutation":false}
    );
    try std.testing.expectEqual(DispatchStatus.incident, controller.dispatch_status_latch.?);
    try std.testing.expectEqualStrings("schema_violation", controller.history.items[0].reason);
    try std.testing.expectEqualStrings("validation", controller.history.items[1].event);
}

test "desktop controller keeps host mutation latched after later validation pass" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"runtime_sample","action_id":"desktop-run-1","status":"PASS","host_mutation":true}
    );
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"validation","action_id":"desktop-run-1","status":"PASS","host_mutation":false}
    );
    try std.testing.expectEqual(DispatchStatus.incident, controller.dispatch_status_latch.?);
    try std.testing.expectEqualStrings("host_mutation_not_false", controller.history.items[0].reason);
    try std.testing.expectEqualStrings("validation", controller.history.items[1].event);
}

test "desktop controller keeps daemon incident event latched after later validation pass" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"incident","action_id":"desktop-run-1","status":"incident","reason":"lost_stream_non_json","host_mutation":false}
    );
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"validation","action_id":"desktop-run-1","status":"PASS","host_mutation":false}
    );
    try std.testing.expectEqual(DispatchStatus.incident, controller.dispatch_status_latch.?);
    try std.testing.expectEqualStrings("incident", controller.history.items[0].event);
    try std.testing.expectEqualStrings("validation", controller.history.items[1].event);
}

test "desktop controller keeps refusal latched after later validation pass" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"refusal","action_id":"desktop-run-1","status":"refused","reason":"stale_or_unknown_target_action_id","host_mutation":false}
    );
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"validation","action_id":"desktop-run-1","status":"PASS","host_mutation":false}
    );
    try std.testing.expectEqual(DispatchStatus.refused, controller.dispatch_status_latch.?);
    try std.testing.expectEqualStrings("refusal", controller.history.items[0].event);
    try std.testing.expectEqualStrings("validation", controller.history.items[1].event);
}

test "desktop controller rejects broad tmp live controller daemon paths" {
    try std.testing.expect(!isValidDaemonPath("/tmp/zig-scheduler-live-controller-test.daemon.py"));
    try std.testing.expect(!isValidDaemonPath("/tmp/zig-scheduler-live-controller-test.12345"));
    try std.testing.expect(isValidDaemonPath("tools/tui_pty_authoritative_daemon.py"));
    try std.testing.expect(isValidDaemonPath("tools/tui_pty_malformed_redaction.py"));
    try std.testing.expect(isValidDaemonPath("tools/live_controller_hung_daemon.py"));
    try std.testing.expect(isValidDaemonPath("tools/live_vm_desktop_failure_daemon.py"));
}

test "desktop controller constructs fixed real daemon argv without shell bridge" {
    var argv = try buildDaemonArgv(std.testing.allocator, "zig-out/bin/zig-scheduler-daemon", ".omo/evidence/task-09-real-vm/state", true);
    defer argv.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), argv.items.len);
    try std.testing.expectEqualStrings("zig-out/bin/zig-scheduler-daemon", argv.items[0]);
    try std.testing.expectEqualStrings("--follow", argv.items[1]);
    try std.testing.expectEqualStrings("--foreground", argv.items[2]);
    try std.testing.expectEqualStrings("--state-dir", argv.items[3]);
    try std.testing.expectEqualStrings(".omo/evidence/task-09-real-vm/state", argv.items[4]);
    for (argv.items) |arg| {
        try std.testing.expect(std.mem.indexOfAny(u8, arg, "&;|`") == null);
        try std.testing.expect(!std.mem.eql(u8, arg, "sh"));
        try std.testing.expect(!std.mem.eql(u8, arg, "bash"));
    }
}

test "desktop controller treats uppercase skip and refuse as fail closed" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    controller.active_action_id = try std.testing.allocator.dupe(u8, "desktop-run-1");
    controller.rollback_id = try std.testing.allocator.dupe(u8, "RB-desktop-run-1");
    controller.daemon_alive = true;
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"stage_finished","action_id":"desktop-run-1","status":"SKIP","reason":"qemu_unavailable","host_mutation":false}
    );
    try std.testing.expectEqual(DispatchStatus.incident, controller.dispatch_status_latch.?);
    try std.testing.expect(!controller.daemon_alive);

    controller.dispatch_status_latch = null;
    controller.daemon_alive = true;
    try controller.appendLine(
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"verifier","action_id":"desktop-run-1","status":"REFUSE","reason":"verifier_reject","host_mutation":false}
    );
    try std.testing.expectEqual(DispatchStatus.refused, controller.dispatch_status_latch.?);
    try std.testing.expect(!controller.daemon_alive);
}

test "desktop controller records malformed stream as incident status" {
    var controller = Controller.init(std.testing.allocator, .{ .daemon_path = "zig-out/bin/zig-scheduler-daemon", .state_dir = ".omo/evidence/test" });
    defer controller.deinit();
    controller.active_action_id = try std.testing.allocator.dupe(u8, "desktop-run-1");
    controller.daemon_alive = true;
    try controller.appendLine("{not-json");
    try std.testing.expectEqualStrings("incident", controller.history.items[0].event);
    try std.testing.expectEqualStrings("incident", controller.history.items[0].status);
    try std.testing.expectEqual(DispatchStatus.incident, controller.dispatch_status_latch.?);
    try std.testing.expect(!controller.daemon_alive);
}

fn hasReason(controller: *const Controller, reason: []const u8) bool {
    for (controller.history.items) |record| {
        if (std.mem.eql(u8, record.reason, reason)) return true;
    }
    return false;
}
