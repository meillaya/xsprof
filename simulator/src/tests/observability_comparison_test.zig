const std = @import("std");
const sim = @import("../root.zig");
const comparison = @import("../observability/comparison.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectStringFieldSet(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |lhs, rhs| {
        try std.testing.expectEqualStrings(lhs, rhs);
    }
}

fn expectJsonObjectFields(value: std.json.Value, expected: []const []const u8) !void {
    try std.testing.expect(value == .object);

    const object = value.object;
    try std.testing.expectEqual(expected.len, object.count());
    for (expected) |field| {
        try std.testing.expect(object.contains(field));
    }
}

test "comparison approved pairing manifest stays frozen to the sole approved inputs" {
    const allocator = std.testing.allocator;
    var manifest = try comparison.loadPairingManifest(allocator, comparison.default_pairing_manifest_path);
    defer manifest.deinit();

    try std.testing.expectEqualStrings(comparison.pairing_manifest_schema, manifest.value.schema);
    try std.testing.expectEqual(comparison.pairing_manifest_version, manifest.value.version);
    try std.testing.expectEqualStrings(comparison.default_pairing_id, manifest.value.pairing_id);
    try std.testing.expectEqualStrings(comparison.default_simulator_scenario_path, manifest.value.simulator_scenario);
    try std.testing.expectEqualStrings(comparison.default_simulator_policy, manifest.value.simulator_policy);
    try std.testing.expectEqualStrings(comparison.default_observability_manifest_path, manifest.value.observability_fixture_manifest);
    try expectStringFieldSet(comparison.approved_metric_set[0..], manifest.value.approved_metric_set);
    try expectStringFieldSet(comparison.approved_caveat_keys[0..], manifest.value.required_caveat_keys);

    const manifest_bytes = try readFileAlloc(allocator, comparison.default_pairing_manifest_path);
    defer allocator.free(manifest_bytes);
    var parsed_value = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer parsed_value.deinit();

    try expectJsonObjectFields(parsed_value.value, &.{
        "schema",
        "version",
        "pairing_id",
        "simulator_scenario",
        "simulator_policy",
        "observability_fixture_manifest",
        "approved_metric_set",
        "required_caveat_keys",
    });
}

test "comparison smoke stays reproducible for the approved inputs" {
    var summary = try comparison.buildApprovedComparison(std.testing.allocator, comparison.default_pairing_manifest_path);
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(comparison.schema_name, summary.schema);
    try std.testing.expectEqual(comparison.schema_version, summary.version);
    try std.testing.expectEqualStrings(comparison.default_pairing_id, summary.pairing_id);
    try std.testing.expectEqualStrings(comparison.default_simulator_scenario_path, summary.simulator_source.scenario_path);
    try std.testing.expectEqualStrings(comparison.default_simulator_policy, summary.simulator_source.policy);
    try std.testing.expectEqualStrings(sim.cli.schema_name, summary.simulator_source.report_schema);
    try std.testing.expectEqual(sim.cli.schema_version, summary.simulator_source.report_version);
    try std.testing.expectEqualStrings(comparison.default_observability_manifest_path, summary.observability_fixture_manifest.manifest_path);
    try std.testing.expectEqualStrings(sim.observability.approved_family, summary.observability_fixture_manifest.family);
    try std.testing.expectEqualStrings("linux-6.6", summary.observability_fixture_manifest.kernel_release);
    try std.testing.expectEqualStrings(sim.observability.approved_snapshot_format_version, summary.observability_fixture_manifest.snapshot_format_version);
    try std.testing.expectEqualStrings(sim.observability.approved_scrub_policy_version, summary.observability_fixture_manifest.scrub_policy_version);
    try expectStringFieldSet(&.{ "activation", "selection", "retirement" }, summary.normalized_order_summary.simulator_families);
    try expectStringFieldSet(&.{ "activation", "selection", "retirement" }, summary.normalized_order_summary.observability_families);
    try std.testing.expectEqual(comparison.approved_metric_set.len, summary.metric_rows.len);

    const expected_sim_ints = [_]i64{ 3, 5, 2, 20, 1, 2 };
    const expected_obs_ints = [_]i64{ 2, 1, 1, 5, 2, 3 };
    const expected_delta_ints = [_]i64{ 1, 4, 1, 15, -1, -1 };
    const expected_caveats = [_][]const u8{
        "not_fidelity",
        "not_fidelity",
        "not_fidelity",
        "unmatched_events_present",
        "observability_only",
        "identity_not_equivalent",
        "units_not_equivalent",
    };

    for (summary.metric_rows[0..6], 0..) |row, index| {
        try std.testing.expectEqualStrings(comparison.approved_metric_set[index], row.metric_key);
        try std.testing.expectEqualStrings(expected_caveats[index], row.caveat_key);
        try std.testing.expect(row.simulator_value == .int);
        try std.testing.expect(row.observability_value == .int);
        try std.testing.expect(row.delta == .int);
        try std.testing.expectEqual(expected_sim_ints[index], row.simulator_value.int);
        try std.testing.expectEqual(expected_obs_ints[index], row.observability_value.int);
        try std.testing.expectEqual(expected_delta_ints[index], row.delta.int);
    }

    try std.testing.expectEqualStrings(comparison.approved_metric_set[6], summary.metric_rows[6].metric_key);
    try std.testing.expectEqualStrings("units_not_equivalent", summary.metric_rows[6].caveat_key);
    try std.testing.expect(summary.metric_rows[6].simulator_value == .float);
    try std.testing.expect(summary.metric_rows[6].observability_value == .float);
    try std.testing.expect(summary.metric_rows[6].delta == .float);
    try std.testing.expectApproxEqAbs(7.0, summary.metric_rows[6].simulator_value.float, 0.000001);
    try std.testing.expectApproxEqAbs(0.2, summary.metric_rows[6].observability_value.float, 0.000001);
    try std.testing.expectApproxEqAbs(6.8, summary.metric_rows[6].delta.float, 0.000001);
}

