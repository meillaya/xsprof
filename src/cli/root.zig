//! CLI dispatch.
//!
//! The command surface lives in `registry.zig` (one table drives dispatch,
//! help, completions, and the committed manifest). This file only translates
//! argv into handler calls, enforces the fail-closed order — removed verb,
//! unsafe verb, unknown verb — and owns the three tiny host-inspection
//! handlers that do not have their own module.

const std = @import("std");
const json = @import("../core/json.zig");
const version = @import("../core/version.zig");
const safety = @import("../core/safety.zig");
const proc = @import("../os/linux/proc.zig");
const journal = @import("../stream/journal.zig");
const chrome_trace = @import("../viz/chrome_trace.zig");
const state_paths = @import("../platform/state_paths.zig");
const render_cmd = @import("render.zig");
const demo_cmd = @import("demo_cmd.zig");
const advise_cmd = @import("advise_cmd.zig");
const incident_cmd = @import("incident_cmd.zig");
const history_cmd = @import("history_cmd.zig");
const bpf_cmd = @import("bpf_cmd.zig");
const recorder_cmd = @import("recorder_cmd.zig");
const record_cmd = @import("record_cmd.zig");
const top_cmd = @import("top_cmd.zig");
const why_cmd = @import("why_cmd.zig");
const completions_cmd = @import("completions_cmd.zig");
const doctor_cmd = @import("doctor_cmd.zig");
const watch_cmd = @import("watch_cmd.zig");
const analysis_cmd = @import("analysis_cmd.zig");
const observe_cmd = @import("observe_cmd.zig");
const verify_cmd = @import("verify_cmd.zig");
const validate_cmd = @import("validate_cmd.zig");
const exit_mod = @import("exit.zig");
const registry = @import("registry.zig");
const help = @import("help.zig");

const Writer = std.Io.Writer;
const Exit = exit_mod.Exit;

pub const unsafe_verbs = safety.unsafe_verbs;

const refusal_reason =
    "unsafe verb is disabled in the host operator (fail-closed); " ++
    "mutation is VM-lab-only with audit-id + rollback-id + lab marker";

fn writeRefusal(w: *Writer, verb: []const u8) Writer.Error!void {
    try json.write(w, .{ .object = &.{
        .{ .key = "event", .value = .{ .string = "refusal" } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "reason", .value = .{ .string = refusal_reason } },
        .{ .key = "schema", .value = .{ .string = "xsprof/event/v1" } },
        .{ .key = "status", .value = .{ .string = "refused" } },
        .{ .key = "verb", .value = .{ .string = verb } },
    } });
    try w.writeByte('\n');
}

/// Whether bare xsprof may open a native window. Unit tests pass .never so a
/// developer terminal can never open a window during `zig build test`.
pub const UiPolicy = enum { interactive, never };

pub fn uiAllowed(env: state_paths.Env, io: std.Io, policy: UiPolicy) bool {
    if (policy == .never) return false;
    if (env.get("XSPROF_NO_UI") != null) return false;
    const tty = std.Io.File.stdout().isTty(io) catch false;
    if (!tty) return false;
    if (comptime @import("builtin").os.tag == .linux) {
        if (env.get("DISPLAY") == null and env.get("WAYLAND_DISPLAY") == null) return false;
    }
    return true;
}

pub fn run(init: std.process.Init) !Exit {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buffer: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    var err_buffer: [4096]u8 = undefined;
    var err_file: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);

    const code = try runWith(
        init.io,
        arena,
        state_paths.Env.fromMap(init.environ_map),
        args,
        &out_file.interface,
        &err_file.interface,
        .interactive,
    );
    try out_file.interface.flush();
    try err_file.interface.flush();
    return code;
}

