const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("zig_scheduler", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const contract_mod = b.addModule("zig_scheduler_report_contract", .{
        .root_source_file = b.path("src/contract/report.zig"),
        .target = target,
    });

    const analysis_mod = b.addModule("zig_scheduler_analysis", .{
        .root_source_file = b.path("src/analysis/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "report_contract", .module = contract_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zig-scheduler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
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

    b.installArtifact(exe);
    b.installArtifact(analysis_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Phase 1 simulator scaffold");
    run_step.dependOn(&run_cmd.step);

    const analyze_cmd = b.addRunArtifact(analysis_exe);
    analyze_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        analyze_cmd.addArgs(args);
    }

    const analyze_step = b.step("analyze", "Analyze exported zig-scheduler/report JSON");
    analyze_step.dependOn(&analyze_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const analysis_tests = b.addTest(.{
        .root_module = analysis_mod,
    });
    const run_analysis_tests = b.addRunArtifact(analysis_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run library, analysis, and CLI tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_analysis_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
