//! Schema-conformance test root for the committed xsprof wire contracts.
//!
//! Two layers:
//! 1. Every schema document under `schemas/xsprof/` is structurally valid
//!    inside the supported JSON-Schema subset, has a unique canonical
//!    `$id` (`https://xsprof.dev/schemas/<basename>`), and every committed
//!    `.schema.json` file is registered here.
//! 2. An explicit file -> contract registry validates every committed
//!    `tests/golden/**` wire sample and every committed event fixture under
//!    `fixtures/ui/` + `fixtures/real/` (NDJSON line by line) against the
//!    correct schema.
//!
//! Run through `zig build test` once wired, or directly:
//!   ./tools/zig test --dep xsprof-schema \
//!     -Mroot=tests/schema.zig -Mxsprof-schema=src/core/schema.zig
//!
//! Keep the registry explicit: adding/removing a schema or a wire sample must
//! be a visible edit here. `lab-run.v1`/`lab-scenario.v1` are intentionally
//! absent because the lab surface was removed from the product.

const std = @import("std");
const schema = @import("xsprof-schema");

const schema_dir = "schemas/xsprof";
const max_fixture_bytes = 8 * 1024 * 1024;

const SchemaFile = struct {
    file: []const u8,
    contract: []const u8,
};

const schema_files = [_]SchemaFile{
    .{ .file = "advisor-report.v1.schema.json", .contract = "xsprof/advisor-report/v1" },
    .{ .file = "aggregates.v1.schema.json", .contract = "xsprof/aggregates/v1" },
    .{ .file = "bpf-gate.v1.schema.json", .contract = "xsprof/bpf-gate/v1" },
    .{ .file = "capture-summary.v1.schema.json", .contract = "xsprof/capture-summary/v1" },
    .{ .file = "cgroup.v1.schema.json", .contract = "xsprof/cgroup/v1" },
    .{ .file = "compare.v1.schema.json", .contract = "xsprof/compare/v1" },
    .{ .file = "doctor.v1.schema.json", .contract = "xsprof/doctor/v1" },
    .{ .file = "event.v1.schema.json", .contract = "xsprof/event/v1" },
    .{ .file = "history.v1.schema.json", .contract = "xsprof/history/v1" },
    .{ .file = "incident-result.v1.schema.json", .contract = "xsprof/incident-result/v1" },
    .{ .file = "incident-summary.v1.schema.json", .contract = "xsprof/incident-summary/v1" },
    .{ .file = "journal.v1.schema.json", .contract = "xsprof/journal/v1" },
    .{ .file = "metrics.v1.schema.json", .contract = "xsprof/metrics/v1" },
    .{ .file = "preflight.v1.schema.json", .contract = "xsprof/preflight/v1" },
    .{ .file = "pressure.v1.schema.json", .contract = "xsprof/pressure/v1" },
    .{ .file = "recorder-manifest.v1.schema.json", .contract = "xsprof/recorder-manifest/v1" },
    .{ .file = "recorder-result.v1.schema.json", .contract = "xsprof/recorder-result/v1" },
    .{ .file = "recorder-verify.v1.schema.json", .contract = "xsprof/recorder-verify/v1" },
    .{ .file = "validate.v1.schema.json", .contract = "xsprof/validate/v1" },
    .{ .file = "why.v1.schema.json", .contract = "xsprof/why/v1" },
};

const SampleFormat = enum { json, ndjson };

const WireSample = struct {
    path: []const u8,
    contract: []const u8,
    format: SampleFormat = .json,
};

/// Every committed golden/fixture byte sample that carries a maintained wire
/// contract. NDJSON samples are validated one non-empty line at a time.
const wire_samples = [_]WireSample{
    .{ .path = "tests/golden/root/advise_vm_fragmented.json", .contract = "xsprof/advisor-report/v1" },
    .{ .path = "tests/golden/root/aggregates_v1_golden.json", .contract = "xsprof/aggregates/v1" },
    .{ .path = "tests/golden/root/event_v1_golden.json", .contract = "xsprof/event/v1" },
    .{ .path = "tests/golden/root/event_v1_page_fault_golden.json", .contract = "xsprof/event/v1" },
    .{ .path = "tests/golden/root/journal_v1_golden.json", .contract = "xsprof/journal/v1" },
    .{ .path = "tests/golden/recorder/segment_v1_golden.ndjson", .contract = "xsprof/event/v1", .format = .ndjson },
    .{ .path = "fixtures/ui/healthy.ndjson", .contract = "xsprof/event/v1", .format = .ndjson },
    .{ .path = "fixtures/real/scheduler-mix.ndjson", .contract = "xsprof/event/v1", .format = .ndjson },
    .{ .path = "fixtures/real/vm-fragmented.ndjson", .contract = "xsprof/event/v1", .format = .ndjson },
    .{ .path = "fixtures/real/macos-vm-sched.ndjson", .contract = "xsprof/event/v1", .format = .ndjson },
};

