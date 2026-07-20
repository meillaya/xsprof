# Independent Code Review — xsprof C++ Rewrite

**Reviewer:** worker-1 (independent, did not write this code)
**Date:** 2026-07-20
**Scope:** src/collectors/live_capture.cpp, src/safety/safety.cpp, src/core/privacy.cpp, src/daemon/daemon.cpp, src/sched/collector.cpp, src/memory/collector.cpp, src/cli/main.cpp, src/viz/chrome_trace.cpp, src/advisor/advisor.cpp, include/xsprof/live_capture.hpp, include/xsprof/safety.hpp
**Safety contract under review:** fail-closed read-only by default; host_mutation=false on every record; unsafe verbs refuse non-zero; mutation VM-lab-only (audit-id + rollback-id + lab marker); capability-gated collectors SKIP when unprivileged and never auto-elevate; privacy filtering excludes argv/env/secrets; advisor recommendations printed, never auto-applied.

---

## Safety Contract Verification

| Invariant | Status | Evidence |
|-----------|--------|----------|
| Fail-closed read-only by default | **HOLDS** | CLI refuses unknown verbs via `write_refusal()` (main.cpp:296); `SafetyGate::decide()` defaults to `allow_mutate=false` (safety.cpp:42); collectors return `CapState::Skip` when unprivileged |
| host_mutation=false on every record | **HOLDS** | `DaemonEvent::to_json()` hardcodes `false` (daemon.cpp:167); `event_to_json()` hardcodes `false` (event.cpp:70); CLI refusal/preflight/capture-summary all set `false`; `event_from_json()` rejects `host_mutation=true` (daemon.cpp:201-202); tests verify this across all surfaces |
| Unsafe verbs refuse non-zero | **HOLDS** | `is_unsafe_verb()` covers load/attach/enable/mutate/apply + 4 more (safety.cpp:28-35); CLI checks before dispatch and returns 1 (main.cpp:289-291); unknown verbs also refuse (main.cpp:296) |
| Mutation VM-lab-only | **HOLDS** | `SafetyGate::decide()` requires `allow_mutate && vm_lab_marker && !audit_id.empty() && !rollback_id.empty()` (safety.cpp:42-56); daemon refuses all lab actions on host with `refused_host` (daemon.cpp:393-401) |
| Capability-gated SKIP, never auto-elevate | **HOLDS** | `LiveCapture::probe()` returns Skip on perf_event_open failure (live_capture.cpp:87-99); `SchedCollector::probe()` checks paranoid>=2 and returns Skip (sched/collector.cpp:82-90); `MemoryCollector::probe()` same pattern (memory/collector.cpp:22-33); no setuid/capset/syscall elevation anywhere |
| Privacy filtering excludes argv/env/secrets | **HOLDS** | `event_to_json()` calls `sanitize_event()` on every serialized event (event.cpp:55-57); `PrivacyFilter::redact()` catches 12 sensitive key patterns + 6 value markers (privacy.cpp:30-38); `bound_comm()` limits to 15 chars (privacy.cpp:82); `cmd_record` applies privacy before output (main.cpp:247-250) |
| Advisor recommendations printed, never auto-applied | **HOLDS** | `Advisor::report_json()` and `report_markdown()` only emit findings/recommendations as data (advisor.cpp:210-260); markdown explicitly states "suggestions only — never auto-applied" (advisor.cpp:252); no exec/system/fork calls in advisor |

---

## Findings

### F-01: Out-of-bounds read in perf ring-buffer raw sample parsing
- **File:** src/collectors/live_capture.cpp:228-260 (drain lambda, SW/WK/MG branches)
- **Severity:** HIGH
- **Description:** `read_u32(raw, offset)` performs `memcpy(&v, base + offset, 4)` without validating that `offset + 4 <= raw_size`. The `raw_size` field is read from the sample record (lines 228-229, 241-242, 249-250) but never used for bounds checking. The offsets come from tracepoint format files (`parse_format`), which are kernel-provided and normally correct, but a malformed or truncated raw sample (e.g., from a corrupted ring buffer or a kernel bug) would cause an out-of-bounds heap read. Similarly, `memcpy(comm, raw + sw_fmt["next_comm"].first, 16)` at line ~237 copies 16 bytes without checking `offset + 16 <= raw_size`.
- **Suggested fix:** Before each `read_u32` or `memcpy` from `raw`, validate `offset + sizeof(uint32_t) <= raw_size` (or `offset + 16 <= raw_size` for comm). Skip the field or zero-fill if out of bounds. Example:
  ```cpp
  if (sw_fmt.count("next_pid") && sw_fmt["next_pid"].first + 4 <= raw_size)
      e.a = read_u32(raw, sw_fmt["next_pid"].first);
  ```

