# Timeline Streaming Stress Test

**Status:** PASS — multi-gigabyte captures now export with bounded memory.

## Problem (found by deeper review + stress test)

`xsprof timeline --chunk-size N` loaded the **entire** journal into memory
(`replay_from_journal` accumulated every event) and only chunked the *output*,
so memory scaled with the whole journal.

## Measurement (2,000,000-event / 312 MB journal)

| Path | Peak RSS | Wall time |
| --- | --- | --- |
| Before (output-only chunking, chunk 100k) | **12,400 MB** | 14.9 s |
| After streaming (chunk 100,000) | **502 MB** | 10.5 s |
| After streaming (chunk 20,000) | **107 MB** | 10.5 s |

Memory is now O(chunk_size), not O(journal). A multi-GB journal uses the same
~100–500 MB (tunable via `--chunk-size`) instead of exhausting memory.

## Fix

`xsprof::viz::stream_timeline_chunked(in, out, chunk_size, rows)` reads the
journal line-by-line, converts events in batches of `chunk_size`, writes each
chunk to the output stream, and discards it — holding at most one chunk in
memory. Gap/sample-loss markers are still emitted per chunk. `xsprof timeline`
gains `--output <file>` and uses the streaming path whenever `--chunk-size > 0`.

## Verification

- Output is well-formed JSON: 5,000 events -> 5 chunks of ~1,000 events, each
  with `traceEvents` + `displayTimeUnit`.
- Full test suite: 118/118 pass.
- Reproduce: `python3 qa/vm-cpp/gen_large_journal.py 2000000 <out>` then
  `python3 qa/vm-cpp/measure_timeline.py <chunk_size>`.