fn hasJson(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn cmdPreflight(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    if (!hasJson(args)) {
        try err.writeAll("preflight expects --json and remains read-only\n");
        return .usage;
    }
    const capabilities = try proc.probeCapabilities(io, allocator);
    const facts = try proc.collectFacts(io, allocator);
    try proc.writePreflight(out, capabilities, facts);
    return .ok;
}

fn cmdCapabilities(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    if (!hasJson(args)) {
        try err.writeAll("capabilities expects --json and remains read-only\n");
        return .usage;
    }
    const capabilities = try proc.probeCapabilities(io, allocator);
    try proc.writeCapabilities(out, capabilities);
    try out.writeByte('\n');
    return .ok;
}

fn cmdTimeline(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var window_text: ?[]const u8 = null;
    var chunk_size: ?usize = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input")) {
            if (i + 1 >= args.len) {
                try err.writeAll("timeline: --input requires a path\n");
                return .usage;
            }
            i += 1;
            input = args[i];
        } else if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) {
                try err.writeAll("timeline: --output requires a path\n");
                return .usage;
            }
            i += 1;
            output = args[i];
        } else if (std.mem.eql(u8, arg, "--window")) {
            if (i + 1 >= args.len) {
                try err.writeAll("timeline: --window requires start:end\n");
                return .usage;
            }
            i += 1;
            window_text = args[i];
        } else if (std.mem.eql(u8, arg, "--chunk-size")) {
            if (i + 1 >= args.len) {
                try err.writeAll("timeline: --chunk-size requires a number\n");
                return .usage;
            }
            i += 1;
            const parsed = std.fmt.parseInt(usize, args[i], 10) catch {
                try err.writeAll("timeline: invalid --chunk-size\n");
                return .usage;
            };
            chunk_size = if (parsed == 0) null else parsed;
        }
    }
    const input_path = input orelse {
        try err.writeAll("timeline requires --input <journal.jsonl>\n");
        return .usage;
    };
    const window = if (window_text) |text| chrome_trace.parseWindow(text) orelse {
        try err.writeAll("timeline: invalid --window (expected start:end in microseconds)\n");
        return .usage;
    } else null;

    const events = journal.read(io, allocator, input_path) catch |read_error| {
        try err.print("timeline: cannot read {s}: {s}\n", .{ input_path, @errorName(read_error) });
        return .refuse;
    };

    if (output) |path| {
        const file = if (path.len != 0 and path[0] == '/')
            std.Io.Dir.createFileAbsolute(io, path, .{}) catch {
                try err.print("timeline: cannot open output {s}\n", .{path});
                return .refuse;
            }
        else
            std.Io.Dir.cwd().createFile(io, path, .{}) catch {
                try err.print("timeline: cannot open output {s}\n", .{path});
                return .refuse;
            };
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        try chrome_trace.writeTimeline(&file_writer.interface, allocator, events, window, chunk_size);
        try file_writer.interface.flush();
    } else {
        try chrome_trace.writeTimeline(out, allocator, events, window, chunk_size);
    }
    if (chunk_size != null) {
        try err.print("{{\"journal_rows\":{d}}}\n", .{events.len});
    }
    return .ok;
}

/// `help` dispatch: plain help, grouped `--all`, per-command usage, or the
/// canonical manifest (`--json --all [--check]`).
fn cmdHelp(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var show_all = false;
    var as_json = false;
    var check = false;
    var target: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (arg.len != 0 and arg[0] == '-') {
            continue;
        } else if (target == null) {
            target = arg;
        }
    }
    if (check) {
        if (!as_json) {
            try err.writeAll("help: --check requires --json (canonical CLI manifest)\n");
            return .usage;
        }
        return registry.checkManifest(io, allocator, out, err);
    }
    if (as_json) {
        try registry.writeManifest(out);
        return .ok;
    }
    if (target) |name| {
        if (registry.find(name)) |command| {
            try help.writeCommand(out, name, command);
        } else {
            try help.writeHelp(out);
        }
        return .ok;
    }
    if (show_all) {
        try help.writeAllHelp(out);
    } else {
        try help.writeHelp(out);
    }
    return .ok;
}

const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
};