### F-02: Missing bounds check on sample record header within ring buffer
- **File:** src/collectors/live_capture.cpp:207-215 (drain lambda)
- **Severity:** HIGH
- **Description:** The drain loop reads `perf_event_header` via `memcpy(&hdr, data + pos, sizeof(hdr))` where `pos = tail % data_size`. If the record wraps around the ring buffer boundary, the `memcpy` for the header itself could read past the end of the mapped region when `pos + sizeof(hdr) > data_size`. The subsequent byte-by-byte copy loop (`rec[b] = data[(pos + b) % data_size]`) handles wrapping correctly for the payload, but the initial header read does not. On a corrupted `hdr.size` value (e.g., 0 or very large), the loop `for (uint32_t b = 0; b < hdr.size; ++b)` could allocate a huge vector or loop excessively. The check `if (hdr.size < sizeof(hdr)) break;` guards against small sizes but not against extremely large ones.
- **Suggested fix:** (a) Read the header byte-by-byte with modular indexing like the payload, or ensure `pos + sizeof(hdr) <= data_size` before the memcpy. (b) Add an upper-bound sanity check on `hdr.size` (e.g., `hdr.size > data_size` → break/skip).

### F-03: `const_cast` to mutate JSON array — fragile and bypasses API design
- **File:** src/viz/chrome_trace.cpp:336, 383, 420
- **Severity:** MEDIUM
- **Description:** Three locations use `const_cast<json::Array*>(&doc.find("traceEvents")->as_array())` to append a SAMPLE_LOSS marker to the traceEvents array. `find()` returns `const Value*` and `as_array()` returns `const Array&`. While the underlying `doc` object is non-const (so this is technically not undefined behavior per the C++ standard), it bypasses the json::Value API's const-correctness design and is fragile: if `doc` were ever made const, or if the JSON library changed its internal storage, this would become UB. The json::Value class already provides `operator[]` (non-const) and `push_back()` which could be used instead.
- **Suggested fix:** Replace `const_cast` with the existing mutable API:
  ```cpp
  doc["traceEvents"].push_back(std::move(marker));
  ```
  Or add a non-const `find()` / `as_array()` overload to `json::Value`.

### F-04: perf events opened enabled — sample loss before mmap setup
- **File:** src/collectors/live_capture.cpp:103-126 (`open_tracepoint`, `open_software`)
- **Severity:** MEDIUM
- **Description:** Both `open_tracepoint` and `open_software` zero-initialize `perf_event_attr` via `memset`, leaving `attr.disabled = 0`. This means the perf event starts counting immediately upon `perf_event_open()`. However, the ring buffer is not mmap'd until after the fd is returned to `run()` (lines 155-175). Events occurring between open and mmap setup are lost silently. By contrast, `probe()` correctly sets `attr.disabled = 1` (line 82). The `#include <sys/ioctl.h>` is present but no `ioctl(PERF_EVENT_IOC_ENABLE)` call exists anywhere, confirming the code relies on events being enabled from creation.
- **Suggested fix:** Set `attr.disabled = 1` in both `open_tracepoint` and `open_software`. After all slots are mmap'd and pollfds are set up, issue `ioctl(fd, PERF_EVENT_IOC_ENABLE, 0)` on each slot fd to start counting atomically. Remove the unused `#include <sys/ioctl.h>` if ioctl is not used, or use it properly.

