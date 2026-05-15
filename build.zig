const std = @import("std");

const Build = std.Build;
const Compile = Build.Step.Compile;
const LazyPath = Build.LazyPath;
const Module = Build.Module;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // module ownership map:
    // - Contract/helper leaves stay dependency-free and can be reused by tools.
    // - The public SDK module wraps the internal simulator module deliberately.
    // - Tool modules (analysis, bench, reports, TUI) depend on explicit roots
    //   rather than importing each other's source files directly.
    const contract_mod = addModule(b, "zig_scheduler_report_contract", b.path("src/contract/report.zig"), target, &.{});
    const list_writer_mod = addModule(b, "list_writer", b.path("src/list_writer.zig"), target, &.{});

    const internal_mod = addModule(
        b,
        "zig_scheduler_internal",
        b.path("src/root.zig"),
        target,
        &.{
            .{ .name = "report_contract", .module = contract_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const lib_mod = addModule(
        b,
        "zig_scheduler",
        b.path("src/lib.zig"),
        target,
        &.{
            .{ .name = "report_contract", .module = contract_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
            .{ .name = "zig_scheduler_internal", .module = internal_mod },
        },
    );

    const analysis_mod = addModule(
        b,
        "zig_scheduler_analysis",
        b.path("src/analysis/root.zig"),
        target,
        &.{
            .{ .name = "report_contract", .module = contract_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const bench_mod = addModule(
        b,
        "zig_scheduler_bench",
        b.path("src/bench/root.zig"),
        target,
        &.{
            .{ .name = "zig_scheduler_internal", .module = internal_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
            .{ .name = "analysis_root", .module = analysis_mod },
        },
    );

    const report_pipeline_mod = addModule(
        b,
        "zig_scheduler_report_pipeline",
        b.path("src/report_pipeline/root.zig"),
        target,
        &.{
            .{ .name = "zig_scheduler_internal", .module = internal_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
            .{ .name = "analysis_root", .module = analysis_mod },
            .{ .name = "bench_root", .module = bench_mod },
        },
    );

    const quality_mod = addModule(
        b,
        "zig_scheduler_quality",
        b.path("src/quality/root.zig"),
        target,
        &.{
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const perf_mod = addModule(
        b,
        "zig_scheduler_perf",
        b.path("src/perf/root.zig"),
        target,
        &.{
            .{ .name = "bench_root", .module = bench_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const semantics_mod = addModule(
        b,
        "zig_scheduler_semantics",
        b.path("src/semantics/root.zig"),
        target,
        &.{
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const dashboard_mod = addModule(
        b,
        "zig_scheduler_dashboard",
        b.path("src/dashboard/root.zig"),
        target,
        &.{
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const tui_mod = addModule(
        b,
        "zig_scheduler_tui",
        b.path("src/tui/root.zig"),
        target,
        &.{
            .{ .name = "zig_scheduler_internal", .module = internal_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
            .{ .name = "analysis_root", .module = analysis_mod },
            .{ .name = "dashboard_root", .module = dashboard_mod },
        },
    );

    const exe = addExecutable(
        b,
        "zig-scheduler",
        b.path("src/main.zig"),
        target,
        optimize,
        &.{
            .{ .name = "zig_scheduler_internal", .module = internal_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
            .{ .name = "tui_root", .module = tui_mod },
        },
    );

    const sim_exe = addExecutable(
        b,
        "zig-scheduler-sim",
        b.path("src/sim_main.zig"),
        target,
        optimize,
        &.{
            .{ .name = "zig_scheduler_internal", .module = internal_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const embed_smoke_exe = addExecutable(
        b,
        "zig-scheduler-embed-smoke",
        b.path("src/examples/embed_smoke.zig"),
        target,
        optimize,
        &.{
            .{ .name = "zig_scheduler", .module = lib_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const analysis_exe = addExecutable(
        b,
        "zig-scheduler-analyze",
        b.path("src/analysis/main.zig"),
        target,
        optimize,
        &.{
            .{ .name = "analysis_root", .module = analysis_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const bench_exe = addExecutable(
        b,
        "zig-scheduler-bench",
        b.path("src/bench/main.zig"),
        target,
        optimize,
        &.{
            .{ .name = "bench_root", .module = bench_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const tui_exe = addExecutable(
        b,
        "zig-scheduler-tui",
        b.path("src/tui/main.zig"),
        target,
        optimize,
        &.{
            .{ .name = "tui_root", .module = tui_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    const semantics_exe = addExecutable(
        b,
        "zig-scheduler-semantics",
        b.path("src/semantics/main.zig"),
        target,
        optimize,
        &.{
            .{ .name = "semantics_root", .module = semantics_mod },
        },
    );

    const dashboard_exe = addExecutable(
        b,
        "zig-scheduler-dashboard",
        b.path("src/dashboard/main.zig"),
        target,
        optimize,
        &.{
            .{ .name = "dashboard_root", .module = dashboard_mod },
        },
    );

    const perf_exe = addExecutable(
        b,
        "zig-scheduler-perf",
        b.path("src/perf/main.zig"),
        target,
        optimize,
        &.{
            .{ .name = "perf_root", .module = perf_mod },
        },
    );

    const quality_exe = addExecutable(
        b,
        "zig-scheduler-quality",
        b.path("src/quality/main.zig"),
        target,
        optimize,
        &.{
            .{ .name = "quality_root", .module = quality_mod },
        },
    );

    const report_pipeline_exe = addExecutable(
        b,
        "zig-scheduler-reports",
        b.path("src/report_pipeline/main.zig"),
        target,
        optimize,
        &.{
            .{ .name = "report_pipeline_root", .module = report_pipeline_mod },
            .{ .name = "list_writer", .module = list_writer_mod },
        },
    );

    for ([_]*Compile{ exe, sim_exe, analysis_exe, bench_exe, tui_exe, embed_smoke_exe }) |artifact| {
        b.installArtifact(artifact);
    }

    addRunStep(b, exe, "run", "Run zig-scheduler (TUI-first main interface)", .{});
    addRunStep(b, sim_exe, "sim", "Run the legacy simulator CLI directly", .{});
    addRunStep(b, analysis_exe, "analyze", "Analyze exported zig-scheduler/report JSON", .{});
    addRunStep(b, bench_exe, "bench", "Render reproducible simulator-local benchmark baselines", .{});
    addRunStep(b, semantics_exe, "semantics", "Render the scheduling semantics v2 contract", .{
        .depend_on_install = false,
    });
    addRunStep(b, dashboard_exe, "dashboard", "Render the smart dashboard spine contract", .{
        .depend_on_install = false,
    });
    addRunStep(b, perf_exe, "perf", "Check reproducible simulator-local performance budgets", .{
        .depend_on_install = false,
    });
    addRunStep(b, tui_exe, "tui", "Run the interactive TUI trace explorer", .{});
    addRunStep(b, quality_exe, "quality", "Render the quality dashboard for maintainers", .{
        .depend_on_install = false,
    });
    // Reports are intentionally step-only: docs use `zig build reports`, not a
    // public installed binary contract.
    addRunStep(b, report_pipeline_exe, "reports", "Regenerate the curated reproducible report artifacts", .{
        .depend_on_install = false,
    });
    addRunStep(b, embed_smoke_exe, "embed-smoke", "Run the embedding smoke example against the curated public module", .{
        .depend_on_install = false,
        .forward_args = false,
    });

    const test_step = b.step("test", "Run library, analysis, benchmark, report-pipeline, main-entry, simulator CLI, and TUI tests");
    for ([_]*Module{
        lib_mod,
        internal_mod,
        analysis_mod,
        bench_mod,
        report_pipeline_mod,
        quality_mod,
        perf_mod,
        semantics_mod,
        dashboard_mod,
        exe.root_module,
        sim_exe.root_module,
        tui_mod,
    }) |module| {
        addTestDependency(b, test_step, module);
    }
}

fn addModule(
    b: *Build,
    name: []const u8,
    root_source_file: LazyPath,
    target: ResolvedTarget,
    imports: []const Module.Import,
) *Module {
    return b.addModule(name, .{
        .root_source_file = root_source_file,
        .target = target,
        .imports = imports,
    });
}

fn addExecutable(
    b: *Build,
    name: []const u8,
    root_source_file: LazyPath,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    imports: []const Module.Import,
) *Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
}

const RunStepOptions = struct {
    depend_on_install: bool = true,
    forward_args: bool = true,
};

fn addRunStep(
    b: *Build,
    artifact: *Compile,
    name: []const u8,
    description: []const u8,
    options: RunStepOptions,
) void {
    const run_cmd = b.addRunArtifact(artifact);
    if (options.depend_on_install) {
        run_cmd.step.dependOn(b.getInstallStep());
    }
    if (options.forward_args) {
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}

fn addTestDependency(b: *Build, test_step: *Build.Step, module: *Module) void {
    const module_tests = b.addTest(.{
        .root_module = module,
    });
    const run_module_tests = b.addRunArtifact(module_tests);
    test_step.dependOn(&run_module_tests.step);
}
