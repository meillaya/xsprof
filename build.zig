const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fonts_mod = b.addModule("fonts", .{
        .root_source_file = b.path("assets/fonts/fonts.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_mod = b.addModule("xsprof", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fonts", .module = fonts_mod },
        },
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
    if (target.result.os.tag == .macos) {
        // Cross-building a universal app needs the macOS SDK framework path;
        // native builds already resolve it through the host sysroot.
        if (b.option([]const u8, "macos-sdk", "macOS SDK path for cross builds")) |sdk| {
            const frameworks = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
            const sdk_libs = b.pathJoin(&.{ sdk, "usr", "lib" });
            exe_mod.addFrameworkPath(.{ .cwd_relative = frameworks });
            core_mod.addFrameworkPath(.{ .cwd_relative = frameworks });
            exe_mod.addLibraryPath(.{ .cwd_relative = sdk_libs });
            core_mod.addLibraryPath(.{ .cwd_relative = sdk_libs });
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

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

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

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const web_fonts_mod = b.createModule(.{
        .root_source_file = b.path("assets/fonts/fonts.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const web_mod = b.createModule(.{
        .root_source_file = b.path("src/web.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fonts", .module = web_fonts_mod },
        },
    });
    web_mod.export_symbol_names = &.{
        "web_init",                "web_resize",              "web_alloc",
        "web_free",                "web_load_journal",        "web_set_screen",
        "web_set_theme",           "web_frame",               "web_instances_ptr",
        "web_instance_stride",     "web_atlas_ptr",           "web_atlas_size",
        "web_width",               "web_height",              "web_refusals",
        "web_capabilities",        "web_append_journal",      "web_set_live",
        "web_atlas_version",       "web_pointer",             "web_key",
        "web_set_paused",          "web_set_follow",          "web_run_scenario",
        "web_scenario_result_ptr", "web_scenario_result_len", "web_generate_trace",
        "web_trace_result_ptr",    "web_trace_result_len",    "web_load_compare",
        "web_clear_compare",
    };
    const web_exe = b.addExecutable(.{ .name = "xsprof-web", .root_module = web_mod });
    web_exe.entry = .disabled;
    const web_step = b.step("web", "Build the WebAssembly frontend into zig-out/web");
    const wasm_install = b.addInstallFile(web_exe.getEmittedBin(), "web/assets/xsprof-web.wasm");
    web_step.dependOn(&wasm_install.step);
    const web_assets = [_][]const u8{ "index.html", "main.js", "gl.js", "style.css", "shaders/ui.vert.glsl", "shaders/ui.frag.glsl" };
    inline for (web_assets) |asset| {
        const install = b.addInstallFile(b.path("web/" ++ asset), "web/" ++ asset);
        web_step.dependOn(&install.step);
    }
    inline for ([_][]const u8{ "healthy.json", "loss.json", "empty.json", "scheduler-mix.json" }) |name| {
        const install = b.addInstallFile(b.path("scenarios/" ++ name), "web/scenarios/" ++ name);
        web_step.dependOn(&install.step);
    }

    const web_smoke = b.addSystemCommand(&.{ "sh", "qa/web_smoke.sh" });
    web_smoke.step.dependOn(b.getInstallStep());
    web_smoke.step.dependOn(web_step);
    const web_smoke_step = b.step("web-smoke", "Optional loopback web bridge smoke test");
    web_smoke_step.dependOn(&web_smoke.step);

    const check = b.step("check", "Full local gate: fmt, lines, vendor, tests");
    check.dependOn(&fmt.step);
    check.dependOn(&lines.step);
    check.dependOn(&vendor.step);
    check.dependOn(&cli_parity.step);
    check.dependOn(web_step);
    check.dependOn(&run_mod_tests.step);
    check.dependOn(&run_exe_tests.step);
    check.dependOn(&run_fuzz_tests.step);
    if (target.result.os.tag == .linux) {
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
