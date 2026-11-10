//! xsprof validate: validate canonical wire documents against the committed
//! JSON schemas. Read-only, bounded, and usable by automation/CI.

const std = @import("std");
const json = @import("../core/json.zig");
const schema = @import("../core/schema.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;

const max_evidence_bytes = 64 * 1024 * 1024;

const Options = struct {
    schema_path: []const u8 = "",
    file_path: []const u8 = "",
    as_json: bool = false,
    force_ndjson: bool = false,
};

pub fn cmdValidate(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    const options = parseArgs(args, err) catch return .usage;
    if (options.schema_path.len == 0 or options.file_path.len == 0) {
        try err.writeAll("validate: --schema <name|path> and --file <path> are required\n");
        return .usage;
    }

    const resolved_schema = resolveSchemaPath(allocator, options.schema_path) catch |resolve_error| {
        try err.print("validate: schema {s}: {s}\n", .{ options.schema_path, @errorName(resolve_error) });
        return .usage;
    };
    defer allocator.free(resolved_schema);

    const schema_text = std.Io.Dir.cwd().readFileAlloc(io, resolved_schema, allocator, .limited(schema.max_schema_bytes)) catch |read_error| {
        try err.print("validate: cannot read schema {s}: {s}\n", .{ resolved_schema, @errorName(read_error) });
        return .usage;
    };
    defer allocator.free(schema_text);

    var validator = schema.Schema.parse(allocator, schema_text) catch |parse_error| {
        try err.print("validate: schema {s}: {s}\n", .{ resolved_schema, @errorName(parse_error) });
        return .usage;
    };
    defer validator.deinit();

    const evidence = std.Io.Dir.cwd().readFileAlloc(io, options.file_path, allocator, .limited(max_evidence_bytes)) catch |read_error| {
        try err.print("validate: cannot read {s}: {s}\n", .{ options.file_path, @errorName(read_error) });
        return .usage;
    };
    defer allocator.free(evidence);

    const schema_name = schemaShortName(resolved_schema);
    const ndjson = options.force_ndjson or std.mem.endsWith(u8, options.file_path, ".ndjson") or std.mem.endsWith(u8, options.file_path, ".jsonl");

    var documents: u64 = 0;
    var failure: ?Failure = null;
    if (ndjson) {
        var lines = std.mem.splitScalar(u8, evidence, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            documents += 1;
            validator.validateText(trimmed) catch |validation_error| {
                failure = .{
                    .line = documents,
                    .error_name = @errorName(validation_error),
                    .keyword = validator.failure.keyword,
                    .path = validator.failure.path(),
                };
                break;
            };
        }
    } else {
        documents = 1;
        validator.validateText(evidence) catch |validation_error| {
            failure = .{
                .line = 1,
                .error_name = @errorName(validation_error),
                .keyword = validator.failure.keyword,
                .path = validator.failure.path(),
            };
        };
    }

    const ok = failure == null;
    if (options.as_json) {
        try writeResultJson(out, options.file_path, schema_name, documents, failure);
    } else if (failure) |failed| {
        try err.print(
            "validate: FAIL {s}:{d} keyword={s} path={s} ({s})\n",
            .{ options.file_path, failed.line, failed.keyword, failed.path, failed.error_name },
        );
    } else {
        try out.print(
            "validate: PASS ({d} document{s}) {s} against {s}\n",
            .{ documents, if (documents == 1) "" else "s", options.file_path, schema_name },
        );
    }
    return if (ok) .ok else .refuse;
}

const Failure = struct {
    line: u64,
    error_name: []const u8,
    keyword: []const u8,
    path: []const u8,
};

fn parseArgs(args: []const []const u8, err: *Writer) !Options {
    var options = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--schema") and i + 1 < args.len) {
            i += 1;
            options.schema_path = args[i];
        } else if (std.mem.eql(u8, arg, "--file") and i + 1 < args.len) {
            i += 1;
            options.file_path = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.as_json = true;
        } else if (std.mem.eql(u8, arg, "--ndjson")) {
            options.force_ndjson = true;
        } else {
            try err.print("validate: unknown option {s}\n", .{arg});
            return error.BadArgs;
        }
    }
    return options;
}

/// Accept a literal path (contains `/` or ends in `.json`) or a schema name
/// such as `event.v1` / `xsprof/event/v1`, resolved under `schemas/xsprof/`.
fn resolveSchemaPath(allocator: std.mem.Allocator, requested: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, requested, '/') != null or std.mem.endsWith(u8, requested, ".json")) {
        return allocator.dupe(u8, requested);
    }
    return std.fmt.allocPrint(allocator, "schemas/xsprof/{s}.schema.json", .{requested});
}

fn schemaShortName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".schema.json")) {
        return base[0 .. base.len - ".schema.json".len];
    }
    return base;
}

fn writeResultJson(
    out: *Writer,
    file_path: []const u8,
    schema_name: []const u8,
    documents: u64,
    failure: ?Failure,
) Writer.Error!void {
    if (failure) |failed| {
        try json.write(out, .{ .object = &.{
            .{ .key = "documents", .value = .{ .unsigned = documents } },
            .{ .key = "error", .value = .{ .string = failed.error_name } },
            .{ .key = "file", .value = .{ .string = file_path } },
            .{ .key = "host_mutation", .value = .{ .boolean = false } },
            .{ .key = "keyword", .value = .{ .string = failed.keyword } },
            .{ .key = "ok", .value = .{ .boolean = false } },
            .{ .key = "path", .value = .{ .string = failed.path } },
            .{ .key = "schema", .value = .{ .string = "xsprof/validate/v1" } },
            .{ .key = "schema_name", .value = .{ .string = schema_name } },
        } });
    } else {
        try json.write(out, .{ .object = &.{
            .{ .key = "documents", .value = .{ .unsigned = documents } },
            .{ .key = "file", .value = .{ .string = file_path } },
            .{ .key = "host_mutation", .value = .{ .boolean = false } },
            .{ .key = "ok", .value = .{ .boolean = true } },
            .{ .key = "schema", .value = .{ .string = "xsprof/validate/v1" } },
            .{ .key = "schema_name", .value = .{ .string = schema_name } },
        } });
    }
    try out.writeByte('\n');
}

test "validate requires schema and file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out_buffer: [128]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        Exit.usage,
        try cmdValidate(std.testing.io, arena.allocator(), &.{}, &out, &err),
    );
}

test "validate rejects unknown options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out_buffer: [128]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        Exit.usage,
        try cmdValidate(std.testing.io, arena.allocator(), &.{"--nope"}, &out, &err),
    );
}
