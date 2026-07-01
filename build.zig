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

    const root_mod = b.addModule("linux_scheduler", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const root_imports = &[_]Module.Import{.{ .name = "linux_scheduler", .module = root_mod }};

    const exe = addExecutable(b, "zig-scheduler", b.path("src/main.zig"), target, optimize, root_imports);
    const preflight_exe = addExecutable(b, "zig-scheduler-linux-preflight", b.path("src/preflight_main.zig"), target, optimize, root_imports);
    const daemon_exe = addExecutable(b, "zig-scheduler-daemon", b.path("src/daemon_main.zig"), target, optimize, root_imports);

    for ([_]*Compile{ exe, preflight_exe, daemon_exe }) |artifact| {
        b.installArtifact(artifact);
    }

    addRunStep(b, exe, "run", "Run fail-closed Linux scheduler operator CLI");
    addRunStep(b, preflight_exe, "linux-preflight", "Read-only Linux scheduler host preflight");
    addRunStep(b, daemon_exe, "daemon", "Run disabled-safe foreground scheduler daemon");
    const daemon_stdio_step = addDaemonStdioStep(b, daemon_exe);
    const daemon_socket_rpc_step = addDaemonSocketRpcStep(b, daemon_exe);
    const client_contract_step = addClientContractStep(b, daemon_exe);
    const bpf_step = addBpfStep(b);
    addVmLabBackendStep(b);
    addVmHarnessMatrixStep(b);
    const host_safe_gates_step = addHostSafeGatesStep(b, bpf_step);
    addPackageStep(b);

    const test_step = b.step("test", "Run root Linux scheduler safety tests");
    for ([_]*Module{ root_mod, exe.root_module, preflight_exe.root_module, daemon_exe.root_module }) |module| {
        const module_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(module_tests).step);
    }
    test_step.dependOn(daemon_stdio_step);
    test_step.dependOn(daemon_socket_rpc_step);
    test_step.dependOn(client_contract_step);
    test_step.dependOn(host_safe_gates_step);
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

    const openrpc_contract = b.addSystemCommand(&.{"python3"});
    openrpc_contract.addFileArg(b.path("qa/openrpc_contract_check.py"));
    openrpc_contract.addArgs(&.{
        "--contract",
        "docs/control/daemon-openrpc.json",
        "--daemon",
        "src/daemon_main.zig",
        "--docs",
        "docs/control",
    });

    const openrpc_self_test = b.addSystemCommand(&.{"python3"});
    openrpc_self_test.addFileArg(b.path("qa/openrpc_contract_check.py"));
    openrpc_self_test.addArg("--self-test");

    const daemon_socket_rpc_step = b.step("daemon-socket-rpc", "Run local socket JSON-RPC daemon contract test");
    daemon_socket_rpc_step.dependOn(&daemon_socket_rpc_test.step);
    daemon_socket_rpc_step.dependOn(&openrpc_contract.step);
    daemon_socket_rpc_step.dependOn(&openrpc_self_test.step);
    return daemon_socket_rpc_step;
}

