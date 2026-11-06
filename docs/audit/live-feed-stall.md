# Postmortem: live feed stop stall (2026-11-06)

Status: fixed in 5fd611c. Severity: high for the first live-recording session;
no data corruption, no host mutation.

## Symptom

A user with the recorder capabilities granted started a live capture, recorded
for a few seconds, then pressed Stop. The native window stopped responding and
the process remained alive. The same stall occurred in headless Xvfb smoke
runs that joined the recorder tail shortly after start.

## Reproduction

- Real compact recorder state from the VM: 152,314 events, 2,186,471 bytes,
  one closed segment.
- `xsprof ui --follow-recorder <state> --smoke --duration 1000` under Xvfb
  hung consistently; 1 s was enough to make the 8 MiB bounded feed fill while
  the tail was still catching up.
- GDB backtrace showed the UI main thread in
  `follow_source.Source.stop -> Thread.join`, and the tail thread in
  `live_feed.Store.append -> std.mem.copyForwards`.

## Root cause

`stream/live_feed.zig` trims the bounded feed by removing exactly the current
overflow for each appended line:

```zig
while (bytes.len + data.len > max_bytes) {
    // find the first newline at/after the overflow point
    // copyForwards the whole remaining tail down
    // shrink
}
```

Once the 8 MiB feed is full, every ~160-byte scheduler line copies almost the
entire remaining feed. During catch-up the tail processes many events per
frame, so this is quadratic in feed size. Stop joins the tail, so the UI thread
waits for a very long sequence of multi-megabyte memmoves. The window is not
deadlocked; it is blocked in a pathological trim path.

The live controller was also allocated from the CLI process arena, which is
not thread-safe while the UI and tail both allocate. That was corrected to the
thread-safe SMP allocator as part of the fix.

## Fix

- Trim in one coarse step to half of `max_bytes` instead of removing the exact
  overflow per event. Trimming now happens once per half-buffer of appended
  data, so the copy cost is amortized.
- Allocate the live controller with `std.heap.smp_allocator`; the tail and the
  UI consume/rebuild from the same controller.
- Add a unit test that fills the store and asserts it stays bounded, ends on a
  line boundary, and keeps the byte offset.
- Add the feed trim explanation to the CHANGELOG.

## Verification

- The same full 152k-event state now passes
  `ui --follow-recorder ... --smoke --duration 1000` 5/5 runs (previously
  5/5 timed out at 10 s).
- `zig build check` and `zig build test` pass, including the new feed test.
- `qa/native_live_smoke.sh` passes under Xvfb (live probe correctly SKIPs when
  capabilities are absent; recorder-tail mode reads a fixture).
- The final privileged recording test could not be repeated in the agent shell
  after rebuilding, because rebuilding removed the file capabilities; the
  affected stop path is shared by the recorder tail and was reproduced and
  fixed with the full real state. Re-run `sudo setcap
  cap_perfmon,cap_dac_read_search+ep zig-out/bin/xsprof` before the manual
  recording retest.

## Follow-up

- The feed remains a copying buffer. If live rates ever exceed the UI drain
  rate for long periods, a head-index ring buffer would remove the remaining
  memmove and make trim O(1). Not required for the measured workload, but it is
  the next structural improvement.
- A trim resets the UI's feed offset, so the existing `feed_trim` loss marker
  is expected and visible; it is not silent data loss.
