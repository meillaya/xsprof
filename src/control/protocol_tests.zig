const std = @import("std");
const protocol = @import("protocol.zig");

const ActionKind = protocol.ActionKind;
const DaemonEvent = protocol.DaemonEvent;
const EventKind = protocol.EventKind;
const event_schema = protocol.event_schema;
const parseActionJson = protocol.parseActionJson;

test "operator action protocol rejects shell strings and unknown actions" {
    // Given: untrusted operator/daemon action JSON containing an unknown action and shell-shaped text.
    // When: the boundary parser receives it.
    // Then: it must reject before any command registry can observe it.
    try std.testing.expectError(error.UnknownAction, parseActionJson(std.testing.allocator,
        \\{"action":"attach && rm -rf /","target_cgroup":"/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope"}
    ));
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"action":"run_lab_host_safe","run_id":"bad\nrun"}
    ));
}

test "operator action protocol rejects forbidden command fields" {
    // Given: untrusted operator input tries to smuggle execution authority through JSON fields.
    // When: the boundary parser receives command, shell, or argv keys.
    // Then: the typed protocol rejects them before any daemon action can be created.
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"action":"run_lab_host_safe","command":"bash qa/vm/run_all_lab.sh"}
    ));
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"action":"run_lab_host_safe","shell":"sh"}
    ));
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"action":"run_lab_host_safe","argv":["qa/vm/run_all_lab.sh"]}
    ));
}

test "operator action protocol roundtrips typed lab action" {
    // Given: a valid host-safe lab action.
    // When: it is parsed and serialized at the trust boundary.
    // Then: the typed action and stable schema survive without shell command fields.
    const parsed = try parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_host_safe","run_id":"lab-demo"}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(ActionKind.run_lab_host_safe, parsed.value.kind);
    const rendered = try parsed.value.toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "run_lab_host_safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "command") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shell") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "argv") == null);
}

test "daemon event protocol roundtrips typed refusal" {
    const rendered = try (DaemonEvent{
        .kind = .refusal,
        .action_id = "act-1",
        .status = "refused_host",
    }).toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, event_schema) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "refused_host") != null);
}

test "operator action protocol rejects target cgroup traversal" {
    // Given: a known action with a traversal-shaped target cgroup.
    // When: the boundary parser receives it.
    // Then: the protocol rejects the path before daemon or harness code sees it.
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"action":"partial_attach","target_cgroup":"/sys/fs/cgroup/zig-scheduler-lab.slice/../../system.slice"}
    ));
}

test "operator action protocol preserves partial attach gates when rendering" {
    // Given: a valid partial attach action with cgroup, audit id, and rollback id gates.
    // When: it is parsed and rendered for daemon/operator journaling.
    // Then: every gate survives the roundtrip and no shell command fields appear.
    const parsed = try parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"partial_attach","target_cgroup":"/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-demo"}
    );
    defer parsed.deinit();
    const rendered = try parsed.value.toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "partial_attach") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AUD-20990101T000000Z-deadbee-abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "RB-demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "command") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shell") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "argv") == null);
}

test "operator action protocol accepts rollback lab targets" {
    const parsed = try parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"rollback_lab_run","action_id":"rb-1","target_action_id":"lab-1","rollback_id":"RB-demo"}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(ActionKind.rollback_lab_run, parsed.value.kind);
    try std.testing.expectEqualStrings("lab-1", parsed.value.target_action_id);
    const rendered = try parsed.value.toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "target_action_id") != null);
}

test "operator action protocol accepts live microvm action without execution fields" {
    const parsed = try parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"live-1","run_id":"live-demo","audit_id":"AUD-live-demo","rollback_id":"RB-live-demo"}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(ActionKind.run_lab_microvm_live, parsed.value.kind);
    try std.testing.expectEqualStrings("live-demo", parsed.value.run_id);

    const rendered = try parsed.value.toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "run_lab_microvm_live") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "command") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shell") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "argv") == null);
}

test "operator action protocol rejects live microvm command smuggling" {
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","run_id":"live-demo","argv":["qemu-system-x86_64"]}
    ));
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","run_id":"live-demo","command":"qa/vm/run_microvm_live_lab.sh"}
    ));
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","run_id":"live-demo","shell":"sh"}
    ));
}

test "operator action protocol rejects live microvm host mutation flags" {
    try std.testing.expectError(error.InvalidField, parseActionJson(std.testing.allocator,
        \\{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","run_id":"live-demo","host_mutation":true}
    ));
}

test "daemon event protocol includes live microvm lifecycle event kinds" {
    const lifecycle = [_]EventKind{
        .microvm_boot,
        .vm_marker,
        .bpf_register,
        .runtime_sample,
        .rollback,
        .cleanup,
    };
    inline for (lifecycle) |kind| {
        const rendered = try (DaemonEvent{
            .kind = kind,
            .action_id = "live-1",
            .status = "accepted",
        }).toJson(std.testing.allocator);
        defer std.testing.allocator.free(rendered);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "host_mutation\":false") != null);
    }
}

test "daemon validation event requires live bundle path" {
    try std.testing.expectError(error.InvalidField, (DaemonEvent{
        .kind = .validation,
        .action_id = "live-1",
        .status = "PASS",
    }).toJson(std.testing.allocator));
}

test "daemon event protocol exposes live bundle path for validation events" {
    const rendered = try (DaemonEvent{
        .kind = .validation,
        .action_id = "live-1",
        .status = "PASS",
        .live_bundle_path = "evidence/lab/run-all/microvm-live-demo/summary.json",
    }).toJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"live_bundle_path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "microvm-live-demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "host_mutation\":false") != null);
}
