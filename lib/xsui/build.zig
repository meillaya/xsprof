//! xsui package build. Exports the target-neutral `xsui` module plus the
//! native backend modules that the host surfaces can opt into.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const freestanding = target.result.cpu.arch == .wasm32 or target.result.os.tag == .freestanding;

    const fonts = b.createModule(.{
        .root_source_file = b.path("assets/fonts/fonts.zig"),
        .target = target,
        .optimize = optimize,
    });

    const xsui = b.addModule("xsui", .{
        .root_source_file = b.path("src/xsui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fonts", .module = fonts },
        },
    });

    var metal: ?*std.Build.Module = null;
    if (target.result.os.tag == .macos) {
        const objc = b.addModule("xsui-objc", .{
            .root_source_file = b.path("src/native/objc.zig"),
            .target = target,
            .optimize = optimize,
        });
        const metal_mod = b.addModule("xsui-metal", .{
            .root_source_file = b.path("src/gpu/metal.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "xsui", .module = xsui },
                .{ .name = "xsui-objc", .module = objc },
            },
        });
        metal_mod.linkFramework("Metal", .{});
        metal_mod.linkFramework("QuartzCore", .{});
        metal = metal_mod;
    }

    var gl: ?*std.Build.Module = null;
    if (target.result.os.tag == .linux) {
        gl = b.addModule("xsui-gl", .{
            .root_source_file = b.path("src/gpu/gl.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "xsui", .module = xsui },
            },
        });
    }

    // The package build is also configured for wasm by xsprof. Only native
    // targets get runnable test/example steps.
    if (freestanding) return;

    const test_step = b.step("test", "Run xsui unit tests");
    const core_tests = b.addTest(.{ .root_module = xsui });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    if (metal) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    if (gl) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/snapshot.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xsui", .module = xsui },
        },
    });
    const example = b.addExecutable(.{ .name = "xsui-snapshot", .root_module = example_mod });
    const run_example = b.addRunArtifact(example);
    run_example.addPassthruArgs();
    const example_step = b.step("example", "Render a PNG through the public xsui API");
    example_step.dependOn(&run_example.step);
}
