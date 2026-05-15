const std = @import("std");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectLacksAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
    }
}

fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
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

test "M27-M32 roadmap slice stays governance and contract focused" {
    const allocator = std.testing.allocator;
    const prd = try readFileAlloc(allocator, ".omx/plans/prd-production-grade-scheduler-50-milestones.md");
    defer allocator.free(prd);
    const test_spec = try readFileAlloc(allocator, ".omx/plans/test-spec-production-grade-scheduler-50-milestones.md");
    defer allocator.free(test_spec);
    const adr = try readFileAlloc(allocator, "docs/adr/0003-m25-productionization-gate.md");
    defer allocator.free(adr);

    const prd_required = [_][]const u8{
        "Scope: planning only; no source implementation in this workflow",
        "Any actual production daemon/service/automation scope remains gated by `docs/adr/0003-m25-productionization-gate.md`",
        "| M27 | Current-truth reset and roadmap re-charter |",
        "| M28 | Repo information architecture cleanup |",
        "| M29 | Build graph hygiene |",
        "| M30 | Zig 0.16 compatibility cleanup pass |",
        "| M31 | Memory ownership and allocator contract audit |",
        "| M32 | Production-boundary compatibility and contract inventory |",
        "Treat M27-M46 as mandatory before any production-runtime work.",
    };
    try expectContainsAll(prd, &prd_required);

    const test_spec_required = [_][]const u8{
        "Wording audit: no current-doc claim that the repo is already a live production scheduler, kernel scheduler, daemon, or Linux-performance tool.",
        "M27-M36 cleanup: architecture/import tests, dead-link/docs consistency checks, ownership docs, M32 lab-only/runtime-portable contract classification.",
        "M27-M32 must prove production-scope truthfulness and contract-boundary clarity.",
    };
    try expectContainsAll(test_spec, &test_spec_required);

    try std.testing.expect(std.mem.indexOf(u8, adr, "no daemon/service/agent/automation implementation is authorized by this milestone") != null);
}

test "M27-M32 current docs preserve simulator truth and production gate" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);
    const future_directions = try readFileAlloc(allocator, "docs/future-directions.md");
    defer allocator.free(future_directions);

    const readme_required = [_][]const u8{
        "deterministic CPU scheduling simulator",
        "not as a kernel scheduler, daemon, or production automation system",
        "The repo is still simulator-first",
    };
    try expectContainsAll(readme, &readme_required);

    const project_doc_required = [_][]const u8{
        "deterministic CPU scheduling simulator",
        "kernel component, daemon",
        "production scheduler.",
        "implementation today",
        "simulator-first mainline",
        "optional production branch is currently deferred indefinitely after M25",
    };
    try expectContainsAll(project_doc, &project_doc_required);

    const future_required = [_][]const u8{
        "This document does not reopen M26",
        "not approval to begin implementation",
        "future decision explicitly reopens it",
    };
    try expectContainsAll(future_directions, &future_required);
}

test "M27-M32 build graph remains testable and free of production runtime artifacts" {
    const allocator = std.testing.allocator;
    const build_file = try readFileAlloc(allocator, "build.zig");
    defer allocator.free(build_file);

    const required_test_graph = [_][]const u8{
        "const test_step = b.step(\"test\"",
        "lib_mod,",
        "internal_mod,",
        "analysis_mod,",
        "bench_mod,",
        "report_pipeline_mod,",
        "exe.root_module,",
        "sim_exe.root_module,",
        "tui_mod,",
        "addTestDependency(b, test_step, module)",
    };
    try expectContainsAll(build_file, &required_test_graph);

    const zig_0_16_build_api = [_][]const u8{
        ".root_module = b.createModule(.{",
        "b.path(\"src/main.zig\")",
        "b.path(\"src/sim_main.zig\")",
    };
    try expectContainsAll(build_file, &zig_0_16_build_api);

    const forbidden_runtime_artifacts = [_][]const u8{
        "zig-scheduler-daemon",
        "zig-scheduler-service",
        "zig-scheduler-agent",
        "zig-scheduler-runtime",
        "production-runtime",
    };
    try expectLacksAll(build_file, &forbidden_runtime_artifacts);
}

test "M31-M32 ownership and public contract docs remain anchored" {
    const allocator = std.testing.allocator;
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);
    const sdk_doc = try readFileAlloc(allocator, "docs/m22-library-sdk.md");
    defer allocator.free(sdk_doc);
    const prd = try readFileAlloc(allocator, ".omx/plans/prd-production-grade-scheduler-50-milestones.md");
    defer allocator.free(prd);

    const architecture_contract_anchors = [_][]const u8{
        "### 1. Scenario layer",
        "### 3. Scheduling-class boundary",
        "### 4. Reporting/export layer",
        "src/contract/report.zig",
        "library / SDK stabilization for embedders",
        "embedder facade",
    };
    try expectContainsAll(project_doc, &architecture_contract_anchors);

    const sdk_contract_anchors = [_][]const u8{
        "stable subset",
        "Workflow-stable allocator-owning types",
        "freeScenario",
        "writeJsonReport",
    };
    try expectContainsAll(sdk_doc, &sdk_contract_anchors);

    const m31_m32_anchors = [_][]const u8{
        "Document ownership rules for scenarios, reports, parsed JSON, generated workloads, TUI history.",
        "Inventory scenario input, report JSON, SDK, CLI args, TUI snapshot output, benchmark output",
        "classify each as lab-only, runtime-portable, or intentionally non-runtime",
    };
    try expectContainsAll(prd, &m31_m32_anchors);
}

test "M33-M36 source-of-truth index anchors cleanup claims" {
    const allocator = std.testing.allocator;
    const source_index = try readFileAlloc(allocator, "docs/source-of-truth-index.md");
    defer allocator.free(source_index);
    const roadmap_index = try readFileAlloc(allocator, "docs/roadmap/README.md");
    defer allocator.free(roadmap_index);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);

    const index_required = [_][]const u8{
        "Canonical claim owners",
        "Project identity: deterministic simulator / scheduler laboratory",
        "Production branch / daemon / service / runtime permission",
        "Linux observability scope",
        "Scenario input contract",
        "Report JSON contract",
        "M36 maintenance rules",
    };
    try expectContainsAll(source_index, &index_required);

    const docs_required = [_][]const u8{
        "docs/source-of-truth-index.md",
        "M36 de-duplication hub",
        "ScenarioFormat.legacy_line",
        "src/contract/inventory.zig",
    };
    const roadmap_required = [_][]const u8{
        "docs/source-of-truth-index.md",
        "M36 de-duplication hub",
    };
    try expectContainsAll(roadmap_index, &roadmap_required);
    try expectContainsAll(project_doc, &docs_required);
}
