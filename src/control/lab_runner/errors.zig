const std = @import("std");

pub const RunError = error{
    InvalidAction,
    InvalidField,
    InvalidSummary,
    OutOfMemory,
    StreamTooLong,
} || std.process.SpawnError || std.Io.File.MultiReader.UnendingError || std.Io.Timeout.Error || std.Io.Dir.ReadFileAllocError || std.Io.Writer.Error;
