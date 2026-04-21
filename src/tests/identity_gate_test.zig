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
