//! Bounded JSON-Schema (draft 2020-12 subset) validator for the committed
//! xsprof wire contracts.
//!
//! This is a fail-closed validation helper, not a general-purpose JSON-Schema
//! engine. It supports only the keywords the committed schemas use; structural
//! conformance of the schema documents themselves (canonical `$id`, allowed
//! keywords, resolvable `$ref`s) is checked by `tests/schema.zig`. Every input
//! is bounded: byte length, JSON nesting depth, `$ref` hops, and recursion.
//!
//! Supported keywords: `type`, `properties`, `required`, `additionalProperties`,
//! `items`, `minItems`, `maxItems`, `anyOf`, `enum`, `const`, `minimum`,
//! `maximum`, `minLength`, `maxLength`, and local `#/$defs/<name>` `$ref`.
//! `$schema`, `$id`, `title`, and `$defs` are annotations/definitions.
//!
//! The module imports `std` only so it can be unit-tested standalone with
//! `zig test src/core/schema.zig` and reused by the test root without pulling in
//! OS/UI modules.

const std = @import("std");

pub const max_schema_bytes = 256 * 1024;
pub const max_instance_bytes = 1024 * 1024;
pub const max_depth = 64;
pub const max_ref_hops = 16;
pub const canonical_id_prefix = "https://xsprof.dev/schemas/";
pub const draft_2020_12 = "https://json-schema.org/draft/2020-12/schema";

pub const Error = error{
    /// Input is not JSON, is empty, or exceeds a structural bound.
    InvalidJson,
    /// Schema document uses unsupported keywords or an inconsistent structure.
    InvalidSchema,
    /// Instance does not satisfy the schema.
    ValidationFailed,
    OutOfMemory,
};

/// Bounded diagnostic for the first failed keyword. `path` is a JSON-pointer-like
/// location in the instance (`/tasks/3/pid`).
pub const Failure = struct {
    pub const capacity = 192;
    buffer: [capacity]u8 = undefined,
    length: usize = 0,
    keyword: []const u8 = "",

    pub fn path(self: *const Failure) []const u8 {
        return self.buffer[0..self.length];
    }
};

