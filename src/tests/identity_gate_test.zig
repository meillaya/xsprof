const std = @import("std");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

fn expectLacksAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
    }
}

test "M5 ADR remains linked from docs and roadmap" {
    const allocator = std.testing.allocator;
    const adr = try readFileAlloc(allocator, "docs/adr/0001-m5-project-identity.md");
    defer allocator.free(adr);
    const roadmap = try readFileAlloc(allocator, "docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md");
    defer allocator.free(roadmap);
    const roadmap_index = try readFileAlloc(allocator, "docs/roadmap/README.md");
    defer allocator.free(roadmap_index);

    try std.testing.expect(std.mem.indexOf(u8, adr, "Status: Approved") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "broader scheduler laboratory roadmap with a simulator-only mainline") != null);
    try std.testing.expect(std.mem.indexOf(u8, roadmap, "docs/adr/0001-m5-project-identity.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, roadmap_index, "prd-multi-horizon-zig-scheduler-roadmap.md") != null);
}

test "M18 ADR is linked from docs and roadmap and keeps observability offline-only" {
    const allocator = std.testing.allocator;
    const adr = try readFileAlloc(allocator, "docs/adr/0002-m18-linux-observability-gate.md");
    defer allocator.free(adr);
    const roadmap = try readFileAlloc(allocator, "docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md");
    defer allocator.free(roadmap);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);

    try std.testing.expect(std.mem.indexOf(u8, adr, "Status: Approved") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "offline, observability-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "version-pinned, scrubbed snapshot fixtures") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "live tracing in the repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "capture tooling or automation in the repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, roadmap, "docs/adr/0002-m18-linux-observability-gate.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "docs/adr/0002-m18-linux-observability-gate.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "offline snapshot fixtures only") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "docs/m19-curated-linux-observability.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "M19 now implements the first approved offline import cut under that gate") != null);
}

test "M5 track classification is explicit" {
    const allocator = std.testing.allocator;
    const adr = try readFileAlloc(allocator, "docs/adr/0001-m5-project-identity.md");
    defer allocator.free(adr);
    const roadmap = try readFileAlloc(allocator, "docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md");
    defer allocator.free(roadmap);

    const required = [_][]const u8{
        "**Mainline core branch:** `M6 -> M17`",
        "**Optional Linux-observability branch:** `M19 -> M20`",
        "**Optional distribution branch:** `M21 -> M23`",
        "**Optional library branch:** `M22`",
        "**Optional research branch:** `M24`",
        "**Optional production branch:** `M26`",
    };

    for (required) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, adr, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, roadmap, "Track classification after M5") != null);
    try std.testing.expect(std.mem.indexOf(u8, roadmap, "Optional library branch") != null);
    try std.testing.expect(std.mem.indexOf(u8, roadmap, "Approved outcome") != null);
}

test "M5 open question is resolved" {
    const allocator = std.testing.allocator;
    const open_questions = try readFileAlloc(allocator, "docs/roadmap/open-questions.md");
    defer allocator.free(open_questions);

    try std.testing.expect(std.mem.indexOf(u8, open_questions, "[x] M5 decided") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_questions, "[ ] For optional M5") == null);
}

test "M18 gate proof surfaces and branch blocking are explicit" {
    const allocator = std.testing.allocator;
    const adr = try readFileAlloc(allocator, "docs/adr/0002-m18-linux-observability-gate.md");
    defer allocator.free(adr);
    const roadmap = try readFileAlloc(allocator, "docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md");
    defer allocator.free(roadmap);
    const test_spec = try readFileAlloc(allocator, "docs/roadmap/gates/test-spec-m18-linux-observability-gate.md");
    defer allocator.free(test_spec);
    const open_questions = try readFileAlloc(allocator, "docs/roadmap/open-questions.md");
    defer allocator.free(open_questions);

    const adr_required = [_][]const u8{
        "offline snapshot fixtures only",
        "approved capture families only",
        "Unsupported tuples are **out of scope by default**",
        "committed",
        "scrubbed",
        "manifest",
    };
    for (adr_required) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, adr, needle) != null);
    }

    try std.testing.expect(std.mem.indexOf(u8, roadmap, "M19 remains blocked until milestone-specific PRD/test-spec artifacts exist") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_spec, "offline observability-only wording is present") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_spec, "live capture, automation, and in-repo perf/ftrace execution workflows are explicitly rejected") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_questions, "docs/adr/0002-m18-linux-observability-gate.md") != null);
}

