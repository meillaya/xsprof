//! Analysis-time symbolization for sampled stack addresses.
//!
//! Inputs are user-supplied and read-only: an optional ELF binary (function
//! symbol table), an optional `/proc/kallsyms`-format text file, and the
//! optional local `session.maps.ndjson` sidecar written by the sampling
//! recorder (ELF load bias). Nothing here resolves DWARF, debuginfod, JIT
//! symbols, or invents a name: an address that cannot be matched stays
//! unresolved (`0x...` in the folded/script writers).
//!
//! Bounds: one binary per run, symbol tables capped by count and bytes, names
//! truncated to `max_name_bytes`, nearest-symbol distance capped at
//! `max_symbol_offset`, kernel kallsyms capped by file bytes and count.

const std = @import("std");
const builtin = @import("builtin");
const maps = @import("../os/linux/maps.zig");

pub const max_name_bytes = 256;
pub const max_symbols = 262_144;
/// `/proc/kallsyms` on a normal kernel has ~250k-450k symbols, more than an ELF
/// `.symtab` budget allows; keep a separate bounded cap so analysis-time kernel
/// symbolization works instead of failing with TooManySymbols. The 32 MiB text
/// bound still limits total memory.
pub const max_kallsyms_symbols = 1_048_576;
pub const max_elf_bytes = 128 * 1024 * 1024;
pub const max_symtab_bytes = 8 * 1024 * 1024;
pub const max_strtab_bytes = 16 * 1024 * 1024;
pub const max_kallsyms_bytes = 32 * 1024 * 1024;
pub const max_section_headers = 4096;
pub const max_nearest_offset: u64 = 1 << 20;

pub const Error = error{
    BinaryUnreadable,
    InvalidElf,
    UnsupportedElf,
    KallsymsUnreadable,
    KallsymsEmpty,
    OutOfMemory,
    TooManySymbols,
};

pub const Symbol = struct {
    addr: u64,
    name: []const u8,
};

pub const Binary = struct {
    symbols: []const Symbol = &.{},
    /// ET_EXEC binaries are loaded at their link address; ET_DYN need a bias
    /// from the maps sidecar.
    executable: bool = false,
    min_vaddr: u64 = 0,
    max_vaddr: u64 = 0,
};

pub const Kallsyms = struct {
    symbols: []const Symbol = &.{},
};

pub const Frame = struct {
    resolved: bool = false,
    kernel: bool = false,
    name: []const u8 = "",
    offset: u64 = 0,
};

pub const LoadOptions = struct {
    binary_path: ?[]const u8 = null,
    maps_path: ?[]const u8 = null,
    kallsyms_path: ?[]const u8 = null,
};