/// Exhaustive over `registry.Handler`: adding a command without wiring its
/// handler fails to compile.
fn dispatch(ctx: Context, handler: registry.Handler) !Exit {
    return switch (handler) {
        .advise => advise_cmd.cmdAdvise(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .bpf_gate => bpf_cmd.cmdBpf(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .capabilities => cmdCapabilities(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .capture => recorder_cmd.cmdCapture(ctx.io, ctx.allocator, ctx.env, ctx.args, ctx.out, ctx.err),
        .cgroup => observe_cmd.cmdCgroup(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .compare => analysis_cmd.cmdCompare(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .completions => completions_cmd.cmdCompletions(ctx.args, ctx.out, ctx.err),
        .daemon => recorder_cmd.cmdDaemon(ctx.io, ctx.allocator, ctx.env, ctx.args, ctx.out, ctx.err),
        .demo => demo_cmd.cmdDemo(ctx.io, ctx.allocator, ctx.env, ctx.args, ctx.out, ctx.err),
        .doctor => doctor_cmd.cmdDoctor(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .help => cmdHelp(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .history => history_cmd.cmdHistory(ctx.io, ctx.allocator, ctx.env, ctx.args, ctx.out, ctx.err),
        .incident => incident_cmd.cmdIncident(ctx.io, ctx.allocator, ctx.env, ctx.args, ctx.out, ctx.err),
        .metrics => analysis_cmd.cmdMetrics(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .preflight => cmdPreflight(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .pressure => observe_cmd.cmdPressure(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .record => record_cmd.cmdRecord(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .snapshot => render_cmd.cmdSnapshot(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .timeline => cmdTimeline(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .top => top_cmd.cmdTop(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .ui => render_cmd.cmdUi(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .unsafe => blk: {
            // Unreachable through runWith (refused before dispatch); kept so the
            // switch stays exhaustive and future callers stay fail-closed.
            try writeRefusal(ctx.out, if (ctx.args.len == 0) "unsafe" else ctx.args[0]);
            break :blk .refuse;
        },
        .validate => validate_cmd.cmdValidate(ctx.io, ctx.allocator, ctx.args, ctx.out, ctx.err),
        .verify => verify_cmd.cmdVerify(ctx.io, ctx.allocator, ctx.env, ctx.args, ctx.out, ctx.err),
        .version => blk: {
            try ctx.out.writeAll(version.line());
            break :blk .ok;
        },
        .watch => watch_cmd.cmdWatch(ctx.io, ctx.allocator, ctx.env, ctx.args, ctx.out, ctx.err),
        .why => why_cmd.cmdWhy(ctx.io, ctx.allocator, ctx.env, ctx.args, ctx.out, ctx.err),
    };
}

pub fn runWith(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
    ui_policy: UiPolicy,
) !Exit {
    if (args.len < 2) {
        // The signed app bundle launches the binary directly and asks for the
        // native UI through LSEnvironment instead of a shell wrapper.
        if (env.get("XSPROF_APP_MODE") != null) {
            return render_cmd.cmdUi(io, allocator, &.{}, out, err);
        }
        if (uiAllowed(env, io, ui_policy)) {
            return render_cmd.cmdUi(io, allocator, &.{}, out, err);
        }
        try help.writeQuickstart(out);
        return .ok;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try help.writeHelp(out);
        return .ok;
    }
    if (std.mem.eql(u8, cmd, "help")) {
        return cmdHelp(io, allocator, args[2..], out, err);
    }
    if (registry.isRemoved(cmd)) {
        try err.print(
            "xsprof: {s} was removed in 0.5.0; the console is native only (run `xsprof` or `xsprof demo`, or use `xsprof snapshot` for headless output)\n",
            .{cmd},
        );
        return .usage;
    }
    if (args.len > 2 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h"))) {
        if (registry.find(cmd)) |command| {
            try help.writeCommand(out, cmd, command);
        } else {
            try help.writeHelp(out);
        }
        return .ok;
    }
    if (std.mem.eql(u8, cmd, "--version")) {
        try out.writeAll(version.line());
        return .ok;
    }

    const command = registry.find(cmd) orelse {
        // Unknown verbs fail closed with a canonical refusal, exactly like the
        // pre-registry CLI: scripts can distinguish refusal from usage errors.
        try writeRefusal(out, cmd);
        return .refuse;
    };
    if (command.unsafe) {
        try writeRefusal(out, cmd);
        return .refuse;
    }
    const ctx = Context{
        .io = io,
        .allocator = allocator,
        .env = env,
        .args = args[2..],
        .out = out,
        .err = err,
    };
    return dispatch(ctx, command.handler);
}

const TestEnv = struct {
    map: std.process.Environ.Map,

    fn init(allocator: std.mem.Allocator) TestEnv {
        return .{ .map = std.process.Environ.Map.init(allocator) };
    }

    fn env(self: *TestEnv) state_paths.Env {
        return state_paths.Env.fromMap(&self.map);
    }

    fn deinit(self: *TestEnv) void {
        self.map.deinit();
    }

    fn put(self: *TestEnv, key: []const u8, value: []const u8) !void {
        try self.map.put(key, value);
    }
};

fn testRun(
    test_env: *TestEnv,
    args: []const []const u8,
    out_buffer: []u8,
    err_buffer: []u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    out.* = Writer.fixed(out_buffer);
    err.* = Writer.fixed(err_buffer);
    return runWith(std.testing.io, arena.allocator(), test_env.env(), args, out, err, .never);
}

test "help exits zero and names the tool" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "help" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "xsprof") != null);
}

test "bare invocation without a UI policy prints the quickstart" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{"xsprof"};
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "xsprof") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "help --all") != null);
    try std.testing.expect(!uiAllowed(test_env.env(), std.testing.io, .never));
}

test "help --all lists automation verbs from the registry" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [16 * 1024]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "help", "--all" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "advise") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "capture") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "serve") == null);
}

test "help lists visible commands and hides automation verbs" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "help" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    var visible_buffer: [registry.all_commands.len][]const u8 = undefined;
    for (registry.visibleNames(&visible_buffer)) |verb| {
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), verb) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "advise") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "help --all") != null);
}

