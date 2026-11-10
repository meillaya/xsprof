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

    // Schema-conformance root: validates committed schemas and wire samples.
    const schema_core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/schema.zig"),
        .target = target,
        .optimize = optimize,
    });
    const schema_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/schema.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xsprof-schema", .module = schema_core_mod },
        },
    });
    const schema_tests = b.addTest(.{ .root_module = schema_test_mod });
    const run_schema_tests = b.addRunArtifact(schema_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_xsui_api_tests.step);
    test_step.dependOn(&run_schema_tests.step);

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
    const lines_step = b.step("lines", "Enforce the source responsibility limit");
    lines_step.dependOn(&lines.step);

    const version_sync = b.addSystemCommand(&.{ "sh", "qa/version_sync.sh" });
    const version_sync_step = b.step("version-sync", "Check package/runtime/docs version lockstep");
    version_sync_step.dependOn(&version_sync.step);

    const script_syntax = b.addSystemCommand(&.{ "sh", "qa/script_syntax.sh" });
    const script_syntax_step = b.step("script-syntax", "Syntax-check every tracked shell script");
    script_syntax_step.dependOn(&script_syntax.step);

    const design_check = b.addSystemCommand(&.{ "python3", "design/validate.py" });
    const design_check_step = b.step("design-check", "Validate the design token/spec contract");
    design_check_step.dependOn(&design_check.step);

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

    const cli_manifest = b.addSystemCommand(&.{ "sh", "-c", "zig-out/bin/xsprof help --json --all --check" });
    cli_manifest.step.dependOn(b.getInstallStep());
    const cli_manifest_step = b.step("cli-manifest", "Check the committed CLI manifest is current");
    cli_manifest_step.dependOn(&cli_manifest.step);

    const perf_smoke = b.addSystemCommand(&.{ "sh", "qa/perf_smoke.sh" });
    perf_smoke.step.dependOn(b.getInstallStep());
    const perf_smoke_step = b.step("perf-smoke", "Bounded hot-path performance floor");
    perf_smoke_step.dependOn(&perf_smoke.step);

    const quickstart_smoke = b.addSystemCommand(&.{ "sh", "qa/quickstart_smoke.sh" });
    quickstart_smoke.step.dependOn(b.getInstallStep());
    const quickstart_smoke_step = b.step("quickstart-smoke", "Headless first-run workflow smoke");
    quickstart_smoke_step.dependOn(&quickstart_smoke.step);

    const compact_roundtrip = b.addSystemCommand(&.{ "sh", "qa/compact_roundtrip.sh" });
    compact_roundtrip.step.dependOn(b.getInstallStep());
    const compact_roundtrip_step = b.step("compact-roundtrip", "Compact .xsraw decode/verify gate");
    compact_roundtrip_step.dependOn(&compact_roundtrip.step);

    const a11y_smoke = b.addSystemCommand(&.{ "sh", "qa/a11y_smoke.sh" });
    a11y_smoke.step.dependOn(b.getInstallStep());
    const a11y_smoke_step = b.step("a11y-smoke", "Deterministic accessibility tree gate");
    a11y_smoke_step.dependOn(&a11y_smoke.step);

    const xsui_package = b.addSystemCommand(&.{ "sh", "qa/xsui_package.sh" });
    const xsui_package_step = b.step("xsui-package", "Test the standalone xsui package");
    xsui_package_step.dependOn(&xsui_package.step);

    // Standalone developer gates. They are promoted into `check-ci` only once
    // the repo diet has landed (they intentionally fail on the pre-diet tree).
    const repo_size = b.addSystemCommand(&.{ "sh", "qa/repo_size.sh" });
    const repo_size_step = b.step("repo-size", "Enforce tracked-file and repository size budgets");
    repo_size_step.dependOn(&repo_size.step);

    const docs_links = b.addSystemCommand(&.{ "sh", "qa/docs_links.sh" });
    const docs_links_step = b.step("docs-links", "Check relative links in tracked markdown");
    docs_links_step.dependOn(&docs_links.step);

    // Platform/media gates: they need a display server, ffmpeg, or python3 and
    // therefore never run as part of the fast `check` gate.
    var platform_steps = std.ArrayList(*std.Build.Step).empty;
    defer platform_steps.deinit(b.allocator);

    const screenshots_check = b.addSystemCommand(&.{ "sh", "tools/screenshots.sh", "--check" });
    screenshots_check.step.dependOn(b.getInstallStep());
    const screenshots_check_step = b.step("screenshots-check", "Re-render committed stills and verify bytes/provenance");
    screenshots_check_step.dependOn(&screenshots_check.step);

    if (target.result.os.tag == .linux) {
        const xvfb_smoke = b.addSystemCommand(&.{ "sh", "qa/xvfb_smoke.sh" });
        xvfb_smoke.step.dependOn(b.getInstallStep());
        const xvfb_smoke_step = b.step("xvfb-smoke", "Hidden X11/GLX native smoke under Xvfb when available");
        xvfb_smoke_step.dependOn(&xvfb_smoke.step);
        platform_steps.append(b.allocator, &xvfb_smoke.step) catch @panic("OOM");

        const native_live = b.addSystemCommand(&.{ "sh", "qa/native_live_smoke.sh" });
        native_live.step.dependOn(b.getInstallStep());
        const native_live_step = b.step("native-live-smoke", "Hidden live/recorder-tail smoke under Xvfb when available");
        native_live_step.dependOn(&native_live.step);
        platform_steps.append(b.allocator, &native_live.step) catch @panic("OOM");

        const live_smoke = b.addSystemCommand(&.{ "sh", "qa/live_smoke.sh" });
        live_smoke.step.dependOn(b.getInstallStep());
        const live_smoke_step = b.step("live-smoke", "Root perf/daemon gate for a disposable Linux VM");
        live_smoke_step.dependOn(&live_smoke.step);

        const service_smoke = b.addSystemCommand(&.{ "sh", "qa/service_smoke.sh" });
        service_smoke.step.dependOn(b.getInstallStep());
        const service_step = b.step("service-smoke", "Root systemd smoke on a disposable Linux VM");
        service_step.dependOn(&service_smoke.step);

        const retention_bench = b.addSystemCommand(&.{ "sh", "qa/retention_bench.sh", "600000", "0", "2G", "yes" });
        retention_bench.step.dependOn(b.getInstallStep());
        const retention_bench_step = b.step("retention-bench", "Root retention budget gate for a disposable Linux VM");
        retention_bench_step.dependOn(&retention_bench.step);

        const check_vm = b.step("check-vm", "Root-only live/service/retention gate (disposable Linux VM)");
        check_vm.dependOn(&live_smoke.step);
        check_vm.dependOn(&service_smoke.step);
        check_vm.dependOn(&retention_bench.step);
    }
    if (target.result.os.tag == .macos) {
        // The viewer is an optional frozen surface on macOS (no capture). The
        // normal `check`/`check-ci` test roots compile the AppKit/Metal paths;
        // there is no hidden-window smoke lane any more.
    }

    const check_platform = b.step("check-platform", "Platform smokes (display server)");
    for (platform_steps.items) |step| check_platform.dependOn(step);

    const check_media = b.step("check-media", "Screenshot determinism/provenance gates");
    check_media.dependOn(&screenshots_check.step);

    // Fast, tool-light gate: safe to run on any developer host. No display
    // server, Python, ffmpeg, or privileged access is expected here.
    const check = b.step("check", "Fast local gate: format, limits, contracts, tests");
    check.dependOn(&fmt.step);
    check.dependOn(&lines.step);
    check.dependOn(&version_sync.step);
    check.dependOn(&script_syntax.step);
    check.dependOn(&privacy_scan.step);
    check.dependOn(&no_mutation.step);
    check.dependOn(&unsafe_matrix.step);
    check.dependOn(&cli_parity.step);
    check.dependOn(&cli_manifest.step);
    check.dependOn(&quickstart_smoke.step);
    check.dependOn(&compact_roundtrip.step);
    check.dependOn(&a11y_smoke.step);
    check.dependOn(&xsui_package.step);
    check.dependOn(&run_mod_tests.step);
    check.dependOn(&run_exe_tests.step);
    check.dependOn(&run_xsui_api_tests.step);
    check.dependOn(&run_schema_tests.step);
    check.dependOn(&run_fuzz_tests.step);

    // CI gate: every declared tool must be present; a SKIP is a failure.
    const check_ci = b.step("check-ci", "Full CI gate: fast + platform/media, no silent SKIPs");
    check_ci.dependOn(check);
    check_ci.dependOn(check_platform);
    check_ci.dependOn(check_media);
    check_ci.dependOn(&repo_size.step);
    check_ci.dependOn(&docs_links.step);
    check_ci.dependOn(&design_check.step);
    check_ci.dependOn(&perf_smoke.step);
    if (target.result.os.tag == .linux) {
        const strict_xvfb = requireTools(b, &.{ "sh", "qa/xvfb_smoke.sh" });
        strict_xvfb.step.dependOn(b.getInstallStep());
        const strict_native_live = requireTools(b, &.{ "sh", "qa/native_live_smoke.sh" });
        strict_native_live.step.dependOn(b.getInstallStep());
        check_ci.dependOn(&strict_xvfb.step);
        check_ci.dependOn(&strict_native_live.step);
    }
    const strict_a11y = requireTools(b, &.{ "sh", "qa/a11y_smoke.sh" });
    strict_a11y.step.dependOn(b.getInstallStep());
    check_ci.dependOn(&strict_a11y.step);
    check_ci.dependOn(&screenshots_check.step);
}

/// Mark a script as CI-strict: declared external tools must exist instead of
/// silently degrading the gate to a SKIP.
fn requireTools(b: *std.Build, argv: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(argv);
    run.setEnvironmentVariable("XSPROF_REQUIRE_TOOLS", "1");
    return run;
}