/// Kernel-space address test for the 64-bit architectures xsprof supports.
pub fn isKernelAddress(address: u64) bool {
    if (comptime @sizeOf(usize) < 8) return false;
    return address >= 0xffff_0000_0000_0000;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn sortSymbols(symbols: []Symbol) void {
    std.mem.sortUnstable(Symbol, symbols, {}, struct {
        fn less(_: void, a: Symbol, b: Symbol) bool {
            if (a.addr != b.addr) return a.addr < b.addr;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
}

fn duplicateName(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const bounded = text[0..@min(text.len, max_name_bytes)];
    return allocator.dupe(u8, bounded);
}

const SectionHeader = struct {
    sh_type: u32,
    sh_offset: u64,
    sh_size: u64,
    sh_link: u32,
    sh_entsize: u64,
};

fn parseSection(bytes: []const u8, shoff: u64, index: usize, shentsize: usize) SectionHeader {
    const base: usize = @as(usize, @intCast(shoff)) + index * shentsize;
    return .{
        .sh_type = readU32(bytes, base + 4),
        .sh_offset = readU64(bytes, base + 24),
        .sh_size = readU64(bytes, base + 32),
        .sh_link = readU32(bytes, base + 40),
        .sh_entsize = readU64(bytes, base + 56),
    };
}

const ElfView = struct {
    executable: bool,
    shoff: u64,
    shentsize: usize,
    shnum: usize,
};

fn parseElfHeader(bytes: []const u8) Error!ElfView {
    if (bytes.len < 64) return error.InvalidElf;
    if (!eql(bytes[0..4], "\x7fELF")) return error.InvalidElf;
    if (bytes[4] != 2) return error.UnsupportedElf; // ELFCLASS64 only
    if (bytes[5] != 1) return error.UnsupportedElf; // little-endian only
    if (bytes[6] != 1) return error.InvalidElf;
    const e_type = readU16(bytes, 16);
    const shoff = readU64(bytes, 40);
    const shentsize = readU16(bytes, 58);
    const shnum = readU16(bytes, 60);
    if (e_type != 1 and e_type != 2 and e_type != 3 and e_type != 4) return error.UnsupportedElf;
    if (shentsize < 64) return error.InvalidElf;
    if (shoff == 0 or shnum == 0) return error.UnsupportedElf;
    if (shnum > max_section_headers) return error.UnsupportedElf;
    return .{
        .executable = e_type == 2,
        .shoff = shoff,
        .shentsize = shentsize,
        .shnum = shnum,
    };
}

const SymbolTable = struct {
    symtab: SectionHeader,
    strtab: SectionHeader,
};

fn findSymbolTable(view: ElfView, bytes: []const u8) Error!SymbolTable {
    var chosen: ?SymbolTable = null;
    var index: usize = 0;
    while (index < view.shnum) : (index += 1) {
        const section = parseSection(bytes, view.shoff, index, view.shentsize);
        if (section.sh_entsize != 24 or section.sh_size == 0) continue;
        if (section.sh_type != 2 and section.sh_type != 11) continue; // SYMTAB, DYNSYM
        if (section.sh_link >= view.shnum) continue;
        const strtab = parseSection(bytes, view.shoff, section.sh_link, view.shentsize);
        if (strtab.sh_size == 0 or strtab.sh_offset + strtab.sh_size > bytes.len) continue;
        if (section.sh_offset + section.sh_size > bytes.len) continue;
        // Prefer the full .symtab over .dynsym regardless of section order.
        const candidate = SymbolTable{ .symtab = section, .strtab = strtab };
        if (chosen == null or section.sh_type == 2) {
            chosen = candidate;
            if (section.sh_type == 2) break;
        }
    }
    return chosen orelse error.UnsupportedElf;
}

const ParsedSymbols = struct {
    symbols: []const Symbol,
    min_vaddr: u64,
    max_vaddr: u64,
};

fn parseSymbolTable(
    allocator: std.mem.Allocator,
    symtab: []const u8,
    strtab: []const u8,
) Error!ParsedSymbols {
    var list: std.ArrayList(Symbol) = .empty;
    errdefer list.deinit(allocator);
    var min_vaddr: u64 = std.math.maxInt(u64);
    var max_vaddr: u64 = 0;
    var at: usize = 0;
    while (at + 24 <= symtab.len) : (at += 24) {
        const name_offset = readU32(symtab, at);
        const info = symtab[at + 4];
        const shndx = readU16(symtab, at + 6);
        const value = readU64(symtab, at + 8);
        const size = readU64(symtab, at + 16);
        const kind = info & 0xf;
        if (shndx == 0 or value == 0) continue; // undefined
        if (kind != 0 and kind != 2 and kind != 10) continue; // NOTYPE, FUNC, GNU_IFUNC
        if (name_offset >= strtab.len) continue;
        const tail = strtab[name_offset..];
        const name_end = std.mem.indexOfScalar(u8, tail, 0) orelse continue;
        if (name_end == 0) continue;
        if (list.items.len >= max_symbols) return error.TooManySymbols;
        try list.append(allocator, .{
            .addr = value,
            .name = try duplicateName(allocator, tail[0..name_end]),
        });
        min_vaddr = @min(min_vaddr, value);
        max_vaddr = @max(max_vaddr, value + @max(size, 1));
    }
    const symbols = try list.toOwnedSlice(allocator);
    sortSymbols(symbols);
    return .{
        .symbols = symbols,
        .min_vaddr = if (min_vaddr == std.math.maxInt(u64)) 0 else min_vaddr,
        .max_vaddr = max_vaddr,
    };
}

/// Parse ELF bytes in memory. The returned names are owned by `allocator`.
pub fn parseBinaryBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!Binary {
    if (bytes.len > max_elf_bytes) return error.UnsupportedElf;
    const view = try parseElfHeader(bytes);
    if (view.shoff + view.shnum * view.shentsize > bytes.len) return error.InvalidElf;
    const table = try findSymbolTable(view, bytes);
    const sym_start: usize = @intCast(table.symtab.sh_offset);
    const sym_len: usize = @intCast(@min(table.symtab.sh_size, max_symtab_bytes));
    const str_start: usize = @intCast(table.strtab.sh_offset);
    const str_len: usize = @intCast(@min(table.strtab.sh_size, max_strtab_bytes));
    const parsed_symbols = try parseSymbolTable(
        allocator,
        bytes[sym_start .. sym_start + sym_len],
        bytes[str_start .. str_start + str_len],
    );
    return .{
        .symbols = parsed_symbols.symbols,
        .executable = view.executable,
        .min_vaddr = parsed_symbols.min_vaddr,
        .max_vaddr = parsed_symbols.max_vaddr,
    };
}

fn openPath(io: std.Io, path: []const u8) Error!std.Io.File {
    if (path.len != 0 and path[0] == '/') {
        return std.Io.Dir.openFileAbsolute(io, path, .{}) catch error.BinaryUnreadable;
    }
    return std.Io.Dir.cwd().openFile(io, path, .{}) catch error.BinaryUnreadable;
}

/// Load an ELF file with positional reads: only the ELF header and the symbol
/// sections are read, so a large debug binary does not have to fit in memory
/// beyond the documented symbol-table bounds.
pub fn loadBinaryFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) Error!Binary {
    const file = try openPath(io, path);
    defer file.close(io);
    const stat = file.stat(io) catch return error.BinaryUnreadable;
    if (stat.size < 64 or stat.size > max_elf_bytes) return error.UnsupportedElf;
    var header: [64]u8 = undefined;
    readPositional(io, file, &header, 0) catch return error.BinaryUnreadable;
    const view = try parseElfHeader(&header);
    if (view.shoff > stat.size or view.shoff + view.shnum * view.shentsize > stat.size) {
        return error.InvalidElf;
    }
    const section_bytes_len = view.shnum * view.shentsize;
    const column = try allocator.alloc(u8, section_bytes_len);
    defer allocator.free(column);
    readPositional(io, file, column, view.shoff) catch return error.BinaryUnreadable;

    var table = SymbolTable{
        .symtab = .{ .sh_type = 0, .sh_offset = 0, .sh_size = 0, .sh_link = 0, .sh_entsize = 0 },
        .strtab = .{ .sh_type = 0, .sh_offset = 0, .sh_size = 0, .sh_link = 0, .sh_entsize = 0 },
    };
    var found = false;
    var index: usize = 0;
    while (index < view.shnum) : (index += 1) {
        const section = parseSection(column, 0, index, view.shentsize);
        if (section.sh_entsize != 24 or section.sh_size == 0) continue;
        if (section.sh_type != 2 and section.sh_type != 11) continue;
        if (section.sh_link >= view.shnum) continue;
        const strtab = parseSection(column, 0, section.sh_link, view.shentsize);
        if (strtab.sh_size == 0) continue;
        if (section.sh_offset +| section.sh_size > stat.size) continue;
        if (strtab.sh_offset +| strtab.sh_size > stat.size) continue;
        table.symtab = section;
        table.strtab = strtab;
        found = true;
        if (section.sh_type == 2) break;
    }
    if (!found) return error.UnsupportedElf;
    const sym_len: usize = @intCast(@min(table.symtab.sh_size, max_symtab_bytes));
    const str_len: usize = @intCast(@min(table.strtab.sh_size, max_strtab_bytes));
    const sym_bytes = try allocator.alloc(u8, sym_len);
    defer allocator.free(sym_bytes);
    const str_bytes = try allocator.alloc(u8, str_len);
    defer allocator.free(str_bytes);
    readPositional(io, file, sym_bytes, table.symtab.sh_offset) catch return error.BinaryUnreadable;
    readPositional(io, file, str_bytes, table.strtab.sh_offset) catch return error.BinaryUnreadable;
    const parsed_symbols = try parseSymbolTable(allocator, sym_bytes, str_bytes);
    return .{
        .symbols = parsed_symbols.symbols,
        .executable = view.executable,
        .min_vaddr = parsed_symbols.min_vaddr,
        .max_vaddr = parsed_symbols.max_vaddr,
    };
}

fn readPositional(io: std.Io, file: std.Io.File, buffer: []u8, offset: u64) !void {
    const read = try file.readPositionalAll(io, buffer, offset);
    if (read != buffer.len) return error.BinaryUnreadable;
}

/// Parse `/proc/kallsyms`-format text (`ADDR TYPE NAME [MODULE]`). Zero
/// addresses (kptr_restrict) are skipped; an all-zero file is an explicit
/// error instead of resolving everything to the first symbol.
pub fn parseKallsyms(allocator: std.mem.Allocator, text: []const u8) Error!Kallsyms {
    var list: std.ArrayList(Symbol) = .empty;
    errdefer list.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var cursor: usize = 0;
        while (cursor < line.len and line[cursor] != ' ' and line[cursor] != '\t') : (cursor += 1) {}
        if (cursor == 0 or cursor >= line.len) continue;
        const address = std.fmt.parseInt(u64, line[0..cursor], 16) catch continue;
        const after = std.mem.trimStart(u8, line[cursor..], " \t");
        if (after.len < 2) continue;
        if (after[1] != ' ' and after[1] != '\t') continue; // single type char
        const name_start = 2;
        var name = std.mem.trimStart(u8, after[name_start..], " \t");
        if (name.len == 0) continue;
        if (std.mem.indexOfScalar(u8, name, ' ')) |space| name = name[0..space]; // drop [module]
        if (name.len == 0) continue;
        if (address == 0) continue; // kptr_restrict: no symbolization evidence
        if (list.items.len >= max_kallsyms_symbols) return error.TooManySymbols;
        try list.append(allocator, .{
            .addr = address,
            .name = try duplicateName(allocator, name),
        });
    }
    if (list.items.len == 0) return error.KallsymsEmpty;
    const symbols = try list.toOwnedSlice(allocator);
    sortSymbols(symbols);
    return .{ .symbols = symbols };
}

/// Read a bounded text file with a streaming reader. Size-hint APIs are wrong
/// for procfs files (they report size 0), which matters for the common
/// `--kallsyms /proc/kallsyms` invocation; stream instead so the content is
/// actually read. Returns null on open/read failure.
fn readTextFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    const file = if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max)) catch null;
}