/// Golden samples with a documented, non-schema disposition. `daemon-event` is
/// the archived legacy lane (preserved for wire-format reference only); the
/// `.xsraw` segment is a binary format covered by the segment reader tests and
/// `qa/compact_roundtrip.sh`.
const archived_frame_samples = [_]struct { path: []const u8, contract: []const u8 }{
    .{ .path = "tests/golden/root/daemon_replay_golden.jsonl", .contract = "xsprof/daemon-event/v1" },
};

const opaque_samples = [_][]const u8{
    "tests/golden/recorder/segments/segment_v1_golden.xsraw",
};

fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_bytes));
}

fn contractIndex(contract: []const u8) !usize {
    for (schema_files, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.contract, contract)) return index;
    }
    return error.UnregisteredContract;
}

fn schemaFileRegistered(name: []const u8) bool {
    for (schema_files) |entry| {
        if (std.mem.eql(u8, entry.file, name)) return true;
    }
    return false;
}

fn loadSchemas(allocator: std.mem.Allocator, documents: []schema.Schema) !void {
    for (schema_files, 0..) |entry, index| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ schema_dir, entry.file });
        const text = try readFile(allocator, path, schema.max_schema_bytes);
        documents[index] = schema.Schema.parse(allocator, text) catch |err| {
            std.debug.print("schema {s}: parse failed: {s}\n", .{ entry.file, @errorName(err) });
            return err;
        };
    }
}

fn validateDocument(document: *schema.Schema, text: []const u8, path: []const u8, line: usize) !void {
    document.validateText(text) catch |err| {
        std.debug.print(
            "{s}:{d}: schema validation failed: {s} keyword=\"{s}\" path=\"{s}\"\n",
            .{ path, line, @errorName(err), document.failure.keyword, document.failure.path() },
        );
        return err;
    };
}

fn validateFile(document: *schema.Schema, allocator: std.mem.Allocator, path: []const u8) !usize {
    const bytes = try readFile(allocator, path, max_fixture_bytes);
    if (std.mem.endsWith(u8, path, ".ndjson") or std.mem.endsWith(u8, path, ".jsonl")) {
        var validated: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var line_number: usize = 0;
        while (lines.next()) |raw_line| {
            line_number += 1;
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0) continue;
            try validateDocument(document, line, path, line_number);
            validated += 1;
        }
        return validated;
    }
    try validateDocument(document, bytes, path, 1);
    return 1;
}

fn field(object: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return object.get(key) orelse error.MissingSchemaField;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (try field(object, key)) {
        .string => |text| text,
        else => error.SchemaFieldWrongType,
    };
}

fn unionTag(value: std.json.Value) std.meta.Tag(std.json.Value) {
    return std.meta.activeTag(value);
}

fn checkSchemaDocument(document: *const schema.Schema, file: []const u8, contract: []const u8) !void {
    const root = switch (document.root) {
        .object => |object| object,
        else => return error.SchemaRootNotObject,
    };
    try std.testing.expectEqualStrings(schema.draft_2020_12, try stringField(root, "$schema"));
    var id_buffer: [160]u8 = undefined;
    const expected_id = try std.fmt.bufPrint(&id_buffer, "{s}{s}", .{ schema.canonical_id_prefix, file });
    try std.testing.expectEqualStrings(expected_id, try stringField(root, "$id"));
    try std.testing.expect((try stringField(root, "title")).len != 0);
    try std.testing.expectEqualStrings("object", try stringField(root, "type"));
    const properties = switch (try field(root, "properties")) {
        .object => |object| object,
        else => return error.SchemaFieldWrongType,
    };
    const discriminator = switch (properties.get("schema") orelse return error.MissingSchemaDiscriminator) {
        .object => |object| object,
        else => return error.SchemaFieldWrongType,
    };
    try std.testing.expectEqualStrings(contract, try stringField(discriminator, "const"));
    try checkSchemaValue(document, document.root, 0, true);
}