fn addClientContractStep(b: *Build, daemon_exe: *Compile) *Build.Step {
    const matrix_fixture = b.addSystemCommand(&.{"bash"});
    matrix_fixture.has_side_effects = true;
    matrix_fixture.addArgs(&.{
        "-c",
        "rm -rf evidence/lab/matrix/fixture-pass && bash qa/vm/vm_harness_matrix.sh --mode host-safe --scenario fixture-pass --out evidence/lab/matrix/fixture-pass >/dev/null",
    });

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
    contract_check.step.dependOn(&matrix_fixture.step);

    const consumer_contract_check = b.addSystemCommand(&.{"python3"});
    consumer_contract_check.addFileArg(b.path("qa/consumer_contract_check.py"));
    consumer_contract_check.addArgs(&.{
        "--fixtures",
        "fixtures/frontend-contract",
        "--schemas",
        "schemas/control",
        "--docs",
        "docs/control",
    });
    consumer_contract_check.step.dependOn(&matrix_fixture.step);

    const client_pack_self_test = b.addSystemCommand(&.{"python3"});
    client_pack_self_test.addFileArg(b.path("qa/frontend_contract_pack_check.py"));
    client_pack_self_test.addArg("--self-test");

    const consumer_contract_self_test = b.addSystemCommand(&.{"python3"});
    consumer_contract_self_test.addFileArg(b.path("qa/consumer_contract_check.py"));
    consumer_contract_self_test.addArg("--self-test");

    const schema_compatibility_self_test = b.addSystemCommand(&.{"python3"});
    schema_compatibility_self_test.addFileArg(b.path("qa/schema_compatibility_check.py"));
    schema_compatibility_self_test.addArg("--self-test");

    const matrix_fixture_cleanup = b.addSystemCommand(&.{"bash"});
    matrix_fixture_cleanup.has_side_effects = true;
    matrix_fixture_cleanup.addArgs(&.{
        "-c",
        "rm -rf evidence/lab/matrix/fixture-pass; rmdir evidence/lab/matrix 2>/dev/null || true",
    });
    matrix_fixture_cleanup.step.dependOn(&contract_check.step);
    matrix_fixture_cleanup.step.dependOn(&consumer_contract_check.step);

    const matrix_contract_check = b.addSystemCommand(&.{"python3"});
    matrix_contract_check.addFileArg(b.path("qa/matrix_run_contract_check.py"));
    matrix_contract_check.addArgs(&.{
        "--fixtures",
        "fixtures/matrix-run",
        "--schemas",
        "schemas/control",
        "--docs",
        "docs/control",
    });

    const runtime_sample_check = b.addSystemCommand(&.{"python3"});
    runtime_sample_check.addFileArg(b.path("qa/runtime_sample_check.py"));
    runtime_sample_check.addArg("--self-test");

    const benchmark_output_check = b.addSystemCommand(&.{"python3"});
    benchmark_output_check.addFileArg(b.path("qa/benchmark_output_check.py"));
    benchmark_output_check.addArgs(&.{
        "--fixtures",
        "fixtures/benchmark-output",
        "--schema",
        "schemas/control/benchmark-output.v1.schema.json",
    });

    const control_schema_check = b.addSystemCommand(&.{"python3"});
    control_schema_check.addFileArg(b.path("qa/control_schema_drift_check.py"));
    control_schema_check.addArgs(&.{
        "--protocol",
        "src/control/protocol.zig",
        "--schemas",
        "schemas/control",
    });

    const schema_compatibility_check = b.addSystemCommand(&.{"python3"});
    schema_compatibility_check.addFileArg(b.path("qa/schema_compatibility_check.py"));
    schema_compatibility_check.addArgs(&.{
        "--protocol",
        "src/control/protocol.zig",
        "--schemas",
        "schemas/control",
        "--docs",
        "docs/control",
        "--fixtures",
        "fixtures/frontend-contract",
    });

    const daemon_golden_check = b.addSystemCommand(&.{"python3"});
    daemon_golden_check.addFileArg(b.path("qa/daemon_golden_transcript_check.py"));
    daemon_golden_check.addArg("--daemon");
    daemon_golden_check.addArtifactArg(daemon_exe);
    daemon_golden_check.addArgs(&.{
        "--fixtures",
        "fixtures/control/golden",
    });
    daemon_golden_check.step.dependOn(b.getInstallStep());

    const golden_lifecycle_check = b.addSystemCommand(&.{"python3"});
    golden_lifecycle_check.addFileArg(b.path("qa/golden_fixture_lifecycle_check.py"));
    golden_lifecycle_check.addArgs(&.{
        "--docs",
        "docs/control",
        "--control",
        "fixtures/control/golden",
        "--frontend=fixtures/frontend-contract",
    });

    const contract_step = b.step("client-contract", "Run backend client contract fixture pack check");
    contract_step.dependOn(&matrix_fixture_cleanup.step);
    contract_step.dependOn(&client_pack_self_test.step);
    contract_step.dependOn(&consumer_contract_self_test.step);
    contract_step.dependOn(&matrix_contract_check.step);
    contract_step.dependOn(&runtime_sample_check.step);
    contract_step.dependOn(&benchmark_output_check.step);
    contract_step.dependOn(&control_schema_check.step);
    contract_step.dependOn(&schema_compatibility_check.step);
    contract_step.dependOn(&schema_compatibility_self_test.step);
    contract_step.dependOn(&daemon_golden_check.step);
    contract_step.dependOn(&golden_lifecycle_check.step);
    return contract_step;
}

fn addBpfStep(b: *Build) *Build.Step {
    const bpf_build = b.addSystemCommand(&.{"bash"});
    bpf_build.has_side_effects = true;
    bpf_build.addFileArg(b.path("tools/build_bpf.sh"));

    const bpf_repro = b.addSystemCommand(&.{"python3"});
    bpf_repro.has_side_effects = true;
    bpf_repro.addFileArg(b.path("qa/bpf_metadata_repro_check.py"));
    bpf_repro.step.dependOn(&bpf_build.step);

    const bpf_abi = b.addSystemCommand(&.{"python3"});
    bpf_abi.addFileArg(b.path("qa/bpf_abi_freeze_check.py"));
    bpf_abi.addArgs(&.{
        "--header",
        "bpf/include/zigsched_common.h",
        "--strategy",
        "docs/adr/0004-bpf-abi-strategy.md",
        "--metadata",
        "zig-out/bpf/zigsched_minimal.bpf.meta.json",
        "--skip-json",
        "zig-out/bpf/zigsched_minimal.bpf.skip.json",
    });
    bpf_abi.step.dependOn(&bpf_repro.step);

    const bpf_step = b.step("bpf", "Build sched_ext BPF object skeleton or record explicit SKIP");
    bpf_step.dependOn(&bpf_abi.step);
    return bpf_step;
}