pub fn loadKallsymsFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) Error!Kallsyms {
    const text = readTextFile(io, allocator, path, max_kallsyms_bytes) orelse
        return error.KallsymsUnreadable;
    return parseKallsyms(allocator, text);
}

fn nearest(symbols: []const Symbol, address: u64) ?usize {
    if (symbols.len == 0) return null;
    var low: usize = 0;
    var high: usize = symbols.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (symbols[mid].addr <= address) low = mid + 1 else high = mid;
    }
    if (low == 0) return null;
    return low - 1;
}

fn lookup(symbols: []const Symbol, address: u64) ?Frame {
    const index = nearest(symbols, address) orelse return null;
    const symbol = symbols[index];
    if (address < symbol.addr) return null;
    const delta = address - symbol.addr;
    if (delta > max_nearest_offset) return null;
    return .{ .resolved = true, .name = symbol.name, .offset = delta };
}

pub const Symbolizer = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    binary: ?Binary = null,
    module: ?maps.Module = null,
    kernel: ?Kallsyms = null,
    binary_path: []const u8 = "",
    kernel_path: []const u8 = "",
    maps_path: []const u8 = "",

    pub fn create(allocator: std.mem.Allocator) Symbolizer {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Symbolizer) void {
        self.arena.deinit();
        self.binary = null;
        self.module = null;
        self.kernel = null;
    }

    pub fn setBinaryBytes(self: *Symbolizer, bytes: []const u8) Error!void {
        self.binary = try parseBinaryBytes(self.arena.allocator(), bytes);
    }

    pub fn setKallsymsText(self: *Symbolizer, text: []const u8) Error!void {
        self.kernel = try parseKallsyms(self.arena.allocator(), text);
    }

    pub fn setModule(self: *Symbolizer, module: maps.Module) void {
        self.module = module;
    }

    /// Load the requested symbol sources. Unreadable or malformed user input is
    /// an explicit error; a data-only binary with no symbol table stays a valid
    /// (all-unresolved) binary rather than being reported as readable symbols.
    pub fn load(io: std.Io, allocator: std.mem.Allocator, options: LoadOptions) !Symbolizer {
        var symbolizer = Symbolizer.create(allocator);
        errdefer symbolizer.deinit();
        const arena = symbolizer.arena.allocator();
        if (options.binary_path) |path| {
            symbolizer.binary_path = try arena.dupe(u8, path);
            symbolizer.binary = loadBinaryFile(io, arena, path) catch |err| switch (err) {
                // A binary without a section table can still be a valid
                // module; mark it present with an empty symbol table.
                error.UnsupportedElf => .{},
                else => return err,
            };
        }
        if (options.maps_path) |path| {
            symbolizer.maps_path = try arena.dupe(u8, path);
            const records = maps.readSidecar(io, arena, path) catch |err| switch (err) {
                error.MapsUnavailable => return error.BinaryUnreadable,
                else => return err,
            };
            if (symbolizer.binary_path.len != 0) {
                symbolizer.module = maps.moduleFromRecords(records, symbolizer.binary_path);
            }
        }
        if (options.kallsyms_path) |path| {
            symbolizer.kernel_path = try arena.dupe(u8, path);
            const text = readTextFile(io, arena, path, max_kallsyms_bytes) orelse
                return error.KallsymsUnreadable;
            symbolizer.kernel = try parseKallsyms(arena, text);
        }
        return symbolizer;
    }

    pub fn binarySymbols(self: *const Symbolizer) usize {
        return if (self.binary) |binary| binary.symbols.len else 0;
    }

    pub fn kernelSymbols(self: *const Symbolizer) usize {
        return if (self.kernel) |kernel| kernel.symbols.len else 0;
    }

    /// Resolve one runtime address. Kernel addresses use kallsyms directly;
    /// user addresses are only resolved when the address lies in the loaded
    /// module (or, without a maps sidecar, in an ET_EXEC image's link range).
    pub fn resolve(self: *const Symbolizer, address: u64) Frame {
        if (isKernelAddress(address)) {
            if (self.kernel) |kernel| {
                if (lookup(kernel.symbols, address)) |frame| {
                    var kernel_frame = frame;
                    kernel_frame.kernel = true;
                    return kernel_frame;
                }
            }
            return .{ .kernel = true };
        }
        const binary = self.binary orelse return .{};
        if (binary.symbols.len == 0) return .{};
        if (self.module) |module| {
            if (address < module.start or address >= module.end) return .{};
            // ET_EXEC images are mapped at their link addresses, so the runtime
            // address is already the ELF virtual address. Only ET_DYN (PIE)
            // needs the maps load bias.
            const vaddr = if (binary.executable)
                address
            else blk: {
                if (address < module.base) return .{};
                break :blk address - module.base;
            };
            if (lookup(binary.symbols, vaddr)) |frame| return frame;
            return .{};
        }
        if (!binary.executable) return .{};
        if (address < binary.min_vaddr or address >= binary.max_vaddr) return .{};
        return lookup(binary.symbols, address) orelse .{};
    }
};

