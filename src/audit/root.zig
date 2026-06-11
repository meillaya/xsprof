const std = @import("std");

pub const AuditIdInputs = struct {
    timestamp: []const u8,
    git_short: []const u8,
    random_bytes: [3]u8,
};

pub fn formatAuditId(buffer: []u8, inputs: AuditIdInputs) ![]const u8 {
    if (!validTimestamp(inputs.timestamp)) return error.InvalidAuditTimestamp;
    if (!validGitShort(inputs.git_short)) return error.InvalidAuditGitShort;
    return std.fmt.bufPrint(
        buffer,
        "AUD-{s}-{s}-{x:0>2}{x:0>2}{x:0>2}",
        .{ inputs.timestamp, inputs.git_short, inputs.random_bytes[0], inputs.random_bytes[1], inputs.random_bytes[2] },
    );
}

pub fn generateAuditId(buffer: []u8, inputs: AuditIdInputs) ![]const u8 {
    return formatAuditId(buffer, inputs);
}

pub fn validateAuditId(id: []const u8) bool {
    if (id.len < "AUD-YYYYMMDDTHHMMSSZ-a-000000".len) return false;
    if (!std.mem.startsWith(u8, id, "AUD-")) return false;
    const timestamp = id[4..20];
    if (!validTimestamp(timestamp)) return false;
    if (id[20] != '-') return false;
    const rest = id[21..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return false;
    const git_short = rest[0..dash];
    const random = rest[dash + 1 ..];
    return validGitShort(git_short) and validRandom(random);
}

fn validTimestamp(value: []const u8) bool {
    if (value.len != "YYYYMMDDTHHMMSSZ".len) return false;
    for (value, 0..) |byte, index| {
        if (index == 8) {
            if (byte != 'T') return false;
        } else if (index == 15) {
            if (byte != 'Z') return false;
        } else if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn validGitShort(value: []const u8) bool {
    if (value.len < 7 or value.len > 12) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

fn validRandom(value: []const u8) bool {
    if (value.len != 6) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

pub const LedgerError = error{
    DuplicateAuditId,
    SecretLikeAuditRecord,
};

pub const LedgerRecord = struct {
    audit_id: []const u8,
    rollback_id: []const u8,
    action: []const u8,
    transcript: []const u8,
};

pub fn validateAppendOnlyRecord(record: LedgerRecord, existing_audit_ids: []const []const u8) LedgerError!void {
    for (existing_audit_ids) |existing| {
        if (std.mem.eql(u8, existing, record.audit_id)) return error.DuplicateAuditId;
    }
    if (containsSecretLike(record.action) or containsSecretLike(record.transcript)) return error.SecretLikeAuditRecord;
}

fn containsSecretLike(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "secret") != null or
        std.mem.indexOf(u8, value, "password") != null or
        std.mem.indexOf(u8, value, "token") != null or
        std.mem.indexOf(u8, value, "Authorization") != null;
}

test "audit formatter produces deterministic shape and validator accepts it" {
    var buffer: [64]u8 = undefined;
    const id = try formatAuditId(&buffer, .{
        .timestamp = "20260610T210305Z",
        .git_short = "deadbee",
        .random_bytes = .{ 0xa1, 0xb2, 0xc3 },
    });
    try std.testing.expectEqualStrings("AUD-20260610T210305Z-deadbee-a1b2c3", id);
    try std.testing.expect(validateAuditId(id));
}

test "audit generator accepts injected time git and random bytes" {
    var buffer: [64]u8 = undefined;
    const id = try generateAuditId(&buffer, .{
        .timestamp = "20260610T210305Z",
        .git_short = "012abcd",
        .random_bytes = .{ 0x00, 0x10, 0xff },
    });
    try std.testing.expectEqualStrings("AUD-20260610T210305Z-012abcd-0010ff", id);
}

test "audit validator rejects malformed ids" {
    try std.testing.expect(!validateAuditId("AUD-20260610T210305-deadbee-a1b2c3"));
    try std.testing.expect(!validateAuditId("AUD-20260610T210305Z-deadbee-a1b2"));
    try std.testing.expect(!validateAuditId("AUD-20260610T210305Z-dead;ee-a1b2c3"));
    try std.testing.expect(!validateAuditId("not-audit"));
}

test "append-only audit records reject duplicate ids and secret-like content" {
    const existing = [_][]const u8{"AUD-20260610T210305Z-deadbee-a1b2c3"};
    try std.testing.expectError(error.DuplicateAuditId, validateAppendOnlyRecord(.{
        .audit_id = existing[0],
        .rollback_id = "RB-demo",
        .action = "rollback",
        .transcript = "transcript.txt",
    }, &existing));
    try std.testing.expectError(error.SecretLikeAuditRecord, validateAppendOnlyRecord(.{
        .audit_id = "AUD-20260610T210305Z-deadbee-0010ff",
        .rollback_id = "RB-demo",
        .action = "rollback token leaked",
        .transcript = "transcript.txt",
    }, &existing));
    try validateAppendOnlyRecord(.{
        .audit_id = "AUD-20260610T210305Z-deadbee-0010ff",
        .rollback_id = "RB-demo",
        .action = "rollback",
        .transcript = "rollback-transcript.txt",
    }, &existing);
}
