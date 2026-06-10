//! Public scenario input helpers.
//!
//! Every parse/load helper allocates a fresh `model.ScenarioOwned` with the
//! caller-supplied allocator. Input buffers and file paths are not retained.
//! The returned scenario must be released exactly once with `deinit()` or
//! `freeScenario`.

const internal = @import("zig_scheduler_internal");

/// Parse object-style ZON or legacy text into an owned scenario.
///
/// `source` and `expected_name` are borrowed only for the duration of the call.
pub const parseScenarioText = internal.parseScenarioText;
/// Parse scenario text with no expected-name gate.
pub const parseScenario = internal.parseScenario;
/// Read a scenario file and return an owned scenario; the path slice is not retained.
pub const loadScenarioFile = internal.loadScenarioFile;
/// Convenience release helper for SDK callers that do not want to call `deinit` directly.
///
/// The allocator argument is accepted for API symmetry; ownership is tracked on
/// the owned scenario value.
pub const freeScenario = internal.freeScenario;
