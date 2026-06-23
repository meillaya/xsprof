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

    const exe = addExecutable(b, "zig-scheduler", b.path("src/main.zig"), target, optimize, &.{
        .{ .name = "linux_scheduler", .module = root_mod },
    });
    const preflight_exe = addExecutable(b, "zig-scheduler-linux-preflight", b.path("src/preflight_main.zig"), target, optimize, &.{
        .{ .name = "linux_scheduler", .module = root_mod },
    });
    const daemon_exe = addExecutable(b, "zig-scheduler-daemon", b.path("src/daemon_main.zig"), target, optimize, &.{
        .{ .name = "linux_scheduler", .module = root_mod },
    });

    for ([_]*Compile{ exe, preflight_exe, daemon_exe }) |artifact| {
        b.installArtifact(artifact);
    }

    addRunStep(b, exe, "run", "Run fail-closed Linux scheduler operator CLI", .{});
    addRunStep(b, preflight_exe, "linux-preflight", "Read-only Linux scheduler host preflight", .{});
    addRunStep(b, daemon_exe, "daemon", "Run disabled-safe foreground scheduler daemon", .{});
    const daemon_stdio_step = addDaemonStdioStep(b, daemon_exe);
    const daemon_socket_rpc_step = addDaemonSocketRpcStep(b, daemon_exe);
    const client_contract_step = addClientContractStep(b);
    addBpfStep(b);
    addVmLabBackendStep(b);
    addPackageStep(b);

    const test_step = b.step("test", "Run root Linux scheduler safety tests");
    for ([_]*Module{ root_mod, exe.root_module, preflight_exe.root_module, daemon_exe.root_module }) |module| {
        addTestDependency(b, test_step, module);
    }
    test_step.dependOn(daemon_stdio_step);
    test_step.dependOn(daemon_socket_rpc_step);
    test_step.dependOn(client_contract_step);
}

fn addDaemonStdioStep(b: *Build, daemon_exe: *Compile) *Build.Step {
    const daemon_stdio_test = b.addSystemCommand(&.{"bash"});
    daemon_stdio_test.addFileArg(b.path("tools/daemon_stdio_test.sh"));
    daemon_stdio_test.addArtifactArg(daemon_exe);
    if (b.args) |args| {
        daemon_stdio_test.addArgs(args);
    }
    daemon_stdio_test.step.dependOn(b.getInstallStep());

    const daemon_stdio_step = b.step("daemon-stdio", "Run foreground daemon stdin/stdout smoke test");
    daemon_stdio_step.dependOn(&daemon_stdio_test.step);
    return daemon_stdio_step;
}

fn addDaemonSocketRpcStep(b: *Build, daemon_exe: *Compile) *Build.Step {
    const daemon_socket_rpc_test = b.addSystemCommand(&.{"python3"});
    daemon_socket_rpc_test.addFileArg(b.path("tools/daemon_socket_rpc_test.py"));
    daemon_socket_rpc_test.addArtifactArg(daemon_exe);
    daemon_socket_rpc_test.step.dependOn(b.getInstallStep());

    const daemon_socket_rpc_step = b.step("daemon-socket-rpc", "Run local socket JSON-RPC daemon contract test");
    daemon_socket_rpc_step.dependOn(&daemon_socket_rpc_test.step);
    return daemon_socket_rpc_step;
}

fn addClientContractStep(b: *Build) *Build.Step {
    const contract_check = b.addSystemCommand(&.{"python3"});
    contract_check.addFileArg(b.path("qa/frontend_contract_pack_check.py"));
    contract_check.addArgs(&.{
        "--fixtures",
        "fixtures/frontend-contract",
        "--schemas",
        "schemas/control",
        "--docs",
        "docs/control",
    });

    const contract_step = b.step("client-contract", "Run backend client contract fixture pack check");
    contract_step.dependOn(&contract_check.step);
    return contract_step;
}

fn addBpfStep(b: *Build) void {
    const bpf_build = b.addSystemCommand(&.{"bash"});
    bpf_build.has_side_effects = true;
    bpf_build.addFileArg(b.path("tools/build_bpf.sh"));

    const bpf_step = b.step("bpf", "Build sched_ext BPF object skeleton or record explicit SKIP");
    bpf_step.dependOn(&bpf_build.step);
}

fn addVmLabBackendStep(b: *Build) void {
    const vm_lab_backend = b.addSystemCommand(&.{"bash"});
    vm_lab_backend.has_side_effects = true;
    vm_lab_backend.addFileArg(b.path("qa/vm/vm_lab_backend.sh"));
    if (b.args) |args| {
        vm_lab_backend.addArgs(args);
    }

    const vm_lab_backend_step = b.step("vm-lab-backend", "Run fail-closed disposable VM backend lab harness");
    vm_lab_backend_step.dependOn(&vm_lab_backend.step);
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
