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
    const daemon_exe = addExecutable(b, "zig-scheduler-daemon", b.path("src/daemon_main.zig"), target, optimize, &.{
        .{ .name = "linux_scheduler", .module = root_mod },
    });

    for ([_]*Compile{ exe, preflight_exe, tui_exe, daemon_exe }) |artifact| {
        b.installArtifact(artifact);
    }

    addRunStep(b, exe, "run", "Run fail-closed Linux scheduler operator CLI", .{});
    addRunStep(b, preflight_exe, "linux-preflight", "Read-only Linux scheduler host preflight", .{});
    addRunStep(b, tui_exe, "tui", "Render the Linux scheduler operator TUI", .{});
    addTuiLiveVmStep(b, tui_exe, daemon_exe);
    addRunStep(b, daemon_exe, "daemon", "Run disabled-safe foreground scheduler daemon", .{});
    const tui_pty_step = addTuiPtyStep(b, tui_exe, daemon_exe);
    const daemon_stdio_step = addDaemonStdioStep(b, daemon_exe);
    addBpfStep(b);
    addPackageStep(b);

    const test_step = b.step("test", "Run root Linux scheduler safety and TUI tests");
    for ([_]*Module{ root_mod, tui_mod, exe.root_module, preflight_exe.root_module, tui_exe.root_module }) |module| {
        addTestDependency(b, test_step, module);
    }
    test_step.dependOn(tui_pty_step);
    test_step.dependOn(daemon_stdio_step);
}

fn addDaemonStdioStep(b: *Build, daemon_exe: *Compile) *Build.Step {
    const daemon_stdio_test = b.addSystemCommand(&.{"bash"});
    daemon_stdio_test.addFileArg(b.path("tools/daemon_stdio_test.sh"));
    daemon_stdio_test.addArtifactArg(daemon_exe);

    const daemon_stdio_step = b.step("daemon-stdio", "Run foreground daemon stdin/stdout smoke test");
    daemon_stdio_step.dependOn(&daemon_stdio_test.step);
    return daemon_stdio_step;
}

fn addBpfStep(b: *Build) void {
    const bpf_build = b.addSystemCommand(&.{"bash"});
    bpf_build.addFileArg(b.path("tools/build_bpf.sh"));

    const bpf_step = b.step("bpf", "Build sched_ext BPF object skeleton or record explicit SKIP");
    bpf_step.dependOn(&bpf_build.step);
}

fn addPackageStep(b: *Build) void {
    const package_build = b.addSystemCommand(&.{"bash"});
    package_build.addFileArg(b.path("packaging/build_package.sh"));
    package_build.addArg("--out");
    package_build.addArg("zig-out/package");
    package_build.step.dependOn(b.getInstallStep());

    const package_step = b.step("package", "Stage a safe installable package artifact manifest");
    package_step.dependOn(&package_build.step);
}

fn addTuiPtyStep(b: *Build, tui_exe: *Compile, daemon_exe: *Compile) *Build.Step {
    const tui_pty_exit_test = b.addSystemCommand(&.{"python3"});
    tui_pty_exit_test.addFileArg(b.path("tools/tui_pty_exit_test.py"));
    tui_pty_exit_test.addArtifactArg(tui_exe);
    tui_pty_exit_test.addArtifactArg(daemon_exe);

    const tui_pty_step = b.step("tui-pty", "Run root TUI PTY snapshot smoke test");
    tui_pty_step.dependOn(&tui_pty_exit_test.step);
    return tui_pty_step;
}

fn addTuiLiveVmStep(b: *Build, tui_exe: *Compile, daemon_exe: *Compile) void {
    const run_cmd = b.addRunArtifact(tui_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    } else {
        run_cmd.addArgs(&.{
            "--interactive",
            "--screen",
            "vm-lab",
            "--daemon-state-dir",
            ".omo/evidence/tui-live-vm",
            "--daemon-bin",
        });
        run_cmd.addArtifactArg(daemon_exe);
    }

    const run_step = b.step(
        "tui-live-vm",
        "Run fail-closed, VM-gated live microVM lab TUI (press m/b/s inside TUI)",
    );
    run_step.dependOn(&run_cmd.step);
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
