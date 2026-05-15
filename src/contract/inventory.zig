//! M31-M32 contract owner inventory.
//!
//! This module is test metadata only. It records which source module owns each
//! public/lab contract boundary so architecture tests can detect accidental
//! deletion of the inventory without widening the production runtime surface.

pub const BoundaryClass = enum {
    runtime_portable,
    lab_only,
    intentionally_non_runtime,
};

pub const ContractSurface = struct {
    name: []const u8,
    owner_module: []const u8,
    boundary_class: BoundaryClass,
};

pub const contract_surfaces = [_]ContractSurface{
    .{
        .name = "scenario-input",
        .owner_module = "src/sim/scenario.zig",
        .boundary_class = .runtime_portable,
    },
    .{
        .name = "simulator-result-api",
        .owner_module = "src/sim/engine.zig",
        .boundary_class = .runtime_portable,
    },
    .{
        .name = "report-json",
        .owner_module = "src/contract/report.zig",
        .boundary_class = .runtime_portable,
    },
    .{
        .name = "sdk-facade",
        .owner_module = "src/lib.zig",
        .boundary_class = .runtime_portable,
    },
    .{
        .name = "cli-arguments",
        .owner_module = "src/cli/args.zig",
        .boundary_class = .lab_only,
    },
    .{
        .name = "tui-snapshot-output",
        .owner_module = "src/tui/root.zig",
        .boundary_class = .lab_only,
    },
    .{
        .name = "benchmark-output",
        .owner_module = "src/bench/root.zig",
        .boundary_class = .lab_only,
    },
    .{
        .name = "offline-linux-observability",
        .owner_module = "src/observability/root.zig",
        .boundary_class = .intentionally_non_runtime,
    },
    .{
        .name = "production-runtime-branch",
        .owner_module = "docs/adr/0003-m25-productionization-gate.md",
        .boundary_class = .intentionally_non_runtime,
    },
};