fn addHostSafeGatesStep(b: *Build, bpf_step: *Build.Step) *Build.Step {
    const workload_catalog = b.addSystemCommand(&.{"bash"});
    workload_catalog.addFileArg(b.path("qa/vm/workload_catalog_check.sh"));

    const root_ui_absence = b.addSystemCommand(&.{"bash"});
    root_ui_absence.addFileArg(b.path("qa/no_frontend_root.sh"));

    const no_host_mutation = b.addSystemCommand(&.{"bash"});
    no_host_mutation.addFileArg(b.path("qa/no_host_mutation.sh"));

    const release_gate = b.addSystemCommand(&.{"bash"});
    release_gate.has_side_effects = true;
    release_gate.addFileArg(b.path("qa/release_gate.sh"));
    release_gate.addArg("--self-test");

    const wording = b.addSystemCommand(&.{"bash"});
    wording.addFileArg(b.path("qa/wording_audit.sh"));

    const zig_docs = b.addSystemCommand(&.{"python3"});
    zig_docs.addFileArg(b.path("qa/zig_docs_vendor_check.py"));
    zig_docs.addArgs(&.{
        "--root",
        "docs/vendor/zig-0.16.0",
    });

    const security_read_only = b.addSystemCommand(&.{"bash"});
    security_read_only.addFileArg(b.path("qa/security_gate.sh"));
    security_read_only.addArgs(&.{ "--profile", "read-only" });

    const security_self_test = b.addSystemCommand(&.{"bash"});
    security_self_test.has_side_effects = true;
    security_self_test.addFileArg(b.path("qa/security_gate.sh"));
    security_self_test.addArg("--self-test");

    const governance_manifest = b.addSystemCommand(&.{"python3"});
    governance_manifest.addFileArg(b.path("qa/governance_manifest_check.py"));
    governance_manifest.addArgs(&.{
        "--manifest",
        "fixtures/lab/governance-sources.json",
    });

    const governance_manifest_self_test = b.addSystemCommand(&.{"python3"});
    governance_manifest_self_test.addFileArg(b.path("qa/governance_manifest_check.py"));
    governance_manifest_self_test.addArg("--self-test");

    const evidence_manifest_self_test = b.addSystemCommand(&.{"python3"});
    evidence_manifest_self_test.addFileArg(b.path("qa/evidence_manifest_check.py"));
    evidence_manifest_self_test.addArg("--self-test");

    const manual_vm_proof_self_test = b.addSystemCommand(&.{"python3"});
    manual_vm_proof_self_test.addFileArg(b.path("qa/manual_vm_proof_ci_check.py"));
    manual_vm_proof_self_test.addArg("--self-test");

    const manual_vm_proof_static = b.addSystemCommand(&.{"python3"});
    manual_vm_proof_static.addFileArg(b.path("qa/manual_vm_proof_ci_check.py"));
    manual_vm_proof_static.addArgs(&.{
        "--workflow",
        ".github/workflows/manual-vm-proof.yml",
        "--docs",
        "docs/ci.md",
        "docs/runbooks/vm-lab.md",
        "docs/releases/governance-gate.md",
        "docs/security/review-checklist.md",
    });

    const matrix_contract_fixture_check = b.addSystemCommand(&.{"python3"});
    matrix_contract_fixture_check.addFileArg(b.path("qa/matrix_run_contract_check.py"));
    matrix_contract_fixture_check.addArgs(&.{
        "--fixtures",
        "fixtures/matrix-run",
        "--schemas",
        "schemas/control",
        "--docs",
        "docs/control",
    });

    const matrix_contract_self_test = b.addSystemCommand(&.{"python3"});
    matrix_contract_self_test.addFileArg(b.path("qa/matrix_run_contract_check.py"));
    matrix_contract_self_test.addArg("--self-test");

    const runner_substrate_fixture_check = b.addSystemCommand(&.{"python3"});
    runner_substrate_fixture_check.addFileArg(b.path("qa/runner_substrate_proof_check.py"));
    runner_substrate_fixture_check.addArgs(&.{
        "--fixtures",
        "fixtures/runner-substrate-proof",
        "--schema",
        "schemas/control/runner-substrate-proof.v1.schema.json",
    });

    const runner_substrate_self_test = b.addSystemCommand(&.{"python3"});
    runner_substrate_self_test.addFileArg(b.path("qa/runner_substrate_proof_check.py"));
    runner_substrate_self_test.addArg("--self-test");

    const benchmark_provenance_self_test = b.addSystemCommand(&.{"python3"});
    benchmark_provenance_self_test.addFileArg(b.path("qa/matrix_benchmark_provenance_check.py"));
    benchmark_provenance_self_test.addArg("--self-test");

    const benchmark_self_test = b.addSystemCommand(&.{"python3"});
    benchmark_self_test.addFileArg(b.path("qa/benchmark_output_check.py"));
    benchmark_self_test.addArg("--self-test");

    const host_safe_matrix_cleanup = b.addSystemCommand(&.{"bash"});
    host_safe_matrix_cleanup.has_side_effects = true;
    host_safe_matrix_cleanup.addArgs(&.{
        "-c",
        "rmdir evidence/lab/matrix 2>/dev/null || true",
    });
    host_safe_matrix_cleanup.step.dependOn(&release_gate.step);
    host_safe_matrix_cleanup.step.dependOn(&matrix_contract_fixture_check.step);
    host_safe_matrix_cleanup.step.dependOn(&matrix_contract_self_test.step);

    const host_safe_gates = b.step("host-safe-gates", "Run host-safe matrix, safety, release-withheld, privacy, and docs gates");
    host_safe_gates.dependOn(bpf_step);
    host_safe_gates.dependOn(&workload_catalog.step);
    host_safe_gates.dependOn(&root_ui_absence.step);
    host_safe_gates.dependOn(&no_host_mutation.step);
    host_safe_gates.dependOn(&release_gate.step);
    host_safe_gates.dependOn(&wording.step);
    host_safe_gates.dependOn(&zig_docs.step);
    host_safe_gates.dependOn(&security_read_only.step);
    host_safe_gates.dependOn(&security_self_test.step);
    host_safe_gates.dependOn(&governance_manifest.step);
    host_safe_gates.dependOn(&governance_manifest_self_test.step);
    host_safe_gates.dependOn(&evidence_manifest_self_test.step);
    host_safe_gates.dependOn(&manual_vm_proof_self_test.step);
    host_safe_gates.dependOn(&manual_vm_proof_static.step);
    host_safe_gates.dependOn(&matrix_contract_fixture_check.step);
    host_safe_gates.dependOn(&matrix_contract_self_test.step);
    host_safe_gates.dependOn(&runner_substrate_fixture_check.step);
    host_safe_gates.dependOn(&runner_substrate_self_test.step);
    host_safe_gates.dependOn(&benchmark_self_test.step);
    host_safe_gates.dependOn(&benchmark_provenance_self_test.step);
    host_safe_gates.dependOn(&host_safe_matrix_cleanup.step);
    return host_safe_gates;
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

fn addVmHarnessMatrixStep(b: *Build) void {
    const vm_harness_matrix = b.addSystemCommand(&.{"bash"});
    vm_harness_matrix.has_side_effects = true;
    if (b.args) |args| {
        vm_harness_matrix.addFileArg(b.path("qa/vm/vm_harness_matrix.sh"));
        vm_harness_matrix.addArgs(args);
    } else {
        vm_harness_matrix.addArgs(&.{
            "-c",
            "run_id=\"zig-build-vm-harness-matrix-$(date -u +%Y%m%dT%H%M%SZ)-$$\"; out=\"evidence/lab/matrix/${run_id}\"; cleanup() { rm -rf \"$out\"; rmdir evidence/lab/matrix 2>/dev/null || true; }; trap cleanup EXIT; bash qa/vm/vm_harness_matrix.sh --mode host-safe --scenario fixture-pass --out \"$out\"; python3 qa/matrix_run_contract_check.py --manifest \"$out/manifest.json\" --schemas schemas/control --docs docs/control",
        });
    }

    const vm_harness_matrix_step = b.step("vm-harness-matrix", "Run host-safe VM harness matrix evidence runner");
    vm_harness_matrix_step.dependOn(&vm_harness_matrix.step);
}

fn addPackageStep(b: *Build) void {
    const package_build = b.addSystemCommand(&.{"bash"});
    package_build.addFileArg(b.path("packaging/build_package.sh"));
    package_build.addArg("--out");
    package_build.addArg("zig-out/package");
    package_build.step.dependOn(b.getInstallStep());

    const package_manifest_check = b.addSystemCommand(&.{"python3"});
    package_manifest_check.addFileArg(b.path("qa/package_manifest_check.py"));
    package_manifest_check.addArgs(&.{
        "--manifest",
        "zig-out/package/manifest.json",
    });
    package_manifest_check.step.dependOn(&package_build.step);

    const package_step = b.step("package", "Stage a safe installable package artifact manifest");
    package_step.dependOn(&package_build.step);
    package_step.dependOn(&package_manifest_check.step);
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

fn addRunStep(
    b: *Build,
    artifact: *Compile,
    name: []const u8,
    description: []const u8,
) void {
    const run_cmd = b.addRunArtifact(artifact);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}