fn checkRequired(value: std.json.Value, properties: ?std.json.Value) !void {
    const names = switch (value) {
        .array => |array| array,
        else => return error.SchemaFieldWrongType,
    };
    try std.testing.expect(names.items.len != 0);
    const documented = if (properties) |value_object| switch (value_object) {
        .object => |object| object,
        else => null,
    } else null;
    for (names.items, 0..) |name_value, index| {
        const name = switch (name_value) {
            .string => |text| text,
            else => return error.SchemaFieldWrongType,
        };
        try std.testing.expect(name.len != 0);
        for (names.items[0..index]) |earlier| {
            if (earlier == .string and std.mem.eql(u8, earlier.string, name)) return error.DuplicateRequired;
        }
        const properties_object = documented orelse return error.RequiredWithoutProperties;
        try std.testing.expect(properties_object.get(name) != null);
    }
}

fn checkTypeKeyword(value: std.json.Value) !void {
    const valid = [_][]const u8{ "null", "boolean", "object", "array", "number", "string", "integer" };
    switch (value) {
        .string => |name| for (valid) |candidate| {
            if (std.mem.eql(u8, name, candidate)) return;
        } else return error.UnknownSchemaType,
        .array => |array| {
            try std.testing.expect(array.items.len != 0);
            for (array.items) |item| {
                try checkTypeKeyword(item);
            }
        },
        else => return error.SchemaFieldWrongType,
    }
}

fn checkRef(document: *const schema.Schema, value: std.json.Value) !void {
    const text = switch (value) {
        .string => |string| string,
        else => return error.SchemaFieldWrongType,
    };
    const prefix = "#/$defs/";
    try std.testing.expect(std.mem.startsWith(u8, text, prefix));
    const name = text[prefix.len..];
    try std.testing.expect(name.len != 0 and std.mem.indexOfAny(u8, name, "/#") == null);
    const root = switch (document.root) {
        .object => |object| object,
        else => return error.SchemaRootNotObject,
    };
    const defs = switch (root.get("$defs") orelse return error.MissingDefs) {
        .object => |object| object,
        else => return error.SchemaFieldWrongType,
    };
    try std.testing.expect(defs.get(name) != null);
}

fn checkNonNegativeInt(value: std.json.Value) !void {
    switch (value) {
        .integer => |integer| try std.testing.expect(integer >= 0),
        else => return error.SchemaFieldWrongType,
    }
}

