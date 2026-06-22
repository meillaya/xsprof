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
    const desktop_assets_mod = addModule(b, "desktop_assets", b.path("web/live-vm-lab/desktop_assets.zig"), target, &.{});
    const live_vm_desktop_exe = addExecutable(b, "zig-scheduler-live-vm-desktop", b.path("src/desktop/main.zig"), target, optimize, &.{
        .{ .name = "desktop_assets", .module = desktop_assets_mod },
        .{ .name = "linux_scheduler", .module = root_mod },
    });
    const desktop_tests_mod = addModule(b, "desktop_tests", b.path("src/desktop/root_tests.zig"), target, &.{
        .{ .name = "desktop_assets", .module = desktop_assets_mod },
        .{ .name = "linux_scheduler", .module = root_mod },
    });

    for ([_]*Compile{ exe, preflight_exe, tui_exe, daemon_exe, live_vm_desktop_exe }) |artifact| {
        b.installArtifact(artifact);
    }

    addRunStep(b, exe, "run", "Run fail-closed Linux scheduler operator CLI", .{});
    addRunStep(b, preflight_exe, "linux-preflight", "Read-only Linux scheduler host preflight", .{});
    addRunStep(b, tui_exe, "tui", "Render the Linux scheduler operator TUI", .{});
    addTuiLiveVmStep(b, tui_exe, daemon_exe);
    addLiveVmWebStep(b, daemon_exe);
    addDesktopWebviewProbeStep(b, target, optimize);
    const webview_host_step = addLinuxWebviewHostStep(b);
    addLiveVmDesktopStep(b, live_vm_desktop_exe, webview_host_step);
    addRunStep(b, daemon_exe, "daemon", "Run disabled-safe foreground scheduler daemon", .{});
    const tui_pty_step = addTuiPtyStep(b, tui_exe, daemon_exe);
    const daemon_stdio_step = addDaemonStdioStep(b, daemon_exe);
    const live_controller_timeout_step = addLiveControllerTimeoutStep(b, live_vm_desktop_exe);
    addBpfStep(b);
    addPackageStep(b);

    const test_step = b.step("test", "Run root Linux scheduler safety and TUI tests");
    for ([_]*Module{ root_mod, tui_mod, exe.root_module, preflight_exe.root_module, tui_exe.root_module, live_vm_desktop_exe.root_module, desktop_tests_mod }) |module| {
        addTestDependency(b, test_step, module);
    }
    test_step.dependOn(tui_pty_step);
    test_step.dependOn(daemon_stdio_step);
    test_step.dependOn(live_controller_timeout_step);
}

fn addLinuxWebviewHostStep(b: *Build) *Build.Step {
    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/bin" });
    const compile = b.addSystemCommand(&.{ "bash", "-c" });
    compile.addArg("cc src/desktop/linux_webview_host.c src/desktop/linux_webview_host_support.c -o zig-out/bin/zig-scheduler-live-vm-webview-host $(pkg-config --cflags --libs webkit2gtk-4.1 gtk+-3.0)");
    compile.step.dependOn(&mkdir.step);

    const host_step = b.step("desktop-webview-host", "Build the Linux WebKitGTK host process used by live-vm-desktop");
    host_step.dependOn(&compile.step);
    return host_step;
}

fn addLiveControllerTimeoutStep(b: *Build, live_vm_desktop_exe: *Compile) *Build.Step {
    const timeout_test = b.addSystemCommand(&.{"python3"});
    timeout_test.addFileArg(b.path("tools/live_controller_timeout_test.py"));
    timeout_test.addArtifactArg(live_vm_desktop_exe);

    const timeout_step = b.step("live-controller-timeout", "Prove desktop controller timeout terminates a hung daemon process");
    timeout_step.dependOn(&timeout_test.step);
    return timeout_step;
}

fn addLiveVmDesktopStep(b: *Build, live_vm_desktop_exe: *Compile, webview_host_step: *Build.Step) void {
    const run_cmd = b.addRunArtifact(live_vm_desktop_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(webview_host_step);
    if (b.args) |args| run_cmd.addArgs(args);

    const desktop_step = b.step(
        "live-vm-desktop",
        "Run the VM-lab-only live microVM desktop WebView shell",
    );
    desktop_step.dependOn(&run_cmd.step);
}

fn addDesktopWebviewProbeStep(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) void {
    const probe_exe = addExecutable(b, "zig-scheduler-desktop-webview-probe", b.path("src/desktop/webview_probe.zig"), target, optimize, &.{});
    const probe_run = b.addRunArtifact(probe_exe);

    const probe_step = b.step(
        "desktop-webview-probe",
        "Probe system WebKitGTK dependencies for the live VM desktop host",
    );
    probe_step.dependOn(&probe_run.step);
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

fn addLiveVmWebStep(b: *Build, daemon_exe: *Compile) void {
    const web_cmd = b.addSystemCommand(&.{"python3"});
    web_cmd.addFileArg(b.path("tools/live_vm_web_server.py"));
    web_cmd.addArg("--daemon-bin");
    web_cmd.addArtifactArg(daemon_exe);
    web_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| web_cmd.addArgs(args);

    const web_step = b.step(
        "live-vm-web",
        "Serve the authoritative browser UI for the VM-gated live microVM lab",
    );
    web_step.dependOn(&web_cmd.step);
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
