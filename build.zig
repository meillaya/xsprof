const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xsui_dep = b.dependency("xsui", .{ .target = target, .optimize = optimize });
    const xsui_mod = xsui_dep.module("xsui");
    const metal_mod = if (target.result.os.tag == .macos) xsui_dep.module("xsui-metal") else null;
    const objc_mod = if (target.result.os.tag == .macos) xsui_dep.module("xsui-objc") else null;
    const gl_mod = if (target.result.os.tag == .linux) xsui_dep.module("xsui-gl") else null;

    const core_mod = b.addModule("xsprof", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xsui", .module = xsui_mod },
        },
    });
    if (metal_mod) |module| core_mod.addImport("xsui-metal", module);
    if (objc_mod) |module| core_mod.addImport("xsui-objc", module);
    if (gl_mod) |module| core_mod.addImport("xsui-gl", module);

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
    if (target.result.os.tag == .macos) {
        // Cross-building a universal app needs the macOS SDK framework path;
        // native builds already resolve it through the host sysroot.
        if (b.option([]const u8, "macos-sdk", "macOS SDK path for cross builds")) |sdk| {
            const frameworks = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
            const sdk_libs = b.pathJoin(&.{ sdk, "usr", "lib" });
            for ([_]*std.Build.Module{ exe_mod, core_mod, xsui_mod }) |module| {
                module.addFrameworkPath(.{ .cwd_relative = frameworks });
                module.addLibraryPath(.{ .cwd_relative = sdk_libs });
            }
            for ([_]*std.Build.Module{ metal_mod.?, objc_mod.? }) |module| {
                module.addFrameworkPath(.{ .cwd_relative = frameworks });
                module.addLibraryPath(.{ .cwd_relative = sdk_libs });
            }
        }
        for ([_][]const u8{ "AppKit", "Metal", "QuartzCore" }) |framework| {
            exe_mod.linkFramework(framework, .{});
            core_mod.linkFramework(framework, .{});
        }
    }
    if (target.result.os.tag == .linux) {
        exe_mod.link_libc = true;
        core_mod.link_libc = true;
    }
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

    const xsui_api_mod = b.createModule(.{
        .root_source_file = b.path("tests/xsui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xsui", .module = xsui_mod },
        },
    });
    const xsui_api_tests = b.addTest(.{ .root_module = xsui_api_mod });
    const run_xsui_api_tests = b.addRunArtifact(xsui_api_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_xsui_api_tests.step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xsprof", .module = core_mod },
        },
    });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run deterministic parser fuzz tests");
    fuzz_step.dependOn(&run_fuzz_tests.step);

    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("build.zig"),
            b.path("build.zig.zon"),
            b.path("src"),
            b.path("lib/xsui/build.zig"),
            b.path("lib/xsui/build.zig.zon"),
            b.path("lib/xsui/src"),
            b.path("lib/xsui/examples"),
            b.path("lib/xsui/assets/fonts/fonts.zig"),
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

    const version_sync = b.addSystemCommand(&.{ "sh", "qa/version_sync.sh" });
    const version_sync_step = b.step("version-sync", "Check package/runtime version lockstep");
    version_sync_step.dependOn(&version_sync.step);

    const unsafe_matrix = b.addSystemCommand(&.{ "sh", "qa/unsafe_cli_matrix.sh" });
    unsafe_matrix.step.dependOn(b.getInstallStep());
    const no_mutation = b.addSystemCommand(&.{ "sh", "qa/no_host_mutation.sh" });
    no_mutation.step.dependOn(b.getInstallStep());
    const privacy_scan = b.addSystemCommand(&.{ "sh", "qa/privacy_scan.sh" });
    privacy_scan.step.dependOn(b.getInstallStep());

    const cli_parity = b.addSystemCommand(&.{ "sh", "qa/cli_parity.sh" });
    cli_parity.step.dependOn(b.getInstallStep());
    const cli_parity_step = b.step("cli-parity", "Check read-only CLI behavior end to end");
    cli_parity_step.dependOn(&cli_parity.step);

    const compact_roundtrip = b.addSystemCommand(&.{ "sh", "qa/compact_roundtrip.sh" });
    compact_roundtrip.step.dependOn(b.getInstallStep());
    const compact_roundtrip_step = b.step("compact-roundtrip", "Compact .xsraw decode/verify gate");
    compact_roundtrip_step.dependOn(&compact_roundtrip.step);

    const showcase_smoke = b.addSystemCommand(&.{ "sh", "qa/showcase_smoke.sh" });
    showcase_smoke.step.dependOn(b.getInstallStep());
    const showcase_smoke_step = b.step("showcase-smoke", "Native showcase media determinism/provenance");
    showcase_smoke_step.dependOn(&showcase_smoke.step);

    const a11y_smoke = b.addSystemCommand(&.{ "sh", "qa/a11y_smoke.sh" });
    a11y_smoke.step.dependOn(b.getInstallStep());
    const a11y_smoke_step = b.step("a11y-smoke", "Deterministic accessibility tree gate");
    a11y_smoke_step.dependOn(&a11y_smoke.step);

    const release_tooling = b.addSystemCommand(&.{ "sh", "qa/release_tooling.sh" });
    const release_tooling_step = b.step("release-tooling", "Release attestation/tap dry-run gate");
    release_tooling_step.dependOn(&release_tooling.step);

    const xsui_package = b.addSystemCommand(&.{ "sh", "qa/xsui_package.sh" });
    const xsui_package_step = b.step("xsui-package", "Test the standalone xsui package");
    xsui_package_step.dependOn(&xsui_package.step);

    const live_smoke = b.addSystemCommand(&.{ "sh", "qa/live_smoke.sh" });
    live_smoke.step.dependOn(b.getInstallStep());
    const live_smoke_step = b.step("live-smoke", "Root perf/daemon gate for a disposable Linux VM");
    live_smoke_step.dependOn(&live_smoke.step);

    const check = b.step("check", "Full local gate: fmt, lines, vendor, tests");
    check.dependOn(&fmt.step);
    check.dependOn(&lines.step);
    check.dependOn(&vendor.step);
    check.dependOn(&version_sync.step);
    check.dependOn(&privacy_scan.step);
    check.dependOn(&no_mutation.step);
    check.dependOn(&unsafe_matrix.step);
    check.dependOn(&cli_parity.step);
    check.dependOn(&compact_roundtrip.step);
    check.dependOn(&a11y_smoke.step);
    check.dependOn(&showcase_smoke.step);
    check.dependOn(&release_tooling.step);
    check.dependOn(&xsui_package.step);
    check.dependOn(&run_mod_tests.step);
    check.dependOn(&run_exe_tests.step);
    check.dependOn(&run_xsui_api_tests.step);
    check.dependOn(&run_fuzz_tests.step);
    if (target.result.os.tag == .linux) {
        const xvfb_smoke = b.addSystemCommand(&.{ "sh", "qa/xvfb_smoke.sh" });
        xvfb_smoke.step.dependOn(b.getInstallStep());
        const xvfb_smoke_step = b.step("xvfb-smoke", "Hidden X11/GLX native smoke under Xvfb when available");
        xvfb_smoke_step.dependOn(&xvfb_smoke.step);
        check.dependOn(&xvfb_smoke.step);

        const native_live = b.addSystemCommand(&.{ "sh", "qa/native_live_smoke.sh" });
        native_live.step.dependOn(b.getInstallStep());
        const native_live_step = b.step("native-live-smoke", "Hidden live/recorder-tail smoke under Xvfb when available");
        native_live_step.dependOn(&native_live.step);
        check.dependOn(&native_live.step);

        const lab_smoke = b.addSystemCommand(&.{ "sh", "qa/lab_smoke.sh" });
        lab_smoke.step.dependOn(b.getInstallStep());
        const lab_smoke_step = b.step("lab-smoke", "Headless GUI lab scenarios and snapshots");
        lab_smoke_step.dependOn(&lab_smoke.step);
        check.dependOn(&lab_smoke.step);

        const service_smoke = b.addSystemCommand(&.{ "sh", "qa/service_smoke.sh" });
        service_smoke.step.dependOn(b.getInstallStep());
        const service_step = b.step("service-smoke", "Root systemd smoke on a disposable Linux VM");
        service_step.dependOn(&service_smoke.step);
    }
    if (target.result.os.tag == .macos) {
        const macos_smoke = b.addSystemCommand(&.{ "sh", "qa/macos_smoke.sh" });
        macos_smoke.step.dependOn(b.getInstallStep());
        const macos_smoke_step = b.step("macos-smoke", "Hidden AppKit/Metal window smoke");
        macos_smoke_step.dependOn(&macos_smoke.step);
        check.dependOn(&macos_smoke.step);
    }
}
