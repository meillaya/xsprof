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

test "observability docs and fixture surfaces stay separated from simulator-native scenarios" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);
    const observability_doc = try readFileAlloc(allocator, "docs/curated-linux-observability.md");
    defer allocator.free(observability_doc);
    const fixture_doc = try readFileAlloc(allocator, "fixtures/linux-observability/README.md");
    defer allocator.free(fixture_doc);

    try std.testing.expect(std.mem.indexOf(u8, readme, "fixtures/linux-observability/") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "widening `zig-scheduler/report` or `src/analysis`") != null);
    try std.testing.expect(std.mem.indexOf(u8, observability_doc, "tracefs-sched-snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, observability_doc, "perf sched") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture_doc, "offline, observability-only") != null);
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

test "comparison claim-rejection audit keeps observability proof surfaces conservative" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);
    const observability_doc = try readFileAlloc(allocator, "docs/curated-linux-observability.md");
    defer allocator.free(observability_doc);
    const fixture_doc = try readFileAlloc(allocator, "fixtures/linux-observability/README.md");
    defer allocator.free(fixture_doc);

    const summary_markdown = try observability.loadFixtureSummaryMarkdown(std.testing.allocator, observability.default_manifest_path);
    defer std.testing.allocator.free(summary_markdown);

    try expectContainsAll(readme, &[_][]const u8{
        "offline,",
        "observability-only, version-pinned snapshot fixtures",
        "not live capture,",
        "Linux-performance claims",
    });
    try expectContainsAll(project_doc, &[_][]const u8{
        "offline snapshot fixtures only",
        "observability-only wording only",
        "replay-fidelity claims",
        "Linux-performance or calibration claims",
    });
    try expectContainsAll(observability_doc, &[_][]const u8{
        "observability-only",
        "does **not**:",
        "make replay, calibration, or Linux-performance claims",
    });
    try expectContainsAll(fixture_doc, &[_][]const u8{
        "offline, observability-only",
        "do not authorize live capture, replay, calibration, or",
    });
    try expectContainsAll(summary_markdown, &[_][]const u8{
        "Linux observability summary",
        "not replay, calibration, or Linux-performance evidence",
    });

    try expectLacksAll(readme, &forbidden_claim_labels);
    try expectLacksAll(observability_doc, &forbidden_claim_labels);
    try expectLacksAll(fixture_doc, &forbidden_claim_labels);
    try expectLacksAll(summary_markdown, &forbidden_claim_labels);
}