fn writeElfFixture(buffer: *[1024]u8, e_type: u16) []const u8 {
    @memset(buffer, 0);
    @memcpy(buffer[0..4], "\x7fELF");
    buffer[4] = 2; // ELFCLASS64
    buffer[5] = 1; // little endian
    buffer[6] = 1; // version
    std.mem.writeInt(u16, buffer[16..18], e_type, .little);
    std.mem.writeInt(u16, buffer[18..20], 62, .little); // EM_X86_64
    std.mem.writeInt(u32, buffer[20..24], 1, .little);
    std.mem.writeInt(u64, buffer[24..32], 0x401000, .little);
    std.mem.writeInt(u64, buffer[40..48], 64, .little); // e_shoff
    std.mem.writeInt(u16, buffer[52..54], 64, .little); // e_ehsize
    std.mem.writeInt(u16, buffer[58..60], 64, .little); // e_shentsize
    std.mem.writeInt(u16, buffer[60..62], 3, .little); // e_shnum
    const sym_off: usize = 64 + 3 * 64;
    const str_off: usize = sym_off + 2 * 24;
    const strtab = "\x00demo_func\x00";
    const sym_sh: usize = 64 + 64;
    std.mem.writeInt(u32, buffer[sym_sh + 4 ..][0..4], 2, .little); // SHT_SYMTAB
    std.mem.writeInt(u64, buffer[sym_sh + 24 ..][0..8], sym_off, .little);
    std.mem.writeInt(u64, buffer[sym_sh + 32 ..][0..8], 2 * 24, .little);
    std.mem.writeInt(u32, buffer[sym_sh + 40 ..][0..4], 2, .little); // linked strtab
    std.mem.writeInt(u64, buffer[sym_sh + 56 ..][0..8], 24, .little);
    const str_sh: usize = 64 + 128;
    std.mem.writeInt(u32, buffer[str_sh + 4 ..][0..4], 3, .little); // SHT_STRTAB
    std.mem.writeInt(u64, buffer[str_sh + 24 ..][0..8], str_off, .little);
    std.mem.writeInt(u64, buffer[str_sh + 32 ..][0..8], strtab.len, .little);
    std.mem.writeInt(u64, buffer[str_sh + 48 ..][0..8], 1, .little);
    // symtab[1]: st_name=1, st_info=(GLOBAL<<4)|FUNC, st_shndx=1, value, size
    const sym1 = sym_off + 24;
    std.mem.writeInt(u32, buffer[sym1..][0..4], 1, .little);
    buffer[sym1 + 4] = 0x12;
    std.mem.writeInt(u16, buffer[sym1 + 6 ..][0..2], 1, .little);
    std.mem.writeInt(u64, buffer[sym1 + 8 ..][0..8], 0x401000, .little);
    std.mem.writeInt(u64, buffer[sym1 + 16 ..][0..8], 16, .little);
    @memcpy(buffer[str_off .. str_off + strtab.len], strtab);
    return buffer[0 .. str_off + strtab.len];
}