### F-05: Unused `mmap_pages` parameter in `open_tracepoint` / `open_software`
- **File:** src/collectors/live_capture.cpp:103, 115; include/xsprof/live_capture.hpp:58-59
- **Severity:** LOW
- **Description:** Both functions accept an `int mmap_pages` parameter that is never used in the function body. The actual mmap size calculation happens in `run()` using `cfg.mmap_pages`. This is a dead parameter that misleads callers into thinking it controls the ring buffer size at open time.
- **Suggested fix:** Remove the `mmap_pages` parameter from both function signatures, or use it to set `attr.wakeup_events` or validate against the caller's intended mmap size.

### F-06: `replay_transcript` allows seq=0 rows to bypass monotonicity validation
- **File:** src/daemon/daemon.cpp:340-344
- **Severity:** MEDIUM
- **Description:** The monotonicity check `if (evt.seq > 0 && evt.seq <= prev_seq)` skips validation for rows with `seq == 0`. A malformed transcript could inject arbitrary rows with `seq=0` interspersed between valid rows, bypassing the ordering guarantee. The `prev_seq` variable is not updated for seq=0 rows, so subsequent valid rows are still checked against the last non-zero seq, but the seq=0 rows themselves are passed through to output without ordering validation.
- **Suggested fix:** Either reject seq=0 rows outright (if seq is required to be positive), or track them separately and validate that they don't violate the transcript's integrity. If seq=0 is a valid "unsequenced" marker, document this explicitly and ensure downstream consumers handle it.

### F-07: `cmd_record` duplicates privacy logic instead of using `sanitize_event`
- **File:** src/cli/main.cpp:247-250
- **Severity:** LOW
- **Description:** The record command manually applies `PrivacyFilter::bound_comm()` and `pf.redact()` to each event, duplicating the logic already encapsulated in `sanitize_event()` (privacy.cpp:96-104). If `sanitize_event` is later updated (e.g., to redact additional fields or handle new event kinds), `cmd_record` will not pick up the changes. The `event_to_json()` function (event.cpp:55-57) already calls `sanitize_event` internally, so the manual sanitization in `cmd_record` is redundant for events serialized via `event_to_json`.
- **Suggested fix:** Remove the manual sanitization loop in `cmd_record` and rely on `event_to_json()`'s built-in sanitization, or call `sanitize_event()` directly for clarity.

### F-08: `SafePath::under` performs lexical-only path resolution (no symlink resolution)
- **File:** src/safety/safety.cpp:62-99
- **Severity:** MEDIUM
- **Description:** `SafePath::under` resolves `..` and `.` components lexically (string manipulation) without resolving symbolic links. If an attacker can create a symlink inside the state directory pointing outside (e.g., `state-dir/evil -> /etc`), the lexical check would pass `evil/passwd` as safe, but the actual filesystem path would escape the root. This is a TOCTOU vulnerability if the state directory is writable by non-daemon users.
- **Suggested fix:** After lexical resolution, call `realpath()` on the resolved path and verify the canonical path still starts with the canonical root. Alternatively, use `O_NOFOLLOW` / `openat()` with `O_RESOLVE_BENEATH` (Linux 5.6+) when opening files under the state directory. Document the threat model: if the state directory is exclusively owned by the daemon user, the risk is reduced.

### F-09: `pending_wakeups_` vector can grow large under burst wakeup load
- **File:** src/sched/collector.cpp:148-163 (`record_wakeup`)
- **Severity:** LOW
- **Description:** `record_wakeup` appends to `pending_wakeups_` and prunes records older than the correlation window (default 1ms). During a burst of wakeups within the window (e.g., a thundering herd), the vector grows linearly with the burst size. For very high wakeup rates (>1M wakeups/ms), this could consume significant memory. The pruning also removes matched records, but only on the next wakeup call — if switches arrive without wakeups, matched records accumulate until the next wakeup.
- **Suggested fix:** Add a hard cap on `pending_wakeups_.size()` (e.g., 100K entries) and drop oldest unmatched records when exceeded. Consider pruning matched records in `record_switch` as well.

### F-10: `std::stoull` without exception handling in hugepages parser
- **File:** src/memory/collector.cpp:196-201 (`poll_hugepages`)
- **Severity:** LOW
- **Description:** `hp.size_kb = std::stoull(num_str)` can throw `std::invalid_argument` or `std::out_of_range` if the directory name has an unexpected format (e.g., `hugepages-` with no digits, or an extremely large number). The code checks `!num_str.empty()` but doesn't catch exceptions. A malformed sysfs entry would crash the profiler.
- **Suggested fix:** Wrap in try/catch or use `strtoull` with error checking:
  ```cpp
  char* end = nullptr;
  unsigned long long val = strtoull(num_str.c_str(), &end, 10);
  if (end != num_str.c_str() && *end == '\0') hp.size_kb = val;
  ```