fn checkSchemaValue(
    document: *const schema.Schema,
    value: std.json.Value,
    depth: usize,
    is_root: bool,
) !void {
    if (depth > schema.max_depth) return error.SchemaTooDeep;
    const object = switch (value) {
        .object => |object| object,
        else => return error.SchemaKeywordNotObject,
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const keyword = entry.key_ptr.*;
        const child = entry.value_ptr.*;
        if (std.mem.eql(u8, keyword, "$schema")) {
            try std.testing.expect(is_root);
            try std.testing.expectEqualStrings(schema.draft_2020_12, try stringField(object, "$schema"));
        } else if (std.mem.eql(u8, keyword, "$id")) {
            try std.testing.expect(is_root);
            _ = try stringField(object, "$id");
        } else if (std.mem.eql(u8, keyword, "title")) {
            try std.testing.expect((try stringField(object, "title")).len != 0);
        } else if (std.mem.eql(u8, keyword, "$defs")) {
            try std.testing.expect(is_root);
            const defs = switch (child) {
                .object => |defs_object| defs_object,
                else => return error.SchemaFieldWrongType,
            };
            var defs_iterator = defs.iterator();
            while (defs_iterator.next()) |def| {
                try checkSchemaValue(document, def.value_ptr.*, depth + 1, false);
            }
        } else if (std.mem.eql(u8, keyword, "$ref")) {
            try checkRef(document, child);
        } else if (std.mem.eql(u8, keyword, "type")) {
            try checkTypeKeyword(child);
        } else if (std.mem.eql(u8, keyword, "properties")) {
            const properties = switch (child) {
                .object => |properties_object| properties_object,
                else => return error.SchemaFieldWrongType,
            };
            var properties_iterator = properties.iterator();
            while (properties_iterator.next()) |property| {
                try std.testing.expect(property.key_ptr.*.len != 0);
                try checkSchemaValue(document, property.value_ptr.*, depth + 1, false);
            }
        } else if (std.mem.eql(u8, keyword, "required")) {
            try checkRequired(child, object.get("properties"));
        } else if (std.mem.eql(u8, keyword, "additionalProperties")) {
            try std.testing.expect(unionTag(child) == .bool);
        } else if (std.mem.eql(u8, keyword, "items")) {
            try checkSchemaValue(document, child, depth + 1, false);
        } else if (std.mem.eql(u8, keyword, "minItems") or
            std.mem.eql(u8, keyword, "maxItems") or
            std.mem.eql(u8, keyword, "minLength") or
            std.mem.eql(u8, keyword, "maxLength"))
        {
            try checkNonNegativeInt(child);
        } else if (std.mem.eql(u8, keyword, "minimum") or std.mem.eql(u8, keyword, "maximum")) {
            try std.testing.expect(unionTag(child) == .integer or unionTag(child) == .float);
        } else if (std.mem.eql(u8, keyword, "anyOf")) {
            const branches = switch (child) {
                .array => |array| array,
                else => return error.SchemaFieldWrongType,
            };
            try std.testing.expect(branches.items.len != 0);
            for (branches.items) |branch| {
                try checkSchemaValue(document, branch, depth + 1, false);
            }
        } else if (std.mem.eql(u8, keyword, "enum")) {
            try std.testing.expect(unionTag(child) == .array);
            try std.testing.expect(child.array.items.len != 0);
        } else if (std.mem.eql(u8, keyword, "const")) {
            // Any JSON value is a legal const.
        } else {
            std.debug.print("schema keyword unsupported: {s}\n", .{keyword});
            return error.UnsupportedSchemaKeyword;
        }
    }
}

test "committed schema documents are canonical, unique, and structurally in subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var documents: [schema_files.len]schema.Schema = undefined;
    try loadSchemas(allocator, &documents);
    defer for (&documents) |*document| document.deinit();

    for (schema_files, 0..) |entry, index| {
        checkSchemaDocument(&documents[index], entry.file, entry.contract) catch |err| {
            std.debug.print("schema {s}: structural check failed: {s}\n", .{ entry.file, @errorName(err) });
            return err;
        };
    }
    for (schema_files, 0..) |entry, index| {
        var id_buffer: [160]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "{s}{s}", .{ schema.canonical_id_prefix, entry.file });
        for (schema_files[0..index]) |earlier| {
            var earlier_buffer: [160]u8 = undefined;
            const earlier_id = try std.fmt.bufPrint(&earlier_buffer, "{s}{s}", .{ schema.canonical_id_prefix, earlier.file });
            try std.testing.expect(!std.mem.eql(u8, id, earlier_id));
            try std.testing.expect(!std.mem.eql(u8, entry.contract, earlier.contract));
        }
    }

    // Fail closed if a schema file is added or removed without updating the
    // explicit registry (and its 600-line sibling `.contract` table).
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, schema_dir, .{ .iterate = true });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var found: usize = 0;
    while (try iterator.next(std.testing.io)) |dir_entry| {
        if (dir_entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, dir_entry.name, ".json")) continue;
        try std.testing.expect(schemaFileRegistered(dir_entry.name));
        found += 1;
    }
    try std.testing.expectEqual(schema_files.len, found);
}

test "registry validates every committed golden and ui fixture sample" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var documents: [schema_files.len]schema.Schema = undefined;
    try loadSchemas(allocator, &documents);
    defer for (&documents) |*document| document.deinit();

    var total: usize = 0;
    for (wire_samples) |sample| {
        const index = try contractIndex(sample.contract);
        const validated = try validateFile(&documents[index], allocator, sample.path);
        try std.testing.expect(validated != 0);
        total += validated;
    }
    try std.testing.expect(total >= wire_samples.len);
}