test "ELF symbol parsing resolves a synthetic binary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var buffer: [1024]u8 = undefined;
    const bytes = writeElfFixture(&buffer, 2); // ET_EXEC
    const binary = try parseBinaryBytes(allocator, bytes);
    try std.testing.expect(binary.executable);
    try std.testing.expectEqual(@as(usize, 1), binary.symbols.len);
    try std.testing.expectEqualStrings("demo_func", binary.symbols[0].name);
    try std.testing.expectEqual(@as(u64, 0x401000), binary.symbols[0].addr);
    try std.testing.expectEqual(@as(u64, 0x401000), binary.min_vaddr);
    try std.testing.expectEqual(@as(u64, 0x401010), binary.max_vaddr);

    var symbolizer = Symbolizer.create(allocator);
    defer symbolizer.deinit();
    try symbolizer.setBinaryBytes(bytes);
    const frame = symbolizer.resolve(0x401004);
    try std.testing.expect(frame.resolved);
    try std.testing.expectEqualStrings("demo_func", frame.name);
    try std.testing.expectEqual(@as(u64, 4), frame.offset);
    // Addresses outside the ET_EXEC image stay unresolved, not guessed.
    const outside = symbolizer.resolve(0x500000);
    try std.testing.expect(!outside.resolved);

    // With a maps sidecar, a non-PIE image is still resolved from its link
    // addresses: the mapping range constrains addresses, but the load bias is
    // not subtracted (`start - offset` is meaningless for ET_EXEC segments).
    symbolizer.setModule(.{
        .base = 0x8e5000,
        .start = 0x400000,
        .end = 0x500000,
        .path = "/bin/probe",
    });
    const mapped = symbolizer.resolve(0x401004);
    try std.testing.expect(mapped.resolved);
    try std.testing.expectEqual(@as(u64, 4), mapped.offset);
}

