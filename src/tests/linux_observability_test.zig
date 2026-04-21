const std = @import("std");
const observability = @import("../observability/root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

test "M19 fixture import loads approved tracefs sched snapshot and renders summary smoke" {
    var loaded = try observability.loadFixture(std.testing.allocator, observability.default_manifest_path);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), loaded.events.len);
    try std.testing.expectEqualStrings("m19-tracefs-sched-demo", loaded.manifest.value.fixture_name);
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

test "M19 support matrix rejects unapproved tuple changes" {
    var matrix = try observability.loadSupportMatrix(std.testing.allocator, observability.support_matrix_path);
    defer matrix.deinit();

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
        .raw_snapshot_path = "fixtures/linux-observability/tracefs-sched-snapshot/m19-tracefs-sched-demo.trace",
        .redistribution_basis = "repo fixture",
        .observability_only_caveats = &caveats,
        .tuple = .{
            .family = "perf sched",
            .kernel_release = "linux-6.6",
            .tool_version = "tracefs-kernel-6.6",
            .tracefs_root = "/sys/kernel/tracing",
            .capture_recipe = "instance=m19-snapshot; events=sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit; snapshot=1",
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
        .raw_snapshot_path = "fixtures/linux-observability/tracefs-sched-snapshot/m19-tracefs-sched-demo.trace",
        .redistribution_basis = "repo fixture",
        .observability_only_caveats = &caveats,
        .tuple = .{
            .family = observability.approved_family,
            .kernel_release = "linux-6.8",
            .tool_version = "tracefs-kernel-6.6",
            .tracefs_root = "/sys/kernel/tracing",
            .capture_recipe = "instance=m19-snapshot; events=sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit; snapshot=1",
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

test "M19 docs and fixture surfaces stay separated from simulator-native scenarios" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);
    const m19_doc = try readFileAlloc(allocator, "docs/m19-curated-linux-observability.md");
    defer allocator.free(m19_doc);
    const fixture_doc = try readFileAlloc(allocator, "fixtures/linux-observability/README.md");
    defer allocator.free(fixture_doc);

    try std.testing.expect(std.mem.indexOf(u8, readme, "fixtures/linux-observability/") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "does not widen `zig-scheduler/report`") != null);
    try std.testing.expect(std.mem.indexOf(u8, m19_doc, "tracefs-sched-snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, m19_doc, "perf sched") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture_doc, "offline, observability-only") != null);
}