test "journal golden entries also validate as canonical events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var documents: [schema_files.len]schema.Schema = undefined;
    try loadSchemas(allocator, &documents);
    defer for (&documents) |*document| document.deinit();

    const bytes = try readFile(allocator, "tests/golden/root/journal_v1_golden.json", max_fixture_bytes);
    const journal = try schema.parseBounded(allocator, bytes, max_fixture_bytes);
    const root = switch (journal) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    const entries = switch (root.get("entries") orelse return error.TestUnexpectedResult) {
        .array => |array| array,
        else => return error.TestUnexpectedResult,
    };
    const event_document = &documents[try contractIndex("xsprof/event/v1")];
    for (entries.items, 0..) |entry, index| {
        event_document.validateValue(entry) catch |err| {
            std.debug.print(
                "journal entry {d}: event schema failed: {s} keyword=\"{s}\" path=\"{s}\"\n",
                .{ index, @errorName(err), event_document.failure.keyword, event_document.failure.path() },
            );
            return err;
        };
    }
}

test "archived legacy frames and opaque segments have explicit dispositions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (archived_frame_samples) |sample| {
        try std.testing.expectError(error.UnregisteredContract, contractIndex(sample.contract));
        const bytes = try readFile(allocator, sample.path, max_fixture_bytes);
        var previous_seq: i64 = -1;
        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            line_number += 1;
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0) continue;
            const frame = try schema.parseBounded(allocator, line, max_fixture_bytes);
            const object = switch (frame) {
                .object => |object| object,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expect(std.mem.eql(u8, try stringField(object, "schema"), sample.contract));
            const mutation = try field(object, "host_mutation");
            try std.testing.expect(unionTag(mutation) == .bool and !mutation.bool);
            const seq = switch (try field(object, "seq")) {
                .integer => |integer| integer,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expect(seq > previous_seq);
            previous_seq = seq;
        }
    }
    for (opaque_samples) |path| {
        const bytes = try readFile(allocator, path, max_fixture_bytes);
        try std.testing.expect(bytes.len != 0);
    }
}

test "validate verb result schema accepts canonical success and failure shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var documents: [schema_files.len]schema.Schema = undefined;
    try loadSchemas(allocator, &documents);
    defer for (&documents) |*document| document.deinit();
    const document = &documents[try contractIndex("xsprof/validate/v1")];

    try validateDocument(document,
        \\{"documents":1,"file":"session.ndjson","host_mutation":false,"ok":true,
        \\"schema":"xsprof/validate/v1","schema_name":"xsprof/event/v1"}
    , "validate-success", 1);
    try validateDocument(document,
        \\{"documents":0,"error":"missing required","file":"session.ndjson",
        \\"host_mutation":false,"keyword":"required","ok":false,"path":"/tasks/0",
        \\"schema":"xsprof/validate/v1","schema_name":"xsprof/event/v1"}
    , "validate-failure", 1);
    try std.testing.expectError(error.ValidationFailed, document.validateText(
        \\{"documents":1,"file":"session.ndjson","host_mutation":false,"ok":true,
        \\"schema":"xsprof/validate/v1"}
    ));
}

test "capture-summary requires page_faults (record drift regression)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var documents: [schema_files.len]schema.Schema = undefined;
    try loadSchemas(allocator, &documents);
    defer for (&documents) |*document| document.deinit();
    const document = &documents[try contractIndex("xsprof/capture-summary/v1")];

    try validateDocument(document,
        \\{"capability":"READY","duration_ms":300,"events_captured":73648,
        \\"faults_major":12,"faults_minor":4959,"host_mutation":false,"lost":0,
        \\"output":"session.ndjson","page_faults":4971,"sched_migrations":3,
        \\"sched_switches":68631,"sched_wakeups":41,
        \\"schema":"xsprof/capture-summary/v1","source":"perf_tracepoint"}
    , "capture-summary", 1);
    try std.testing.expectError(error.ValidationFailed, document.validateText(
        \\{"capability":"READY","duration_ms":300,"events_captured":1,
        \\"faults_major":0,"faults_minor":0,"host_mutation":false,"lost":0,
        \\"output":"-","sched_migrations":0,"sched_switches":0,"sched_wakeups":0,
        \\"schema":"xsprof/capture-summary/v1","source":"perf_tracepoint"}
    ));
}