test "kallsyms parsing resolves kernel frames and rejects all-zero tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text =
        "ffffffff81000000 T do_syscall_64\n" ++
        "ffffffff81001000 t local_helper [test_module]\n" ++
        "0000000000000000 T hidden_symbol\n";
    const kernel = try parseKallsyms(allocator, text);
    try std.testing.expectEqual(@as(usize, 2), kernel.symbols.len);
    var symbolizer = Symbolizer.create(allocator);
    defer symbolizer.deinit();
    try symbolizer.setKallsymsText(text);
    const frame = symbolizer.resolve(0xffffffff81000040);
    try std.testing.expect(frame.resolved);
    try std.testing.expect(frame.kernel);
    try std.testing.expectEqualStrings("do_syscall_64", frame.name);
    try std.testing.expectEqual(@as(u64, 0x40), frame.offset);
    const module_frame = symbolizer.resolve(0xffffffff81001010);
    try std.testing.expectEqualStrings("local_helper", module_frame.name);
    const outside = symbolizer.resolve(0xffffffff82000000);
    try std.testing.expect(!outside.resolved);
    try std.testing.expect(outside.kernel);
    try std.testing.expectError(
        error.KallsymsEmpty,
        parseKallsyms(allocator, "0000000000000000 T hidden\n"),
    );
}

