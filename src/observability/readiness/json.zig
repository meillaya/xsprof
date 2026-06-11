const std = @import("std");
const sched_ext = @import("../../sched_ext/root.zig");
const types = @import("types.zig");

pub fn writeKernelReadinessJson(writer: anytype, kernel: types.KernelReadiness) !void {
    try writer.writeAll(",\"readiness\":");
    try writeFactStatus(writer, kernel.status);
    try writer.writeAll(",\"minimum_release\":");
    try writeJsonString(writer, kernel.minimum_release);
}

pub fn writeKernelConfigJson(writer: anytype, facts: types.KernelConfigFacts) !void {
    try writer.writeAll("{\"status\":");
    try writeFactStatus(writer, facts.status);
    try writer.writeAll(",\"source\":");
    try writeJsonString(writer, facts.source);
    try writer.writeAll(",\"sched_class_ext\":");
    try writeFactStatus(writer, facts.sched_class_ext);
    try writer.writeAll(",\"bpf\":");
    try writeFactStatus(writer, facts.bpf);
    try writer.writeAll(",\"bpf_syscall\":");
    try writeFactStatus(writer, facts.bpf_syscall);
    try writer.writeAll(",\"bpf_jit\":");
    try writeFactStatus(writer, facts.bpf_jit);
    try writer.writeAll(",\"bpf_jit_always_on\":");
    try writeFactStatus(writer, facts.bpf_jit_always_on);
    try writer.writeAll(",\"bpf_jit_default_on\":");
    try writeFactStatus(writer, facts.bpf_jit_default_on);
    try writer.writeAll(",\"debug_info_btf\":");
    try writeFactStatus(writer, facts.debug_info_btf);
    try writer.writeAll("}");
}

pub fn writeBpfJitSysctlsJson(writer: anytype, facts: types.BpfJitSysctlFacts) !void {
    try writer.writeAll("{");
    try writeNamedTextFact(writer, "enable", facts.enable);
    try writer.writeAll(",");
    try writeNamedTextFact(writer, "harden", facts.harden);
    try writer.writeAll(",");
    try writeNamedTextFact(writer, "kallsyms", facts.kallsyms);
    try writer.writeAll("}");
}

pub fn writeToolchainJson(writer: anytype, facts: types.ToolchainFacts) !void {
    try writer.writeAll("{");
    try writeNamedTextFact(writer, "bpftool", facts.bpftool);
    try writer.writeAll(",");
    try writeNamedTextFact(writer, "clang", facts.clang);
    try writer.writeAll(",");
    try writeNamedTextFact(writer, "llvm", facts.llvm);
    try writer.writeAll(",");
    try writeNamedTextFact(writer, "libbpf_pkg_config", facts.libbpf_pkg_config);
    try writer.writeAll("}");
}

pub fn writePrivilegesJson(writer: anytype, facts: types.PrivilegeFacts) !void {
    try writer.writeAll("{\"status\":");
    try writeFactStatus(writer, facts.status);
    try writer.print(",\"cap_bpf\":{},\"cap_sys_admin\":{},\"cap_perfmon\":{}", .{ facts.cap_bpf, facts.cap_sys_admin, facts.cap_perfmon });
    try writer.writeAll("}");
}

fn writeNamedTextFact(writer: anytype, name: []const u8, fact: sched_ext.TextFact) !void {
    try writeJsonString(writer, name);
    try writer.writeAll(":{\"status\":");
    try writeFactStatus(writer, fact.status);
    try writer.writeAll(",\"value\":");
    try writeJsonString(writer, fact.value);
    try writer.writeAll("}");
}

fn writeFactStatus(writer: anytype, status: types.FactStatus) !void {
    try writeJsonString(writer, @tagName(status));
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u{x:0>4}", .{byte}) else try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}
