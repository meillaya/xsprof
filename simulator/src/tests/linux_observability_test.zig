const std = @import("std");
const observability = @import("../observability/root.zig");

const forbidden_claim_labels = [_][]const u8{
    "faithful",
    "validated",
    "kernel-accurate",
    "replay match",
    "performance baseline",
    "calibrated against Linux truth",
};

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
    }
}

fn expectLacksAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
    }
}

test "observability fixture import loads approved tracefs sched snapshot and renders summary smoke" {
    var loaded = try observability.loadFixture(std.testing.allocator, observability.default_manifest_path);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), loaded.events.len);
    try std.testing.expectEqualStrings("tracefs-sched-demo", loaded.manifest.value.fixture_name);
    try std.testing.expectEqualStrings(observability.approved_family, loaded.manifest.value.tuple.family);
    try std.testing.expectEqual(@as(usize, 2), loaded.summary.cpu_ids.len);
    try std.testing.expectEqual(@as(u16, 0), loaded.summary.cpu_ids[0]);
    try std.testing.expectEqual(@as(u16, 1), loaded.summary.cpu_ids[1]);
    try std.testing.expectEqual(@as(usize, 3), loaded.summary.pid_ids.len);
    try std.testing.expectEqual(@as(u32, 0), loaded.summary.pid_ids[0]);
    try std.testing.expectEqual(@as(u32, 101), loaded.summary.pid_ids[1]);
    try std.testing.expectEqual(@as(u32, 202), loaded.summary.pid_ids[2]);
    try std.testing.expectEqual(@as(usize, 1), loaded.summary.counts.sched_switch);
    try std.testing.expectEqual(@as(usize, 1), loaded.summary.counts.sched_wakeup);
    try std.testing.expectEqual(@as(usize, 1), loaded.summary.counts.sched_wakeup_new);
    try std.testing.expectEqual(@as(usize, 1), loaded.summary.counts.sched_process_fork);
    try std.testing.expectEqual(@as(usize, 1), loaded.summary.counts.sched_process_exit);

    const markdown = try observability.renderSummaryMarkdown(std.testing.allocator, &loaded.summary);
    defer std.testing.allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "Linux observability summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "not replay, calibration, or Linux-performance evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "sched_process_exit") != null);
}

test "observability support matrix rejects unapproved tuple changes" {
    var matrix = try observability.loadSupportMatrix(std.testing.allocator, observability.support_matrix_path);
    defer matrix.deinit();

    try std.testing.expectEqual(@as(usize, 1), matrix.value.approved_tuples.len);

    const sched_events = [_][]const u8{
        "sched_switch",
        "sched_wakeup",
        "sched_wakeup_new",
        "sched_process_fork",
        "sched_process_exit",
    };
    const caveats = [_][]const u8{
        "Offline observability fixture only.",
    };

    const unsupported_family = observability.FixtureManifest{
        .schema = observability.fixture_manifest_schema,
        .version = 1,
        .fixture_name = "test",
        .source_class = "committed scrubbed offline snapshot",
        .raw_snapshot_path = "fixtures/linux-observability/tracefs-sched-snapshot/tracefs-sched-demo.trace",
        .redistribution_basis = "repo fixture",
        .observability_only_caveats = &caveats,
        .tuple = .{
            .family = "perf sched",
            .kernel_release = "linux-6.6",
            .tool_version = "tracefs-kernel-6.6",
            .tracefs_root = "/sys/kernel/tracing",
            .capture_recipe = "instance=tracefs-snapshot; events=sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit; snapshot=1",
            .trace_clock = "global",
            .enabled_sched_events = &sched_events,
            .scope = "system-wide dedicated instance",
            .mode = "snapshot",
            .time_window = "single bounded snapshot",
            .snapshot_format_version = observability.approved_snapshot_format_version,
            .scrub_policy_version = observability.approved_scrub_policy_version,
        },
    };
    try std.testing.expectError(observability.Error.UnsupportedFamily, observability.validateManifestAgainstMatrix(&unsupported_family, &matrix.value));

    const unsupported_tuple = observability.FixtureManifest{
        .schema = observability.fixture_manifest_schema,
        .version = 1,
        .fixture_name = "test",
        .source_class = "committed scrubbed offline snapshot",
        .raw_snapshot_path = "fixtures/linux-observability/tracefs-sched-snapshot/tracefs-sched-demo.trace",
        .redistribution_basis = "repo fixture",
        .observability_only_caveats = &caveats,
        .tuple = .{
            .family = observability.approved_family,
            .kernel_release = "linux-6.8",
            .tool_version = "tracefs-kernel-6.6",
            .tracefs_root = "/sys/kernel/tracing",
            .capture_recipe = "instance=tracefs-snapshot; events=sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit; snapshot=1",
            .trace_clock = "global",
            .enabled_sched_events = &sched_events,
            .scope = "system-wide dedicated instance",
            .mode = "snapshot",
            .time_window = "single bounded snapshot",
            .snapshot_format_version = observability.approved_snapshot_format_version,
            .scrub_policy_version = observability.approved_scrub_policy_version,
        },
    };
    try std.testing.expectError(observability.Error.UnsupportedTuple, observability.validateManifestAgainstMatrix(&unsupported_tuple, &matrix.value));
}