test "module bias maps runtime addresses back to ELF virtual addresses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var buffer: [1024]u8 = undefined;
    const bytes = writeElfFixture(&buffer, 3); // ET_DYN (PIE)
    var symbolizer = Symbolizer.create(allocator);
    defer symbolizer.deinit();
    try symbolizer.setBinaryBytes(bytes);
    // Runtime address = ELF virtual address + load bias for ET_DYN.
    symbolizer.setModule(.{
        .base = 0x1000,
        .start = 0x402000,
        .end = 0x403000,
        .path = "/bin/probe",
    });
    const resolved = symbolizer.resolve(0x402123);
    try std.testing.expect(resolved.resolved);
    try std.testing.expectEqualStrings("demo_func", resolved.name);
    try std.testing.expectEqual(@as(u64, 0x123), resolved.offset);
    const outside = symbolizer.resolve(0x501000);
    try std.testing.expect(!outside.resolved);
}

test "symbolizer resolves a function in the compiled test binary" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var maps_file = std.Io.Dir.openFileAbsolute(std.testing.io, "/proc/self/maps", .{}) catch
        return error.SkipZigTest;
    defer maps_file.close(std.testing.io);
    var maps_buffer: [64 * 1024]u8 = undefined;
    var maps_reader = maps_file.readerStreaming(std.testing.io, &maps_buffer);
    const maps_text = maps_reader.interface.allocRemaining(allocator, .limited(8 * 1024 * 1024)) catch
        return error.SkipZigTest;
    const mappings = try maps.parseProcMaps(allocator, maps_text);
    const address: u64 = @intFromPtr(&Symbolizer.resolve);
    var module: ?maps.Module = null;
    for (mappings) |mapping| {
        if (!mapping.isExecutable()) continue;
        if (address < mapping.start or address >= mapping.end) continue;
        module = .{
            .base = mapping.start -| mapping.offset,
            .start = mapping.start,
            .end = mapping.end,
            .path = mapping.path,
        };
        break;
    }
    const found_module = module orelse return error.SkipZigTest;
    var symbolizer = Symbolizer.create(allocator);
    defer symbolizer.deinit();
    symbolizer.binary = loadBinaryFile(std.testing.io, allocator, "/proc/self/exe") catch
        return error.SkipZigTest;
    if (symbolizer.binary.?.symbols.len == 0) return error.SkipZigTest;
    symbolizer.setModule(found_module);
    const frame = symbolizer.resolve(address);
    try std.testing.expect(frame.resolved);
    try std.testing.expect(std.mem.indexOf(u8, frame.name, "resolve") != null);
}
