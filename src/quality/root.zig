const std = @import("std");
const list_writer = @import("list_writer");

pub const GateKind = enum {
    taxonomy,
    golden_governance,
    property,
    determinism,
    fault_injection,
    architecture,
    cli_sdk,
    dashboard_snapshot,
    release,
    quality_dashboard,

    pub fn label(self: GateKind) []const u8 {
        return switch (self) {
            .taxonomy => "test taxonomy",
            .golden_governance => "golden fixture governance",
            .property => "property testing",
            .determinism => "determinism oracle",
            .fault_injection => "fault injection",
            .architecture => "architecture gate",
            .cli_sdk => "CLI/SDK compatibility",
            .dashboard_snapshot => "dashboard snapshot regression",
            .release => "release checklist",
            .quality_dashboard => "quality dashboard",
        };
    }
};

pub const GateStatus = enum {
    enforced,
    documented,

    pub fn label(self: GateStatus) []const u8 {
        return switch (self) {
            .enforced => "enforced",
            .documented => "documented",
        };
    }
};

pub const QualityGate = struct {
    milestone: []const u8,
    kind: GateKind,
    owner: []const u8,
    command: []const u8,
    evidence: []const u8,
    status: GateStatus,
};

pub const quality_gates = [_]QualityGate{
    .{ .milestone = "M37", .kind = .taxonomy, .owner = "docs/quality-gates.md", .command = "zig build test --summary all", .evidence = "taxonomy table maps unit, integration, property, golden, snapshot, contract, and architecture tests to owners", .status = .enforced },
    .{ .milestone = "M38", .kind = .golden_governance, .owner = "docs/quality-gates.md", .command = "zig build reports -- --check", .evidence = "golden artifacts and update rules are review-owned before fixture changes land", .status = .documented },
    .{ .milestone = "M39", .kind = .property, .owner = "src/tests/property_test.zig", .command = "zig build test --summary all", .evidence = "generated scenarios cover groups, topology, phases, deadlines, policies, export accounting, and shrinker workflows", .status = .enforced },
    .{ .milestone = "M40", .kind = .determinism, .owner = "src/tests/quality_gate_test.zig", .command = "zig build test --summary all", .evidence = "curated corpus runs are compared across repeated simulator executions", .status = .enforced },
    .{ .milestone = "M41", .kind = .fault_injection, .owner = "src/tests/quality_gate_test.zig", .command = "zig build test --summary all", .evidence = "invalid scenario and report inputs assert stable errors instead of panics", .status = .enforced },
    .{ .milestone = "M42", .kind = .architecture, .owner = "src/tests/policy_architecture_test.zig", .command = "zig build test --summary all", .evidence = "forbidden imports and report-contract-only consumers are checked in tests", .status = .enforced },
    .{ .milestone = "M43", .kind = .cli_sdk, .owner = "src/tests/library_sdk_test.zig", .command = "zig build m22-embed-smoke && zig build test --summary all", .evidence = "public SDK namespace, embedder smoke flow, and CLI report compatibility stay frozen", .status = .enforced },
    .{ .milestone = "M44", .kind = .dashboard_snapshot, .owner = "src/tests/quality_gate_test.zig", .command = "zig build test --summary all", .evidence = "TUI snapshot/layout contracts cover compact, medium, and large terminal tiers", .status = .enforced },
    .{ .milestone = "M45", .kind = .release, .owner = "docs/release-checklist.md", .command = "zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print) && git diff --check && zig build test --summary all", .evidence = "release checklist requires changelog, contract migration notes, baseline review, and artifact checks", .status = .documented },
    .{ .milestone = "M46", .kind = .quality_dashboard, .owner = "src/quality/root.zig", .command = "zig build quality", .evidence = "maintainers can render this quality dashboard from the build graph", .status = .enforced },
};

pub fn writeMarkdown(writer: anytype) !void {
    try writer.writeAll("# zig-scheduler quality dashboard\n\n");
    try writer.writeAll("Scope: simulator-lab/product quality under ADR 0003. This dashboard does not authorize a daemon, service, agent, or production automation runtime.\n\n");
    try writer.writeAll("| Milestone | Gate | Status | Owner | Command | Evidence |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- | --- |\n");
    for (quality_gates) |gate| {
        try writer.print("| {s} | {s} | {s} | `{s}` | `{s}` | {s} |\n", .{
            gate.milestone,
            gate.kind.label(),
            gate.status.label(),
            gate.owner,
            gate.command,
            gate.evidence,
        });
    }
    try writer.writeAll("\n## Maintainer gate\n\n");
    try writer.writeAll("Run `zig build quality`, then `zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print)`, `git diff --check`, and `zig build test --summary all` before claiming M37-M46 complete.\n");
}

pub fn renderMarkdown(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var writer = list_writer.writer(&out, allocator);
    try writeMarkdown(&writer);
    return try out.toOwnedSlice(allocator);
}

test "M46 quality dashboard enumerates all Phase B gates" {
    const allocator = std.testing.allocator;
    const rendered = try renderMarkdown(allocator);
    defer allocator.free(rendered);

    for (quality_gates) |gate| {
        try std.testing.expect(std.mem.indexOf(u8, rendered, gate.milestone) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, gate.kind.label()) != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, gate.owner) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ADR 0003") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "daemon, service, agent") != null);
}