/// A parsed schema document. Owns an arena containing the schema JSON; each
/// validated instance is parsed into a scratch arena that is freed afterwards.
pub const Schema = struct {
    arena: std.heap.ArenaAllocator,
    root: std.json.Value,
    failure: Failure = .{},

    path_buf: [Failure.capacity]u8 = undefined,
    path_len: usize = 0,
    ref_hops: usize = 0,

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Schema {
        if (text.len == 0 or text.len > max_schema_bytes) return error.InvalidJson;
        var arena = std.heap.ArenaAllocator.init(allocator);
        var ok = false;
        defer if (!ok) arena.deinit();
        const root = try parseBounded(arena.allocator(), text, max_schema_bytes);
        if (root != .object) return error.InvalidSchema;
        ok = true;
        return .{ .arena = arena, .root = root };
    }

    pub fn deinit(self: *Schema) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Validate one JSON document (single object/array/value) against the schema.
    pub fn validateText(self: *Schema, text: []const u8) Error!void {
        var scratch = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer scratch.deinit();
        const instance = try parseBounded(scratch.allocator(), text, max_instance_bytes);
        return self.validateValue(instance);
    }

    /// Validate an already-parsed instance value against the schema.
    pub fn validateValue(self: *Schema, instance: std.json.Value) Error!void {
        self.failure = .{};
        self.path_len = 0;
        self.ref_hops = 0;
        return self.validateSchema(self.root, instance, 0);
    }

    fn validateSchema(
        self: *Schema,
        schema_value: std.json.Value,
        instance: std.json.Value,
        depth: usize,
    ) Error!void {
        if (depth > max_depth * 2) return error.InvalidSchema;
        const schema = switch (schema_value) {
            .object => |object| object,
            else => return error.InvalidSchema,
        };
        if (schema.get("$ref")) |ref_value| {
            const name = try refName(ref_value);
            if (self.ref_hops >= max_ref_hops) return error.InvalidSchema;
            const root_object = switch (self.root) {
                .object => |object| object,
                else => return error.InvalidSchema,
            };
            const defs = switch (root_object.get("$defs") orelse return error.InvalidSchema) {
                .object => |object| object,
                else => return error.InvalidSchema,
            };
            const target = defs.get(name) orelse return error.InvalidSchema;
            self.ref_hops += 1;
            defer self.ref_hops -= 1;
            try self.validateSchema(target, instance, depth + 1);
        }
        if (schema.get("type")) |type_value| {
            if (!typeMatches(type_value, instance)) return self.fail("type");
        }
        if (schema.get("const")) |const_value| {
            if (!deepEqual(const_value, instance)) return self.fail("const");
        }
        if (schema.get("enum")) |enum_value| {
            if (unionTag(enum_value) != .array) return error.InvalidSchema;
            var matched = false;
            for (enum_value.array.items) |candidate| {
                if (deepEqual(candidate, instance)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return self.fail("enum");
        }
        const properties: ?std.json.ObjectMap = if (schema.get("properties")) |value| switch (value) {
            .object => |object| object,
            else => return error.InvalidSchema,
        } else null;
        switch (instance) {
            .object => |object| {
                if (schema.get("required")) |required| {
                    if (unionTag(required) != .array) return error.InvalidSchema;
                    for (required.array.items) |name_value| {
                        const name = switch (name_value) {
                            .string => |string| string,
                            else => return error.InvalidSchema,
                        };
                        if (object.get(name) == null) return self.fail("required");
                    }
                }
                if (properties) |documented| {
                    var iterator = documented.iterator();
                    while (iterator.next()) |entry| {
                        const child = object.get(entry.key_ptr.*) orelse continue;
                        const mark = self.path_len;
                        self.pushKey(entry.key_ptr.*);
                        try self.validateSchema(entry.value_ptr.*, child, depth + 1);
                        self.path_len = mark;
                    }
                }
                if (schema.get("additionalProperties")) |additional| {
                    if (unionTag(additional) != .bool) return error.InvalidSchema;
                    if (!additional.bool) {
                        const empty = std.json.ObjectMap.empty;
                        const documented = properties orelse empty;
                        for (object.keys()) |key| {
                            if (documented.get(key) != null) continue;
                            self.pushKey(key);
                            return self.fail("additionalProperties");
                        }
                    }
                }
            },
            .array => |array| {
                if (schema.get("items")) |items| {
                    for (array.items, 0..) |item, index| {
                        const mark = self.path_len;
                        self.pushIndex(index);
                        try self.validateSchema(items, item, depth + 1);
                        self.path_len = mark;
                    }
                }
                if (schema.get("minItems")) |bound| {
                    if (array.items.len < try goodBound(bound)) return self.fail("minItems");
                }
                if (schema.get("maxItems")) |bound| {
                    if (array.items.len > try goodBound(bound)) return self.fail("maxItems");
                }
            },
            .string => |string| {
                if (schema.get("minLength")) |bound| {
                    if (codepointCount(string) < try goodBound(bound)) return self.fail("minLength");
                }
                if (schema.get("maxLength")) |bound| {
                    if (codepointCount(string) > try goodBound(bound)) return self.fail("maxLength");
                }
            },
            else => {
                if (numericValue(instance)) |number| {
                    if (schema.get("minimum")) |bound| {
                        if (number < numericValue(bound).?) return self.fail("minimum");
                    }
                    if (schema.get("maximum")) |bound| {
                        if (number > numericValue(bound).?) return self.fail("maximum");
                    }
                }
            },
        }
        if (schema.get("anyOf")) |any_of| {
            if (unionTag(any_of) != .array) return error.InvalidSchema;
            const mark = self.path_len;
            var passed = false;
            for (any_of.array.items) |branch| {
                self.path_len = mark;
                if (self.validateSchema(branch, instance, depth + 1)) |_| {
                    passed = true;
                    break;
                } else |err| switch (err) {
                    error.ValidationFailed => continue,
                    else => return err,
                }
            }
            if (!passed) {
                self.path_len = mark;
                return self.fail("anyOf");
            }
        }
    }

    fn goodBound(value: std.json.Value) Error!usize {
        return schemaNonNegativeInt(value) orelse error.InvalidSchema;
    }

    fn fail(self: *Schema, keyword: []const u8) Error {
        const length = @min(self.path_len, Failure.capacity);
        @memcpy(self.failure.buffer[0..length], self.path_buf[0..length]);
        self.failure.length = length;
        self.failure.keyword = keyword;
        return error.ValidationFailed;
    }

    fn pushIndex(self: *Schema, index: usize) void {
        var digits: [24]u8 = undefined;
        const segment = std.fmt.bufPrint(&digits, "/{d}", .{index}) catch return;
        self.pushBytes(segment);
    }

    fn pushKey(self: *Schema, key: []const u8) void {
        self.pushBytes("/");
        self.pushBytes(key);
    }

    fn pushBytes(self: *Schema, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.path_len >= Failure.capacity) return;
            self.path_buf[self.path_len] = byte;
            self.path_len += 1;
        }
    }
};