### F-11: `add_metadata_name` overwrites `e.name` with "process_name"
- **File:** src/viz/chrome_trace.cpp:24-35
- **Severity:** LOW
- **Description:** The function first sets `e.name = group_name` (line 26), then overwrites it with `e.name = "process_name"` (line 32). The first assignment is dead code. The Chrome Trace format expects `name` to be `"process_name"` for metadata events, so the final value is correct, but the initial assignment is confusing.
- **Suggested fix:** Remove the first `e.name = group_name` assignment.

### F-12: Hardcoded 100ms gap detection threshold
- **File:** src/viz/chrome_trace.cpp:310, 365, 408
- **Severity:** LOW
- **Description:** Gap detection uses a hardcoded threshold of `100000000ULL` ns (100ms) between consecutive events. For high-frequency sched_switch workloads (e.g., 10K switches/sec), 100ms is reasonable. For low-frequency workloads or long idle periods, this may produce false-positive SAMPLE_LOSS markers. The threshold is not configurable.
- **Suggested fix:** Make the gap threshold configurable via `CaptureConfig` or a timeline option, with 100ms as the default. Document the heuristic.

### F-13: Privacy filter `redact()` tokenizer may miss secrets in quoted or multi-token values
- **File:** src/core/privacy.cpp:55-80
- **Severity:** LOW
- **Description:** `redact()` splits on space, comma, and semicolon. A secret value like `password="my secret pass"` would be tokenized as `password="my`, `secret`, `pass"`. The key `password` would be caught and redacted, but the value tokens `secret` and `pass"` would be emitted as separate tokens. The `sensitive_value()` check would catch `secret` as a standalone token (it matches the "secret" marker), but arbitrary secret values without known markers could leak. This is a defense-in-depth concern; the primary protection is that argv/env should never enter the `detail` field in the first place.
- **Suggested fix:** Consider handling quoted values as a single token, or document that `detail` fields must not contain raw argv/env material (the privacy filter is a secondary safety net, not the primary boundary).

### F-14: `PerfEvent` RAII class in sched collector is well-designed (positive note)
- **File:** src/sched/collector.cpp:24-48; include/xsprof/sched_collector.hpp:20-38
- **Severity:** N/A (positive)
- **Description:** The `PerfEvent` class correctly deletes copy constructor/assignment, implements move semantics, and closes the fd in the destructor. This prevents fd leaks and double-close bugs. Good pattern.

### F-15: `event_to_json` applies privacy sanitization on every serialization (positive note)
- **File:** src/core/event.cpp:53-57
- **Severity:** N/A (positive)
- **Description:** Every `RawEvent` serialized via `event_to_json()` is sanitized through `sanitize_event()` before output. This is a fail-closed privacy boundary that ensures no caller can accidentally emit unsanitized events. Well-designed invariant.

---

## Summary Statistics

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 4 |
| Low | 6 |
| Positive notes | 2 |

---

## Overall Assessment

The safety contract **holds across all reviewed surfaces**. The fail-closed design is consistent: unsafe verbs refuse non-zero, host_mutation=false is hardcoded in every serialization path and validated on ingestion, capability probes SKIP when unprivileged without any auto-elevation, the safety gate requires VM-lab marker + audit-id + rollback-id for any mutation, and advisor recommendations are output-only.

The two HIGH findings (F-01, F-02) are memory-safety issues in the perf ring-buffer parsing hot path. They require a malformed or truncated kernel sample to trigger, making them unlikely in normal operation but real vulnerabilities in adversarial or buggy-kernel scenarios. These should be fixed before any production-adjacent use.

The MEDIUM findings (F-03 through F-08) are correctness and robustness issues that don't violate the safety contract but could cause silent data loss, fragile code paths, or edge-case crashes.

The LOW findings are code quality and hardening improvements.

VERDICT: APPROVE WITH COMMENTS
