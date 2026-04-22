const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const contract_mod = b.addModule("zig_scheduler_report_contract", .{
        .root_source_file = b.path("src/contract/report.zig"),
        .target = target,
    });

    const internal_mod = b.addModule("zig_scheduler_internal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "report_contract", .module = contract_mod },
        },
    });

    const lib_mod = b.addModule("zig_scheduler", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "report_contract", .module = contract_mod },
            .{ .name = "zig_scheduler_internal", .module = internal_mod },
        },
    });

    const analysis_mod = b.addModule("zig_scheduler_analysis", .{
        .root_source_file = b.path("src/analysis/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "report_contract", .module = contract_mod },
        },
    });

    const bench_mod = b.addModule("zig_scheduler_bench", .{
        .root_source_file = b.path("src/bench/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zig_scheduler_internal", .module = internal_mod },
            .{ .name = "analysis_root", .module = analysis_mod },
        },
    });

    const report_pipeline_mod = b.addModule("zig_scheduler_report_pipeline", .{
        .root_source_file = b.path("src/report_pipeline/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zig_scheduler_internal", .module = internal_mod },
            .{ .name = "analysis_root", .module = analysis_mod },
            .{ .name = "bench_root", .module = bench_mod },
        },
    });

    const tui_mod = b.addModule("zig_scheduler_tui", .{
        .root_source_file = b.path("src/tui/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zig_scheduler_internal", .module = internal_mod },
            .{ .name = "analysis_root", .module = analysis_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zig-scheduler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tui_root", .module = tui_mod },
            },
        }),
    });

    const sim_exe = b.addExecutable(.{
        .name = "zig-scheduler-sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_scheduler_internal", .module = internal_mod },
            },
        }),
    });

    const embed_smoke_exe = b.addExecutable(.{
        .name = "zig-scheduler-m22-embed-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/m22_embed_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_scheduler", .module = lib_mod },
            },
        }),
    });

    const analysis_exe = b.addExecutable(.{
        .name = "zig-scheduler-analyze",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/analysis/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "analysis_root", .module = analysis_mod },
            },
        }),
    });

    const bench_exe = b.addExecutable(.{
        .name = "zig-scheduler-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bench_root", .module = bench_mod },
            },
        }),
    });

    const tui_exe = b.addExecutable(.{
        .name = "zig-scheduler-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tui_root", .module = tui_mod },
            },
        }),
    });

    const report_pipeline_exe = b.addExecutable(.{
        .name = "zig-scheduler-reports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/report_pipeline/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "report_pipeline_root", .module = report_pipeline_mod },
            },
        }),
    });

    b.installArtifact(exe);
    b.installArtifact(sim_exe);
    b.installArtifact(analysis_exe);
    b.installArtifact(bench_exe);
    b.installArtifact(tui_exe);
    b.installArtifact(embed_smoke_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zig-scheduler (TUI-first main interface)");
    run_step.dependOn(&run_cmd.step);

    const sim_cmd = b.addRunArtifact(sim_exe);
    sim_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        sim_cmd.addArgs(args);
    }

    const sim_step = b.step("sim", "Run the legacy simulator CLI directly");
    sim_step.dependOn(&sim_cmd.step);

    const analyze_cmd = b.addRunArtifact(analysis_exe);
    analyze_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        analyze_cmd.addArgs(args);
    }

    const analyze_step = b.step("analyze", "Analyze exported zig-scheduler/report JSON");
    analyze_step.dependOn(&analyze_cmd.step);

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Render reproducible simulator-local benchmark baselines");
    bench_step.dependOn(&bench_cmd.step);

    const tui_cmd = b.addRunArtifact(tui_exe);
    tui_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        tui_cmd.addArgs(args);
    }

    const tui_step = b.step("tui", "Run the M15 interactive TUI trace explorer");
    tui_step.dependOn(&tui_cmd.step);

    const report_pipeline_cmd = b.addRunArtifact(report_pipeline_exe);
    if (b.args) |args| {
        report_pipeline_cmd.addArgs(args);
    }

    const report_pipeline_step = b.step("reports", "Regenerate the curated reproducible report artifacts");
    report_pipeline_step.dependOn(&report_pipeline_cmd.step);

    const embed_smoke_cmd = b.addRunArtifact(embed_smoke_exe);
    const embed_smoke_step = b.step("m22-embed-smoke", "Run the M22 embedding smoke example against the curated public module");
    embed_smoke_step.dependOn(&embed_smoke_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const internal_tests = b.addTest(.{
        .root_module = internal_mod,
    });
    const run_internal_tests = b.addRunArtifact(internal_tests);

    const analysis_tests = b.addTest(.{
        .root_module = analysis_mod,
    });
    const run_analysis_tests = b.addRunArtifact(analysis_tests);

    const bench_tests = b.addTest(.{
        .root_module = bench_mod,
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const sim_exe_tests = b.addTest(.{
        .root_module = sim_exe.root_module,
    });
    const run_sim_exe_tests = b.addRunArtifact(sim_exe_tests);

    const tui_tests = b.addTest(.{
        .root_module = tui_mod,
    });
    const run_tui_tests = b.addRunArtifact(tui_tests);

    const report_pipeline_tests = b.addTest(.{
        .root_module = report_pipeline_mod,
    });
    const run_report_pipeline_tests = b.addRunArtifact(report_pipeline_tests);

    const test_step = b.step("test", "Run library, analysis, benchmark, report-pipeline, main-entry, simulator CLI, and TUI tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_internal_tests.step);
    test_step.dependOn(&run_analysis_tests.step);
    test_step.dependOn(&run_bench_tests.step);
    test_step.dependOn(&run_report_pipeline_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_sim_exe_tests.step);
    test_step.dependOn(&run_tui_tests.step);
}