test "comparison fixed-input observability fixture remains reproducible across repeated loads" {
    var first = try observability.loadFixture(std.testing.allocator, observability.default_manifest_path);
    defer first.deinit(std.testing.allocator);
    var second = try observability.loadFixture(std.testing.allocator, observability.default_manifest_path);
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqual(first.events.len, second.events.len);
    try std.testing.expectEqual(first.summary.event_count, second.summary.event_count);
    try std.testing.expectEqual(first.summary.first_timestamp, second.summary.first_timestamp);
    try std.testing.expectEqual(first.summary.last_timestamp, second.summary.last_timestamp);
    try std.testing.expectEqualSlices(u16, first.summary.cpu_ids, second.summary.cpu_ids);
    try std.testing.expectEqualSlices(u32, first.summary.pid_ids, second.summary.pid_ids);
    try std.testing.expectEqualDeep(first.summary.counts, second.summary.counts);

    for (first.events, second.events) |lhs, rhs| {
        try std.testing.expectEqual(lhs.kind, rhs.kind);
        try std.testing.expectEqual(lhs.cpu, rhs.cpu);
        try std.testing.expectEqual(lhs.timestamp, rhs.timestamp);
        try std.testing.expectEqual(lhs.subject_pid, rhs.subject_pid);
        try std.testing.expectEqual(lhs.related_pid, rhs.related_pid);
        try std.testing.expectEqualStrings(lhs.raw_line, rhs.raw_line);
    }

    const first_markdown = try observability.renderSummaryMarkdown(std.testing.allocator, &first.summary);
    defer std.testing.allocator.free(first_markdown);
    const second_markdown = try observability.renderSummaryMarkdown(std.testing.allocator, &second.summary);
    defer std.testing.allocator.free(second_markdown);
    try std.testing.expectEqualStrings(first_markdown, second_markdown);
}

test "offline observer contract rejects live capture and control semantics" {
    const contract = observability.offlineObserverContract();
    try std.testing.expectEqualStrings("offline-linux-workload-observer", contract.mode_label);
    try std.testing.expect(std.mem.indexOf(u8, contract.fixture_root, "fixtures/linux-observability/") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract.allowed_input, "committed scrubbed version-pinned fixture") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract.forbidden_live_capture, "no live trace capture") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract.forbidden_live_capture, "eBPF collection") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract.forbidden_control, "no scheduler control") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract.forbidden_control, "cgroup mutation") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract.claim_boundary, "observability-only summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract.claim_boundary, "Linux-performance") != null);
}

test "lab live observer preflight fails closed until every gate is explicit" {
    try std.testing.expectError(observability.Error.LiveObserverGateClosed, observability.validateLiveObserverPreflight(.{}));
    try std.testing.expectError(observability.Error.LabEnvironmentRequired, observability.validateLiveObserverPreflight(.{
        .gate_open = true,
    }));
    try std.testing.expectError(observability.Error.OperatorConfirmationRequired, observability.validateLiveObserverPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
    }));
    try std.testing.expectError(observability.Error.PrivacyPolicyRequired, observability.validateLiveObserverPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .operator_confirmed = true,
    }));
    try std.testing.expectError(observability.Error.KernelTupleRequired, observability.validateLiveObserverPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .operator_confirmed = true,
        .privacy_policy_confirmed = true,
    }));
    try std.testing.expectError(observability.Error.AuditIdRequired, observability.validateLiveObserverPreflight(.{
        .gate_open = true,
        .approved_lab_environment = true,
        .operator_confirmed = true,
        .privacy_policy_confirmed = true,
        .kernel_tuple = "linux-6.6/tracefs-lab",
    }));
}