test "comparison JSON contract shape stays frozen to v1" {
    var summary = try comparison.buildApprovedComparison(std.testing.allocator, comparison.default_pairing_manifest_path);
    defer summary.deinit(std.testing.allocator);

    const rendered = try comparison.renderComparisonJson(std.testing.allocator, &summary);
    defer std.testing.allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();

    try expectJsonObjectFields(parsed.value, comparison.top_level_fields[0..]);
    try expectJsonObjectFields(parsed.value.object.get("simulator_source").?, comparison.simulator_source_fields[0..]);
    try expectJsonObjectFields(parsed.value.object.get("observability_fixture_manifest").?, comparison.observability_fixture_manifest_fields[0..]);
    try expectJsonObjectFields(parsed.value.object.get("normalized_order_summary").?, comparison.normalized_order_summary_fields[0..]);
    try expectJsonObjectFields(parsed.value.object.get("caveats").?, comparison.approved_caveat_keys[0..]);

    const metric_rows = parsed.value.object.get("metric_rows").?.array;
    try std.testing.expectEqual(comparison.approved_metric_set.len, metric_rows.items.len);
    for (metric_rows.items[0..]) |row| {
        try expectJsonObjectFields(row, comparison.metric_row_fields[0..]);
    }
}

test "comparison numeric semantics stay exact for count and span rows" {
    var summary = try comparison.buildApprovedComparison(std.testing.allocator, comparison.default_pairing_manifest_path);
    defer summary.deinit(std.testing.allocator);

    const rendered = try comparison.renderComparisonJson(std.testing.allocator, &summary);
    defer std.testing.allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();

    const metric_rows = parsed.value.object.get("metric_rows").?.array.items;
    for (metric_rows[0..6]) |row| {
        try std.testing.expect(row.object.get("simulator_value").? == .integer);
        try std.testing.expect(row.object.get("observability_value").? == .integer);
        try std.testing.expect(row.object.get("delta").? == .integer);
    }
    const simulator_span_value = metric_rows[6].object.get("simulator_value").?;
    const observability_span_value = metric_rows[6].object.get("observability_value").?;
    try std.testing.expect(simulator_span_value == .integer or simulator_span_value == .float);
    try std.testing.expect(observability_span_value == .integer or observability_span_value == .float);
    try std.testing.expect(metric_rows[6].object.get("delta").? == .float);
}

test "comparison is deterministic across repeated approved-input runs" {
    var first = try comparison.buildApprovedComparison(std.testing.allocator, comparison.default_pairing_manifest_path);
    defer first.deinit(std.testing.allocator);
    var second = try comparison.buildApprovedComparison(std.testing.allocator, comparison.default_pairing_manifest_path);
    defer second.deinit(std.testing.allocator);

    const first_json = try comparison.renderComparisonJson(std.testing.allocator, &first);
    defer std.testing.allocator.free(first_json);
    const second_json = try comparison.renderComparisonJson(std.testing.allocator, &second);
    defer std.testing.allocator.free(second_json);

    try std.testing.expectEqualStrings(first_json, second_json);
}

test "comparison rejects unsupported marketing labels and keeps boundary flags false" {
    inline for (comparison.rejected_claim_labels) |label| {
        try std.testing.expectError(error.UnsupportedClaim, comparison.assertSupportedPresentationLabel(label));
    }
    try comparison.assertSupportedPresentationLabel("observability_only");
    try std.testing.expect(!comparison.supports_raw_event_alignment);
    try std.testing.expect(!comparison.supports_entity_equivalence);
}

test "comparison markdown proof surface renders the approved comparison rows" {
    var summary = try comparison.buildApprovedComparison(std.testing.allocator, comparison.default_pairing_manifest_path);
    defer summary.deinit(std.testing.allocator);

    const markdown = try comparison.renderComparisonMarkdown(std.testing.allocator, &summary);
    defer std.testing.allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "comparison simulator-to-trace comparison") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "`activation_count_delta`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "`time_span_delta`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "`units_not_equivalent`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "not replay authority or Linux-performance evidence") != null);
}
