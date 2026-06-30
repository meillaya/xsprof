const std = @import("std");
const stream = @import("stream.zig");
const samples = @import("stream_test_samples.zig");

const appendRuntimeFile = stream.appendRuntimeFile;
const appendRuntimeLine = stream.appendRuntimeLine;
const max_stream_events = stream.max_stream_events;

test "runtime stream accepts good samples and sanitizes private failures" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendRuntimeLine(std.testing.allocator, &output, samples.goodSample(0), &seq, 0, "sha");
    try appendRuntimeLine(std.testing.allocator, &output, samples.richSample(), &seq, 0, "sha");
    try appendRuntimeLine(std.testing.allocator, &output, "{malformed", &seq, 0, "sha");
    try appendRuntimeLine(std.testing.allocator, &output, samples.goodSampleWithPrivate(), &seq, 0, "sha");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"runtime_sample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"dsq_depth\":\"global=2 local=1 shared=0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"benchmark_histograms\":\"refs=1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "unsafe_to_assume") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "cmdline") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"env\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "host_mutation\":false") != null);
}

test "runtime stream supports replay offsets stale git and bounded drops" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendRuntimeLine(std.testing.allocator, &output, samples.goodSample(1), &seq, 2, "sha");
    try std.testing.expectEqual(@as(usize, 1), seq);
    try appendRuntimeLine(std.testing.allocator, &output, samples.goodSampleWithGit("old"), &seq, 0, "sha");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "stale_git_sha") != null);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(std.testing.allocator);
    for (0..max_stream_events + 2) |i| {
        try file.appendSlice(std.testing.allocator, samples.goodSample(i));
        try file.append(std.testing.allocator, '\n');
    }
    try appendRuntimeFile(std.testing.allocator, &output, file.items, &seq, 0, "sha");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "stream_backpressure_dropped") != null);
}

test "runtime stream refuses missing policy ABI and invalid cgroup digests" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendRuntimeLine(std.testing.allocator, &output, samples.sampleMissingPolicyAbi(), &seq, 0, "sha");
    try appendRuntimeLine(std.testing.allocator, &output, samples.sampleWithInvalidDigest(), &seq, 0, "sha");
    try std.testing.expectEqual(@as(usize, 3), seq);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"runtime_sample\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "malformed_runtime_sample") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "host_mutation\":false") != null);
}

test "runtime stream refuses digest quote injection before emission" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendRuntimeLine(std.testing.allocator, &output, samples.sampleWithDigestQuoteInjection(), &seq, 0, "sha");
    try std.testing.expectEqual(@as(usize, 2), seq);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"runtime_sample\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "malformed_runtime_sample") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"host_mutation\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"x\"") == null);
}

test "runtime stream emits ordered alerts after accepted samples" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendRuntimeLine(std.testing.allocator, &output, samples.sampleWithRejectedDispatches(), &seq, 0, "sha");
    try appendRuntimeLine(std.testing.allocator, &output, samples.sampleWithLoss(), &seq, 0, "sha");
    try appendRuntimeLine(std.testing.allocator, &output, samples.sampleWithDeadWorkload(), &seq, 0, "sha");
    const rejected_sample = std.mem.indexOf(u8, output.items, "\"sample_sequence\":3") orelse return error.TestExpectedRuntimeAlertSample;
    const rejected_incident = std.mem.indexOf(u8, output.items, "runtime_nr_rejected_nonzero") orelse return error.TestExpectedRuntimeAlertIncident;
    const loss_sample = std.mem.indexOf(u8, output.items, "\"sample_sequence\":5") orelse return error.TestExpectedRuntimeAlertSample;
    const loss_incident = std.mem.indexOf(u8, output.items, "runtime_sample_loss") orelse return error.TestExpectedRuntimeAlertIncident;
    const dead_sample = std.mem.indexOf(u8, output.items, "\"sample_sequence\":4") orelse return error.TestExpectedRuntimeAlertSample;
    const dead_incident = std.mem.indexOf(u8, output.items, "runtime_workload_dead") orelse return error.TestExpectedRuntimeAlertIncident;
    try std.testing.expect(rejected_sample < rejected_incident);
    try std.testing.expect(loss_sample < loss_incident);
    try std.testing.expect(dead_sample < dead_incident);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "host_mutation\":false") != null);
}

test "runtime stream accepts ABI-v3 cgroup policy ABI and replay summary stays no-claim" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendRuntimeFile(std.testing.allocator, &output, samples.goodAbiV3PolicySample(), &seq, 0, "sha");
    try std.testing.expectEqual(@as(usize, 2), seq);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"runtime_sample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "malformed_runtime_sample") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "production_claim") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "release_eligible") == null);
}

test "runtime stream rejects bad ABI-v3 cgroup semantics and host claims" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendRuntimeLine(std.testing.allocator, &output, samples.sampleWithBadAbiV3CpuMax(), &seq, 0, "sha");
    try appendRuntimeLine(std.testing.allocator, &output, samples.sampleWithAbiV3HostMutationClaim(), &seq, 0, "sha");
    try std.testing.expectEqual(@as(usize, 3), seq);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"runtime_sample\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "malformed_runtime_sample") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "host_mutation\":true") == null);
}
