const std = @import("std");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

test "M5 ADR is linked from README and roadmap" {
    const allocator = std.testing.allocator;
    const adr = try readFileAlloc(allocator, "docs/adr/0001-m5-project-identity.md");
    defer allocator.free(adr);
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const roadmap = try readFileAlloc(allocator, ".omx/plans/prd-multi-horizon-zig-scheduler-roadmap.md");
    defer allocator.free(roadmap);

    try std.testing.expect(std.mem.indexOf(u8, adr, "Status: Approved") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "broader scheduler laboratory roadmap with a simulator-only mainline") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "docs/adr/0001-m5-project-identity.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, roadmap, "docs/adr/0001-m5-project-identity.md") != null);
}

test "M18 ADR is linked from README and roadmap and keeps observability offline-only" {
    const allocator = std.testing.allocator;
    const adr = try readFileAlloc(allocator, "docs/adr/0002-m18-linux-observability-gate.md");
    defer allocator.free(adr);
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const roadmap = try readFileAlloc(allocator, ".omx/plans/prd-multi-horizon-zig-scheduler-roadmap.md");
    defer allocator.free(roadmap);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);

    try std.testing.expect(std.mem.indexOf(u8, adr, "Status: Approved") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "offline, observability-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "version-pinned, scrubbed snapshot fixtures") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "live tracing in the repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, adr, "capture tooling or automation in the repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "docs/adr/0002-m18-linux-observability-gate.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, roadmap, "docs/adr/0002-m18-linux-observability-gate.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "docs/adr/0002-m18-linux-observability-gate.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "not live capture") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "tooling automation, replay") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "Linux-performance claims") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "offline snapshot fixtures only") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "docs/m19-curated-linux-observability.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "M19 now executes only inside the milestone-specific PRD/test-spec boundary") != null);
}

test "M5 track classification is explicit" {
    const allocator = std.testing.allocator;
    const adr = try readFileAlloc(allocator, "docs/adr/0001-m5-project-identity.md");
    defer allocator.free(adr);
    const roadmap = try readFileAlloc(allocator, ".omx/plans/prd-multi-horizon-zig-scheduler-roadmap.md");
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
    const open_questions = try readFileAlloc(allocator, ".omx/plans/open-questions.md");
    defer allocator.free(open_questions);

    try std.testing.expect(std.mem.indexOf(u8, open_questions, "[x] M5 decided") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_questions, "[ ] For optional M5") == null);
}

test "M18 gate proof surfaces and branch blocking are explicit" {
    const allocator = std.testing.allocator;
    const adr = try readFileAlloc(allocator, "docs/adr/0002-m18-linux-observability-gate.md");
    defer allocator.free(adr);
    const roadmap = try readFileAlloc(allocator, ".omx/plans/prd-multi-horizon-zig-scheduler-roadmap.md");
    defer allocator.free(roadmap);
    const test_spec = try readFileAlloc(allocator, ".omx/plans/test-spec-m18-linux-observability-gate.md");
    defer allocator.free(test_spec);
    const open_questions = try readFileAlloc(allocator, ".omx/plans/open-questions.md");
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
