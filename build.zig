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

    const root_mod = addModule(b, "linux_scheduler", b.path("src/root.zig"), target, &.{});
    const tui_mod = addModule(b, "linux_scheduler_tui", b.path("src/tui/root.zig"), target, &.{
        .{ .name = "linux_scheduler", .module = root_mod },
    });

    const exe = addExecutable(b, "zig-scheduler", b.path("src/main.zig"), target, optimize, &.{
        .{ .name = "linux_scheduler", .module = root_mod },
    });
    const preflight_exe = addExecutable(b, "zig-scheduler-linux-preflight", b.path("src/preflight_main.zig"), target, optimize, &.{
        .{ .name = "linux_scheduler", .module = root_mod },
    });
    const tui_exe = addExecutable(b, "zig-scheduler-tui", b.path("src/tui/main.zig"), target, optimize, &.{
        .{ .name = "linux_scheduler_tui", .module = tui_mod },
    });

    for ([_]*Compile{ exe, preflight_exe, tui_exe }) |artifact| {
        b.installArtifact(artifact);
    }

    addRunStep(b, exe, "run", "Run fail-closed Linux scheduler operator CLI", .{});
    addRunStep(b, preflight_exe, "linux-preflight", "Read-only Linux scheduler host preflight", .{});
    addRunStep(b, tui_exe, "tui", "Render the Linux scheduler operator TUI", .{});

    const test_step = b.step("test", "Run root Linux scheduler safety and TUI tests");
    for ([_]*Module{ root_mod, tui_mod, exe.root_module, preflight_exe.root_module, tui_exe.root_module }) |module| {
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
    const module_tests = b.addTest(.{ .root_module = module });
    const run_module_tests = b.addRunArtifact(module_tests);
    test_step.dependOn(&run_module_tests.step);
}