test "help --json --all emits the canonical CLI manifest" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [registry.manifest_max_bytes]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "help", "--json", "--all" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    const manifest = out.buffered();
    try std.testing.expect(std.mem.startsWith(u8, manifest, "{\"commands\":["));
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"schema\":\"xsprof/cli-manifest/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"name\":\"validate\"") != null);
}

test "help --json --all --check verifies the committed manifest" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "help", "--json", "--all", "--check" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "cli-manifest: PASS") != null);
}

test "aliases resolve to the canonical command's help" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "report", "--help" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "alias of `xsprof incident`") != null);
}

test "version is stable" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [128]u8 = undefined;
    var err_buffer: [64]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "version" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expectEqualStrings("xsprof 0.6.1\n", out.buffered());
}

test "unsafe verbs refuse with canonical json" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [64]u8 = undefined;
    for (unsafe_verbs) |verb| {
        var out: Writer = undefined;
        var err: Writer = undefined;
        const args = [_][]const u8{ "xsprof", verb };
        try std.testing.expectEqual(
            Exit.refuse,
            try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
        );
        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"event\":\"refusal\",\"host_mutation\":false," ++
                "\"reason\":\"unsafe verb is disabled in the host operator (fail-closed); " ++
                "mutation is VM-lab-only with audit-id + rollback-id + lab marker\"," ++
                "\"schema\":\"xsprof/event/v1\",\"status\":\"refused\"," ++
                "\"verb\":\"{s}\"}}\n",
            .{verb},
        );
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, out.buffered());
    }
}

test "unknown verbs fail closed" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [64]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "no-such-verb" };
    try std.testing.expectEqual(
        Exit.refuse,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"verb\":\"no-such-verb\"") != null);
}

test "removed serve verb fails closed with an explicit reason" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [512]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "serve" };
    try std.testing.expectEqual(
        Exit.usage,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "removed in 0.5.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "refusal") == null);
}

test "preflight requires --json and emits a read-only document" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [16384]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;

    const no_json = [_][]const u8{ "xsprof", "preflight" };
    try std.testing.expectEqual(
        Exit.usage,
        try testRun(&test_env, &no_json, &out_buffer, &err_buffer, &out, &err),
    );

    const with_json = [_][]const u8{ "xsprof", "preflight", "--json" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &with_json, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"schema\":\"xsprof/preflight/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"capabilities\":[") != null);
}

test "capabilities requires --json and is an array" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [64]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "capabilities", "--json" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "[{\"host_mutation\":false"));
}

test "advise json and markdown stay read-only" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    var out_buffer: [16384]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;

    const json_args = [_][]const u8{ "xsprof", "advise", "--json" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &json_args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"schema\":\"xsprof/advisor-report/v1\"") != null);

    const md_args = [_][]const u8{ "xsprof", "advise", "--md" };
    try std.testing.expectEqual(
        Exit.ok,
        try testRun(&test_env, &md_args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Performance Advisor Report") != null);
}

test "XSPROF_STATE_DIR from the injected environment reaches verb defaults" {
    var test_env = TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    try test_env.put("XSPROF_STATE_DIR", "/tmp/xsprof-b2-env-state");
    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    // `verify` with no --dir resolves the state dir; the empty temp dir does
    // not exist, so the verb fails closed and reports the resolved path.
    const args = [_][]const u8{ "xsprof", "verify" };
    try std.testing.expectEqual(
        Exit.refuse,
        try testRun(&test_env, &args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(
        std.mem.indexOf(u8, err.buffered(), "/tmp/xsprof-b2-env-state") != null,
    );
}