test "M19 proof surfaces expose the bounded observability import contract" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);
    const m19_doc = try readFileAlloc(allocator, "docs/m19-curated-linux-observability.md");
    defer allocator.free(m19_doc);

    try std.testing.expect(std.mem.indexOf(u8, readme, "fixtures/linux-observability/") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "does **not** widen `zig-scheduler/report` or `src/analysis`") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "src/observability/root.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, m19_doc, "Unsupported tuples fail closed by default.") != null);
    try std.testing.expect(std.mem.indexOf(u8, m19_doc, "tracefs-sched-snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, m19_doc, "perf sched") != null);
}

test "M20 boundary keeps report and analysis surfaces free of comparison payload fields" {
    const forbidden_fields = [_][]const u8{
        "pairing_id",
        "simulator_source",
        "observability_fixture_manifest",
        "normalized_order_summary",
        "metric_rows",
        "caveats",
    };

    const allocator = std.testing.allocator;
    const report_contract = try readFileAlloc(allocator, "src/contract/report.zig");
    defer allocator.free(report_contract);
    const cli_report = try readFileAlloc(allocator, "src/cli/report.zig");
    defer allocator.free(cli_report);
    const analysis_root = try readFileAlloc(allocator, "src/analysis/root.zig");
    defer allocator.free(analysis_root);
    const build_file = try readFileAlloc(allocator, "build.zig");
    defer allocator.free(build_file);

    try expectLacksAll(report_contract, &forbidden_fields);
    try expectLacksAll(cli_report, &forbidden_fields);
    try expectLacksAll(analysis_root, &forbidden_fields);
    try std.testing.expect(std.mem.indexOf(u8, build_file, "observability-comparison") == null);
}

test "M21 docs keep simulator-first teaching polish bounded to three anchors" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const m21_doc = try readFileAlloc(allocator, "docs/m21-simulator-first-teaching-surface.md");
    defer allocator.free(m21_doc);
    const status_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(status_doc);
    const teaching_pack = try readFileAlloc(allocator, "docs/labs/simulator-teaching-pack.md");
    defer allocator.free(teaching_pack);

    try std.testing.expect(std.mem.indexOf(u8, readme, "simulator-first teaching path") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "docs/labs/simulator-teaching-pack.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, m21_doc, "short-vs-long") != null);
    try std.testing.expect(std.mem.indexOf(u8, m21_doc, "sleep-wakeup") != null);
    try std.testing.expect(std.mem.indexOf(u8, m21_doc, "multicore-balancing") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_doc, "docs/labs/simulator-teaching-pack.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, teaching_pack, "M19/M20 remain reachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, teaching_pack, "no browser/WASM requirement") != null);
    try std.testing.expect(std.mem.indexOf(u8, teaching_pack, "Linux-performance") != null);
    try std.testing.expect(std.mem.indexOf(u8, teaching_pack, "group-fairness") == null);
}

test "M22 docs keep the library branch optional and simulator-first" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);
    const sdk_doc = try readFileAlloc(allocator, "docs/m22-library-sdk.md");
    defer allocator.free(sdk_doc);

    try std.testing.expect(std.mem.indexOf(u8, readme, "zig build m22-embed-smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "docs/m22-library-sdk.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "optional library branch") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "zig build m22-embed-smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdk_doc, "stable subset") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdk_doc, "browser/WASM") != null);
    try std.testing.expect(std.mem.indexOf(u8, sdk_doc, "M23-style") == null);
}

test "M24 docs keep the research sandbox unstable and outside the default path" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const status_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(status_doc);
    const sandbox_doc = try readFileAlloc(allocator, "docs/m24-research-sandbox.md");
    defer allocator.free(sandbox_doc);

    try std.testing.expect(std.mem.indexOf(u8, readme, "docs/m24-research-sandbox.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_doc, "research sandbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, sandbox_doc, "unstable") != null);
    try std.testing.expect(std.mem.indexOf(u8, sandbox_doc, "Promotion path") != null);
    try std.testing.expect(std.mem.indexOf(u8, sandbox_doc, "browser/WASM") != null);
    try std.testing.expect(std.mem.indexOf(u8, sandbox_doc, "stable default") == null);
}

test "M23 docs keep one canonical package entry and optional appendices only" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const status_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(status_doc);
    const package_doc = try readFileAlloc(allocator, "docs/courseware/m23-teaching-distribution.md");
    defer allocator.free(package_doc);
    const instructor_doc = try readFileAlloc(allocator, "docs/courseware/instructor-guide.md");
    defer allocator.free(instructor_doc);
    const assignment_doc = try readFileAlloc(allocator, "docs/courseware/assignment-pack-01.md");
    defer allocator.free(assignment_doc);

    try std.testing.expect(std.mem.indexOf(u8, readme, "docs/courseware/m23-teaching-distribution.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_doc, "docs/courseware/m23-teaching-distribution.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_doc, "package shell over M21") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_doc, "Appendix — bounded observability side lane") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructor_doc, "Appendix — optional M22 embedder extension") != null);
    try std.testing.expect(std.mem.indexOf(u8, assignment_doc, "zig build m22-embed-smoke") == null);
    try std.testing.expect(std.mem.indexOf(u8, assignment_doc, "--m19") == null);
    try std.testing.expect(std.mem.indexOf(u8, assignment_doc, "--m20") == null);
    try std.testing.expect(std.mem.indexOf(u8, package_doc, "browser/WASM") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_doc, "Linux-performance") != null);
}

test "M25 ADR keeps the production branch deferred and blocks M26 by default" {
    const allocator = std.testing.allocator;
    const adr = try readFileAlloc(allocator, "docs/adr/0003-m25-productionization-gate.md");
    defer allocator.free(adr);
    const roadmap = try readFileAlloc(allocator, "docs/roadmap/prd-multi-horizon-zig-scheduler-roadmap.md");
    defer allocator.free(roadmap);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);
    const open_questions = try readFileAlloc(allocator, "docs/roadmap/open-questions.md");
    defer allocator.free(open_questions);

    try std.testing.expect(std.mem.indexOf(u8, adr, "Status: Approved") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "Deferred the optional production branch indefinitely") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "M26 is blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, roadmap, "docs/adr/0003-m25-productionization-gate.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "deferred indefinitely") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_questions, "[x] M25 decided") != null);
}
