const std = @import("std");
const commands = @import("commands.zig");
const protocol = @import("protocol.zig");

fn expectNoStaticDaemonCacheEnv(plan: commands.CommandPlan) !void {
    for (plan.env) |env_var| {
        try std.testing.expect(!std.mem.eql(u8, env_var.name, "XDG_CACHE_HOME"));
        try std.testing.expect(std.mem.indexOf(u8, env_var.value, "zig-scheduler-daemon-cache") == null);
    }
}

fn expectNoPathLookup(plan: commands.CommandPlan) !void {
    try std.testing.expect(plan.env.len >= 1);
    try std.testing.expectEqualStrings("PATH", plan.env[0].name);
    try std.testing.expect(std.mem.indexOf(u8, plan.env[0].value, ".omo/evidence/hostile-bin") == null);
    try expectNoStaticDaemonCacheEnv(plan);
    for (plan.args()) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "bash") == null);
        try std.testing.expect(std.mem.indexOf(u8, arg, "python3") == null);
        try std.testing.expect(std.mem.indexOf(u8, arg, "bpftool") == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, arg, '\n') == null);
    }
}

test "trusted lab command registry rejects hostile path and newline args" {
    try std.testing.expectError(error.InvalidField, commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_host_safe,
        .run_id = "bad\nrun",
    }));
    try std.testing.expectError(error.InvalidAction, commands.buildLabCommand(std.testing.allocator, .{ .kind = .preflight }));
}

test "trusted lab command registry does not export static daemon cache path" {
    const actions = [_]protocol.OperatorAction{
        .{ .kind = .run_lab_host_safe, .run_id = "host-safe-cache" },
        .{ .kind = .run_lab_vm, .run_id = "vm-cache" },
        .{ .kind = .run_lab_microvm_live, .run_id = "microvm-cache", .audit_id = "AUD-20990101T000000Z-deadbee-abc123" },
        .{ .kind = .verifier_only, .run_id = "verifier-cache" },
        .{ .kind = .partial_attach, .run_id = "partial-cache", .audit_id = "AUD-20990101T000000Z-deadbee-abc123", .rollback_id = "RB-partial-cache" },
        .{ .kind = .observe, .run_id = "observe-cache" },
        .{ .kind = .rollback, .run_id = "rollback-cache" },
        .{ .kind = .incident_drill, .run_id = "incident-cache" },
    };
    for (actions) |action| {
        var plan = try commands.buildLabCommand(std.testing.allocator, action);
        defer plan.deinit(std.testing.allocator);
        try expectNoStaticDaemonCacheEnv(plan);
    }
}

test "trusted lab command registry uses fixed argv and clean env" {
    var plan = try commands.buildLabCommand(std.testing.allocator, .{ .kind = .run_lab_host_safe, .run_id = "demo" });
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("qa/vm/run_all_lab.sh", plan.executable);
    try std.testing.expectEqualStrings("--mode", plan.args()[1]);
    try std.testing.expectEqualStrings("host-safe", plan.args()[2]);
    try std.testing.expectEqual(commands.HostBehavior.surrogate, plan.host_behavior);
    try expectNoPathLookup(plan);
}

test "trusted lab command registry maps verifier attach observe and rollback" {
    const actions = [_]protocol.OperatorAction{
        .{ .kind = .verifier_only, .run_id = "verifier" },
        .{ .kind = .partial_attach, .run_id = "partial", .audit_id = "AUD-20990101T000000Z-deadbee-abc123", .rollback_id = "RB-partial" },
        .{ .kind = .observe, .run_id = "observe" },
        .{ .kind = .rollback, .run_id = "rollback" },
    };
    for (actions) |action| {
        var plan = try commands.buildLabCommand(std.testing.allocator, action);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.startsWith(u8, plan.executable, "qa/vm/"));
        try expectNoPathLookup(plan);
    }
}

test "trusted lab command registry maps live microvm action to fixed argv" {
    var plan = try commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_microvm_live,
        .run_id = "microvm-live-demo",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
    });
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("qa/vm/run_microvm_live_lab.sh", plan.executable);
    try std.testing.expectEqualStrings("qa/vm/run_microvm_live_lab.sh", plan.args()[0]);
    try std.testing.expectEqualStrings("--out", plan.args()[1]);
    try std.testing.expectEqualStrings("evidence/lab/run-all/microvm-live-demo", plan.args()[2]);
    try std.testing.expectEqual(@as(usize, 3), plan.args().len);
    try std.testing.expectEqual(commands.HostBehavior.surrogate, plan.host_behavior);
    try expectNoPathLookup(plan);
}

test "trusted lab command registry keeps fixture vm route separate from live microvm route" {
    var fixture_plan = try commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_vm,
        .run_id = "fixture-vm-demo",
    });
    defer fixture_plan.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("qa/vm/run_all_lab.sh", fixture_plan.executable);
    try std.testing.expect(std.mem.indexOf(u8, fixture_plan.out_dir, "fixture-vm-demo") != null);

    var live_plan = try commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_microvm_live,
        .run_id = "live-vm-demo",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
    });
    defer live_plan.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("qa/vm/run_microvm_live_lab.sh", live_plan.executable);
    try std.testing.expect(std.mem.indexOf(u8, live_plan.out_dir, "live-vm-demo") != null);
}

test "trusted lab command registry requires explicit audit id for mutation-capable VM actions" {
    try std.testing.expectError(error.InvalidField, commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_microvm_live,
        .run_id = "microvm-missing-audit",
    }));
    try std.testing.expectError(error.InvalidField, commands.buildLabCommand(std.testing.allocator, .{
        .kind = .partial_attach,
        .run_id = "partial-missing-audit",
        .rollback_id = "RB-partial-missing-audit",
    }));
    try std.testing.expectError(error.InvalidField, commands.buildLabCommand(std.testing.allocator, .{
        .kind = .partial_attach,
        .run_id = "partial-missing-rollback",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
    }));
}

test "trusted lab command registry rejects live microvm unsafe run ids" {
    try std.testing.expectError(error.InvalidField, commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_microvm_live,
        .run_id = "../escape",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
    }));
    try std.testing.expectError(error.InvalidField, commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_microvm_live,
        .run_id = ".",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
    }));
    try std.testing.expectError(error.InvalidField, commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_microvm_live,
        .run_id = "..",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
    }));
    try std.testing.expectError(error.InvalidField, commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_microvm_live,
        .run_id = ".hidden",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
    }));
    try std.testing.expectError(error.InvalidField, commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_microvm_live,
        .run_id = "trailing.",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
    }));
    try std.testing.expectError(error.InvalidField, commands.buildLabCommand(std.testing.allocator, .{
        .kind = .run_lab_microvm_live,
        .run_id = "bad\nrun",
        .audit_id = "AUD-20990101T000000Z-deadbee-abc123",
    }));
}