/// Parse one bounded JSON value (single document). Used by the test registry for
/// NDJSON lines and archived frames.
pub fn parseBounded(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_bytes: usize,
) Error!std.json.Value {
    if (text.len == 0 or text.len > @min(max_bytes, max_instance_bytes)) return error.InvalidJson;
    if (!depthOk(text, max_depth)) return error.InvalidJson;
    return std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        text,
        .{ .max_value_len = text.len },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
}

/// Reject pathological nesting before std.json runs. Mirrors the core writer's
/// guard; duplicated so this module stays dependency-free for standalone tests.
pub fn depthOk(data: []const u8, max_nesting: usize) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (data) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > max_nesting) return false;
            },
            ']', '}' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
    return depth == 0 and !in_string and !escaped;
}

fn unionTag(value: std.json.Value) std.meta.Tag(std.json.Value) {
    return std.meta.activeTag(value);
}

fn refName(value: std.json.Value) Error![]const u8 {
    const text = switch (value) {
        .string => |string| string,
        else => return error.InvalidSchema,
    };
    const prefix = "#/$defs/";
    if (!std.mem.startsWith(u8, text, prefix)) return error.InvalidSchema;
    const name = text[prefix.len..];
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/#") != null) return error.InvalidSchema;
    return name;
}

fn typeMatches(type_value: std.json.Value, instance: std.json.Value) bool {
    return switch (type_value) {
        .string => |name| typeNameMatches(name, instance),
        .array => |array| blk: {
            for (array.items) |item| {
                if (typeMatches(item, instance)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn typeNameMatches(name: []const u8, instance: std.json.Value) bool {
    return switch (instance) {
        .null => std.mem.eql(u8, name, "null"),
        .bool => std.mem.eql(u8, name, "boolean"),
        .integer => std.mem.eql(u8, name, "integer") or std.mem.eql(u8, name, "number"),
        .float => std.mem.eql(u8, name, "number"),
        .number_string => |text| blk: {
            if (std.mem.eql(u8, name, "number")) break :blk numericValue(instance) != null;
            if (std.mem.eql(u8, name, "integer"))
                break :blk std.json.isNumberFormattedLikeAnInteger(text) and numericValue(instance) != null;
            break :blk false;
        },
        .string => std.mem.eql(u8, name, "string"),
        .array => std.mem.eql(u8, name, "array"),
        .object => std.mem.eql(u8, name, "object"),
    };
}

fn numericValue(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| if (std.math.isFinite(float)) float else null,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

fn schemaNonNegativeInt(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |integer| if (integer < 0) null else std.math.cast(usize, integer),
        .float => |float| if (std.math.isFinite(float) and float >= 0 and @floor(float) == float and
            float <= @as(f64, @floatFromInt(std.math.maxInt(u32))))
            @intFromFloat(float)
        else
            null,
        else => null,
    };
}

fn codepointCount(string: []const u8) usize {
    return std.unicode.utf8CountCodepoints(string) catch string.len;
}

fn deepEqual(a: std.json.Value, b: std.json.Value) bool {
    if (numericValue(a)) |a_number| {
        const b_number = numericValue(b) orelse return false;
        return a_number == b_number;
    }
    return switch (a) {
        .null => unionTag(b) == .null,
        .bool => |a_bool| unionTag(b) == .bool and a_bool == b.bool,
        .string => |a_string| unionTag(b) == .string and std.mem.eql(u8, a_string, b.string),
        .array => |a_array| blk: {
            if (unionTag(b) != .array or a_array.items.len != b.array.items.len) break :blk false;
            for (a_array.items, b.array.items) |a_item, b_item| {
                if (!deepEqual(a_item, b_item)) break :blk false;
            }
            break :blk true;
        },
        .object => |a_object| blk: {
            if (unionTag(b) != .object or a_object.count() != b.object.count()) break :blk false;
            var iterator = a_object.iterator();
            while (iterator.next()) |entry| {
                const b_value = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!deepEqual(entry.value_ptr.*, b_value)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

const value_schema =
    \\{"type":"object","additionalProperties":false,"required":["id","kind"],
    \\"properties":{"id":{"type":"string","minLength":1},
    \\"kind":{"enum":["a","b"]},"count":{"type":"integer","minimum":0},
    \\"tags":{"type":"array","maxItems":2,"items":{"type":"string"}}}}
;

fn testSchema(allocator: std.mem.Allocator) !Schema {
    return Schema.parse(allocator, value_schema);
}

test "validates nested objects and reports keyword plus path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document = try testSchema(arena.allocator());
    defer document.deinit();

    try document.validateText("{\"id\":\"x\",\"kind\":\"a\",\"count\":2,\"tags\":[\"t\"]}");
    try std.testing.expectError(
        error.ValidationFailed,
        document.validateText("{\"id\":\"x\",\"kind\":\"a\",\"count\":-1}"),
    );
    try std.testing.expectEqualStrings("minimum", document.failure.keyword);
    try std.testing.expectEqualStrings("/count", document.failure.path());
    try std.testing.expectError(
        error.ValidationFailed,
        document.validateText("{\"id\":\"\",\"kind\":\"a\"}"),
    );
    try std.testing.expectEqualStrings("/id", document.failure.path());
    try std.testing.expectError(
        error.ValidationFailed,
        document.validateText("{\"id\":\"x\",\"kind\":\"a\",\"extra\":0}"),
    );
    try std.testing.expectEqualStrings("additionalProperties", document.failure.keyword);
    try std.testing.expectError(
        error.ValidationFailed,
        document.validateText("{\"id\":\"x\",\"kind\":\"zzz\"}"),
    );
    try std.testing.expectEqualStrings("enum", document.failure.keyword);
    try std.testing.expectError(
        error.ValidationFailed,
        document.validateText("{\"id\":\"x\",\"kind\":\"a\",\"tags\":[\"a\",\"b\",\"c\"]}"),
    );
    try std.testing.expectEqualStrings("maxItems", document.failure.keyword);
}

test "anyOf and local $ref validate alternative shapes" {
    const text =
        \\{"type":"object","required":["value"],"properties":{"value":
        \\{"anyOf":[{"type":"null"},{"$ref":"#/$defs/sample"}]}},
        \\"$defs":{"sample":{"type":"object","required":["total_us"],
        \\"properties":{"total_us":{"type":"integer","minimum":0}}}}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document = try Schema.parse(arena.allocator(), text);
    defer document.deinit();
    try document.validateText("{\"value\":null}");
    try document.validateText("{\"value\":{\"total_us\":5}}");
    try std.testing.expectError(
        error.ValidationFailed,
        document.validateText("{\"value\":{\"total_us\":-1}}"),
    );
    try std.testing.expectEqualStrings("anyOf", document.failure.keyword);
    try std.testing.expectEqualStrings("/value", document.failure.path());
    try std.testing.expectError(
        error.ValidationFailed,
        document.validateText("{\"value\":true}"),
    );
}

test "number, integer, and bounds are distinguished" {
    const text =
        \\{"type":"object","required":["ratio"],"properties":{"ratio":
        \\{"type":"number","minimum":0.5,"maximum":2}}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document = try Schema.parse(arena.allocator(), text);
    defer document.deinit();
    try document.validateText("{\"ratio\":1.5}");
    try std.testing.expectError(error.ValidationFailed, document.validateText("{\"ratio\":0.25}"));
    try std.testing.expectEqualStrings("minimum", document.failure.keyword);
    try std.testing.expectError(error.ValidationFailed, document.validateText("{\"ratio\":3}"));
    try std.testing.expectEqualStrings("maximum", document.failure.keyword);
    try std.testing.expectError(error.ValidationFailed, document.validateText("{\"ratio\":\"1\"}"));
    try std.testing.expectEqualStrings("type", document.failure.keyword);
}

test "schema refs and bounds fail closed when malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var bad_ref = try Schema.parse(allocator,
        \\{"type":"object","properties":{"value":{"$ref":"#/definitions/x"}}}
    );
    defer bad_ref.deinit();
    try std.testing.expectError(error.InvalidSchema, bad_ref.validateText("{\"value\":1}"));
    var missing = try Schema.parse(allocator,
        \\{"type":"object","properties":{"value":{"$ref":"#/$defs/missing"}}}
    );
    defer missing.deinit();
    try std.testing.expectError(error.InvalidSchema, missing.validateText("{\"value\":1}"));
}

test "pathological input is rejected before parsing and depth is bounded" {
    try std.testing.expect(depthOk("{\"a\":[1,2]}", 4));
    try std.testing.expect(!depthOk("[[[[[]]]]]", 4));
    try std.testing.expect(depthOk("{\"text\":\"[[[[\"}", 2));
    try std.testing.expect(!depthOk("}", 4));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidSchema, Schema.parse(allocator, "true"));
    try std.testing.expectError(error.InvalidJson, parseBounded(allocator, "{\"a\":1}", 4));
    try std.testing.expectError(error.InvalidJson, parseBounded(allocator, "", 16));
    try std.testing.expectError(error.InvalidJson, parseBounded(allocator, "{\"a\":", 16));
    var deep: [132]u8 = undefined;
    for (0..66) |index| {
        deep[index] = '[';
        deep[deep.len - 1 - index] = ']';
    }
    try std.testing.expectError(error.InvalidJson, parseBounded(allocator, &deep, 4096));
}
