//! Deterministic mutation fuzzing for the parsers that consume untrusted
//! bytes. These are fast property tests, not a replacement for a long-running
//! coverage-guided fuzzer: every case is reproducible from the fixed seed.

const std = @import("std");
const xsprof = @import("xsprof");

const cases = 3000;

fn mutate(random: std.Random, seed: []const u8, buffer: []u8) []u8 {
    const len = @min(seed.len, buffer.len);
    @memcpy(buffer[0..len], seed[0..len]);
    var copy_len = len;
    if (copy_len == 0 or random.boolean()) {
        copy_len = random.intRangeAtMost(usize, 0, @min(buffer.len, 512));
        random.bytes(buffer[0..copy_len]);
    }
    const flips = random.intRangeAtMost(usize, 1, 4);
    var i: usize = 0;
    while (i < flips and copy_len != 0) : (i += 1) {
        const at = random.uintLessThan(usize, copy_len);
        buffer[at] = random.int(u8);
    }
    return buffer[0..copy_len];
}

test "fuzz event JSON, journal, manifest, pressure, cgroup, and duration" {
    var prng = std.Random.DefaultPrng.init(0x585350524f46);
    const random = prng.random();
    var buffer: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const event_seed =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_switch\",\"ts_ns\":1," ++
        "\"cpu\":0,\"pid\":10,\"tid\":10,\"comm\":\"worker\",\"host_mutation\":false}";
    const manifest_seed =
        "{\"host_mutation\":false,\"max_age_ms\":600000,\"max_bytes\":2147483648," ++
        "\"schema\":\"xsprof/recorder-manifest/v1\",\"segments\":[],\"session_id\":\"abc\"," ++
        "\"started_mono_ns\":1,\"started_wall_ns\":2,\"state\":\"stopped\",\"updated_wall_ns\":3}";
    const pressure_seed =
        "some avg10=1.23 avg60=4.56 avg300=7.89 total=123456\n" ++
        "full avg10=0.25 avg60=0.50 avg300=0.75 total=9000\n";
    const cgroup_seed = "0::/user.slice/user-1000.slice/session-2.scope\n";

    var case_index: usize = 0;
    while (case_index < cases) : (case_index += 1) {
        if (case_index % 256 == 0) _ = arena.reset(.retain_capacity);

        const event_bytes = mutate(random, event_seed, buffer[0..1024]);
        if (xsprof.event.parseJson(allocator, event_bytes)) |parsed| {
            var canonical: [2048]u8 = undefined;
            var writer = std.Io.Writer.fixed(&canonical);
            xsprof.event.writeJson(&writer, parsed) catch continue;
            var reparsed = xsprof.event.parseJson(allocator, writer.buffered()) catch
                @panic("canonical event did not re-parse");
            std.mem.doNotOptimizeAway(&reparsed);
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"host_mutation\":false") != null);
        } else |_| {}

        const journal_bytes = mutate(random, event_seed, buffer[0..1024]);
        _ = xsprof.journal.parseData(allocator, journal_bytes) catch {};

        const manifest_bytes = mutate(random, manifest_seed, buffer[0..2048]);
        _ = xsprof.recorder_manifest.parse(allocator, manifest_bytes) catch {};

        const pressure_bytes = mutate(random, pressure_seed, buffer[0..1024]);
        _ = xsprof.pressure.parseResource(pressure_bytes) catch {};

        const cgroup_bytes = mutate(random, cgroup_seed, buffer[0..1024]);
        _ = xsprof.cgroup.parseProcCgroup(cgroup_bytes);

        const duration_bytes = mutate(random, "10m", buffer[0..64]);
        _ = xsprof.recorder_extract.parseDuration(duration_bytes) catch {};
    }
}
