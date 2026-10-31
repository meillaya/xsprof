//! Privacy boundary for event text. No argv/environment is ever collected;
//! comm is bounded to the kernel's TASK_COMM_LEN-1, and sensitive key/value
//! material is redacted before serialization or rendering.

const std = @import("std");

pub const redacted = "[REDACTED]";

const sensitive_keys = [_][]const u8{
    "secret", "api_key",    "apikey", "api-key",     "token",      "password",
    "passwd", "credential", "auth",   "private_key", "access_key", "session_id",
};

const secret_markers = [_][]const u8{
    "-----begin", "bearer", "sk-", "ghp_", "xox", "aws_secret",
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

pub fn isSensitiveKey(key: []const u8) bool {
    for (sensitive_keys) |candidate| {
        if (containsIgnoreCase(key, candidate)) return true;
    }
    return false;
}

pub fn isSensitiveValue(value: []const u8) bool {
    for (secret_markers) |marker| {
        if (containsIgnoreCase(value, marker)) return true;
    }
    return false;
}

/// Copy at most 15 bytes of a kernel comm into `buf`, replacing bytes outside
/// printable ASCII so the wire form is always valid UTF-8 JSON.
pub fn boundComm(comm: []const u8, buf: *[15]u8) []const u8 {
    const n = @min(comm.len, buf.len);
    for (comm[0..n], 0..) |byte, i| {
        buf[i] = if (byte >= 0x20 and byte < 0x7f) byte else '?';
    }
    return buf[0..n];
}

fn appendToken(out: []u8, used: *usize, token: []const u8) void {
    for (token) |byte| {
        if (used.* >= out.len) return;
        out[used.*] = if (byte >= 0x20 and byte < 0x7f) byte else '?';
        used.* += 1;
    }
}

/// Redact sensitive `key=value` / `key: value` material and secret-looking
/// values into `out`. The result is a prefix if the input is too long; callers
/// bound event detail before this point.
fn isDelimiter(c: u8) bool {
    return c == ' ' or c == ',' or c == ';';
}

/// Redact sensitive `key=value` / `key: value` material and secret-looking
/// values into `out`. The result is a prefix if the input is too long; callers
/// bound event detail before this point.
pub fn redactDetail(detail: []const u8, out: []u8) []const u8 {
    var used: usize = 0;
    var i: usize = 0;
    while (i < detail.len) {
        const start = i;
        while (i < detail.len and !isDelimiter(detail[i])) i += 1;
        const token = detail[start..i];
        const split = std.mem.indexOfAny(u8, token, "=:");

        if (split) |at| {
            const key = token[0..at];
            const value = token[at + 1 ..];
            const sensitive = isSensitiveKey(key) or isSensitiveValue(value);
            if (sensitive and value.len == 0 and token[at] == ':') {
                // `key: value` where the value is separated by whitespace.
                appendToken(out, &used, key);
                appendToken(out, &used, ":");
                if (i < detail.len and detail[i] == ' ') {
                    appendToken(out, &used, " ");
                    i += 1;
                }
                while (i < detail.len and !isDelimiter(detail[i])) i += 1;
                appendToken(out, &used, redacted);
            } else if (sensitive) {
                appendToken(out, &used, key);
                appendToken(out, &used, &[_]u8{token[at]});
                appendToken(out, &used, redacted);
            } else {
                appendToken(out, &used, token);
            }
        } else if (isSensitiveValue(token)) {
            appendToken(out, &used, redacted);
        } else {
            appendToken(out, &used, token);
        }
        if (i < detail.len) {
            appendToken(out, &used, detail[i .. i + 1]);
            i += 1;
        }
    }
    return out[0..used];
}

test "sensitive keys and values are detected case-insensitively" {
    try std.testing.expect(isSensitiveKey("API_KEY"));
    try std.testing.expect(isSensitiveKey("Password"));
    try std.testing.expect(!isSensitiveKey("comm"));
    try std.testing.expect(isSensitiveValue("Bearer abc"));
    try std.testing.expect(isSensitiveValue("sk-live-123"));
    try std.testing.expect(!isSensitiveValue("worker"));
}

test "redaction preserves delimiters and non-secret tokens" {
    var buf: [128]u8 = undefined;
    const out = redactDetail("pid=7 token=abc,comm=worker password: hunter2", &buf);
    try std.testing.expectEqualStrings(
        "pid=7 token=[REDACTED],comm=worker password: [REDACTED]",
        out,
    );
}

test "secret-looking bare values are redacted" {
    var buf: [128]u8 = undefined;
    const out = redactDetail("bearer ghp_abc safe", &buf);
    try std.testing.expectEqualStrings("[REDACTED] [REDACTED] safe", out);
}

test "comm is bounded to fifteen bytes" {
    var buf: [15]u8 = undefined;
    const out = boundComm("abcdefghijklmnopqrstuvwxyz", &buf);
    try std.testing.expectEqualStrings("abcdefghijklmno", out);
}
