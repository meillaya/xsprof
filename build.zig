const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.addModule("xsprof", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xsprof", .module = core_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = "xsprof",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run xsprof");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = core_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("build.zig"),
            b.path("build.zig.zon"),
            b.path("src"),
            b.path("tests"),
            b.path("tools"),
        },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check Zig formatting");
    fmt_step.dependOn(&fmt.step);

    const lines = b.addSystemCommand(&.{ "sh", "qa/lines.sh" });
    const lines_step = b.step("lines", "Enforce the 600-line source limit");
    lines_step.dependOn(&lines.step);

    const vendor = b.addSystemCommand(&.{ "sh", "qa/vendor_hash.sh" });
    const vendor_step = b.step("vendor-check", "Verify vendored Zig 0.17 hashes");
    vendor_step.dependOn(&vendor.step);

    const cli_parity = b.addSystemCommand(&.{ "sh", "qa/cli_parity.sh" });
    cli_parity.step.dependOn(b.getInstallStep());
    const cli_parity_step = b.step("cli-parity", "Check read-only CLI behavior end to end");
    cli_parity_step.dependOn(&cli_parity.step);

    const check = b.step("check", "Full local gate: fmt, lines, vendor, tests");
    check.dependOn(&fmt.step);
    check.dependOn(&lines.step);
    check.dependOn(&vendor.step);
    check.dependOn(&cli_parity.step);
    check.dependOn(&run_mod_tests.step);
    check.dependOn(&run_exe_tests.step);
}
