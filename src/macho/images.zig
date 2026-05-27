const std = @import("std");
const builtin = @import("builtin");

const macho = std.macho;

pub const Error = error{
    UnsupportedPlatform,
    InvalidArgument,
    InvalidMachO,
    OutOfMemory,
    NotFound,
    Ambiguous,
};

pub const OffsetKind = enum {
    vmaddr,
    file,
    global_file,
};

pub const Pattern = struct {
    bytes: []const u8,
    mask: ?[]const u8 = null,
};

pub const PatternScope = struct {
    image: ?[]const u8 = null,
    segment: ?[]const u8 = null,
    section: ?[]const u8 = null,
    occurrence: usize = 0,
    result_offset: isize = 0,
};

pub const ImageInfo = struct {
    name: []const u8,
    header: *const macho.mach_header_64,
    slide: isize,
};

extern "c" fn _dyld_image_count() u32;
extern "c" fn _dyld_get_image_name(image_index: u32) ?[*:0]const u8;
extern "c" fn _dyld_get_image_header(image_index: u32) ?*const macho.mach_header_64;
extern "c" fn _dyld_get_image_vmaddr_slide(image_index: u32) isize;

const Image = struct {
    name: []const u8,
    header: *const macho.mach_header_64,
    slide: isize,
};

const Section = struct {
    segment: []const u8,
    section: []const u8,
    addr: u64,
    size: u64,
    offset: u64,
    flags: u32,

    fn isCode(self: Section) bool {
        const attrs = self.flags & 0xffffff00;
        return attrs & macho.S_ATTR_PURE_INSTRUCTIONS != 0 or attrs & macho.S_ATTR_SOME_INSTRUCTIONS != 0;
    }
};

const FatArch64 = extern struct {
    cputype: macho.cpu_type_t,
    cpusubtype: macho.cpu_subtype_t,
    offset: u64,
    size: u64,
    @"align": u32,
    reserved: u32,
};

pub fn resolveSymbol(optional_image: ?[]const u8, symbol: []const u8) Error!usize {
    if (!isDarwin()) return error.UnsupportedPlatform;
    if (symbol.len == 0) return error.InvalidArgument;
    var found: ?usize = null;
    const total = _dyld_image_count();
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        const image_name_z = _dyld_get_image_name(index) orelse continue;
        const image_name = std.mem.span(image_name_z);
        if (optional_image) |needle| {
            if (!imageMatches(image_name, needle)) continue;
        }
        const header = _dyld_get_image_header(index) orelse continue;
        const image: Image = .{
            .name = image_name,
            .header = header,
            .slide = _dyld_get_image_vmaddr_slide(index),
        };
        if (resolveSymbolInImage(image, symbol)) |address| {
            if (optional_image != null) return address;
            if (found != null) return error.Ambiguous;
            found = address;
        }
    }
    return found orelse error.NotFound;
}

pub fn resolveOffset(image_name: []const u8, offset: u64, kind: OffsetKind) Error!usize {
    if (!isDarwin()) return error.UnsupportedPlatform;
    if (image_name.len == 0) return error.InvalidArgument;
    const image = findImage(image_name) orelse return error.NotFound;
    return switch (kind) {
        .vmaddr => resolveVmaddr(image, offset),
        .file => resolveFileOffset(image, offset),
        .global_file => resolveGlobalFileOffset(image, offset),
    };
}

pub fn resolvePattern(scope: PatternScope, pattern: Pattern) Error!usize {
    if (!isDarwin()) return error.UnsupportedPlatform;
    if (pattern.bytes.len == 0) return error.InvalidArgument;
    if (pattern.mask) |mask| {
        if (mask.len != 0 and mask.len != pattern.bytes.len) return error.InvalidArgument;
    }
    const total = _dyld_image_count();
    var remaining = scope.occurrence;
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        const image_name_z = _dyld_get_image_name(index) orelse continue;
        const image_name = std.mem.span(image_name_z);
        if (scope.image) |needle| {
            if (!imageMatches(image_name, needle)) continue;
        }
        const header = _dyld_get_image_header(index) orelse continue;
        const image: Image = .{
            .name = image_name,
            .header = header,
            .slide = _dyld_get_image_vmaddr_slide(index),
        };
        if (resolvePatternInImage(image, scope, pattern, &remaining)) |address| return address;
    }
    return error.NotFound;
}

pub fn resolvePatternText(allocator: std.mem.Allocator, scope: PatternScope, text: []const u8) Error!usize {
    const parsed = try parsePatternText(allocator, text);
    defer allocator.free(parsed.bytes);
    defer allocator.free(parsed.mask);
    return resolvePattern(scope, .{ .bytes = parsed.bytes, .mask = parsed.mask });
}

pub fn imageContainingAddress(address: usize) Error!ImageInfo {
    if (!isDarwin()) return error.UnsupportedPlatform;
    if (address == 0) return error.InvalidArgument;
    const total = _dyld_image_count();
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        const image_name_z = _dyld_get_image_name(index) orelse continue;
        const header = _dyld_get_image_header(index) orelse continue;
        const slide = _dyld_get_image_vmaddr_slide(index);
        const image: Image = .{
            .name = std.mem.span(image_name_z),
            .header = header,
            .slide = slide,
        };
        if (containsAddress(image, address)) {
            return .{
                .name = image.name,
                .header = image.header,
                .slide = image.slide,
            };
        }
    }
    return error.NotFound;
}

pub fn imageUuid(header: *const macho.mach_header_64, out_uuid: []u8) Error!usize {
    if (out_uuid.len < 16) return error.InvalidArgument;
    var it = try loadCommands(header);
    while (try it.next()) |load_cmd| {
        if (load_cmd.hdr.cmd != .UUID) continue;
        const uuid_cmd = load_cmd.cast(macho.uuid_command) orelse return error.InvalidMachO;
        @memcpy(out_uuid[0..16], &uuid_cmd.uuid);
        return 16;
    }
    return error.NotFound;
}

fn resolveSymbolInImage(image: Image, symbol: []const u8) ?usize {
    _ = image.name;
    var symtab: ?macho.symtab_command = null;
    var linkedit: ?macho.segment_command_64 = null;
    var it = loadCommands(image.header) catch return null;
    while (it.next() catch return null) |load_cmd| {
        switch (load_cmd.hdr.cmd) {
            .SYMTAB => symtab = load_cmd.cast(macho.symtab_command) orelse return null,
            .SEGMENT_64 => {
                const seg = load_cmd.cast(macho.segment_command_64) orelse return null;
                if (std.mem.eql(u8, seg.segName(), "__LINKEDIT")) linkedit = seg;
            },
            else => {},
        }
    }
    const st = symtab orelse return null;
    const le = linkedit orelse return null;
    const linkedit_base = @as(isize, @intCast(le.vmaddr)) + image.slide - @as(isize, @intCast(le.fileoff));
    if (linkedit_base < 0) return null;
    const sym_ptr: [*]align(1) const macho.nlist_64 = @ptrFromInt(@as(usize, @intCast(linkedit_base + @as(isize, @intCast(st.symoff)))));
    const str_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(linkedit_base + @as(isize, @intCast(st.stroff)))));
    const allow_underscore = needsLeadingUnderscore(symbol);
    var index: usize = 0;
    while (index < st.nsyms) : (index += 1) {
        const entry = sym_ptr[index];
        if (entry.n_strx == 0 or entry.n_strx >= st.strsize) continue;
        if (entry.n_type.bits.is_stab != 0) continue;
        if (entry.n_type.bits.type != .sect and entry.n_type.bits.type != .abs) continue;
        const actual = std.mem.sliceTo(str_ptr[entry.n_strx..], 0);
        if (symbolMatches(actual, symbol, allow_underscore)) return @intCast(@as(isize, @intCast(entry.n_value)) + image.slide);
    }
    return null;
}

fn findImage(needle: []const u8) ?Image {
    const total = _dyld_image_count();
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        const image_name_z = _dyld_get_image_name(index) orelse continue;
        const image_name = std.mem.span(image_name_z);
        if (!imageMatches(image_name, needle)) continue;
        const header = _dyld_get_image_header(index) orelse continue;
        return .{
            .name = image_name,
            .header = header,
            .slide = _dyld_get_image_vmaddr_slide(index),
        };
    }
    return null;
}

fn containsAddress(image: Image, address: usize) bool {
    var it = loadCommands(image.header) catch return false;
    while (it.next() catch return false) |load_cmd| {
        if (load_cmd.hdr.cmd != .SEGMENT_64) continue;
        const seg = load_cmd.cast(macho.segment_command_64) orelse return false;
        if (seg.vmsize == 0) continue;
        const start = addSlide(seg.vmaddr, image.slide) catch continue;
        const end = addSlide(seg.vmaddr + seg.vmsize, image.slide) catch continue;
        if (address >= start and address < end) return true;
    }
    return false;
}

fn resolveVmaddr(image: Image, vmaddr: u64) Error!usize {
    var it = try loadCommands(image.header);
    while (try it.next()) |load_cmd| {
        if (load_cmd.hdr.cmd != .SEGMENT_64) continue;
        const seg = load_cmd.cast(macho.segment_command_64) orelse return error.InvalidMachO;
        if (vmaddr < seg.vmaddr or vmaddr >= seg.vmaddr + seg.vmsize) continue;
        return addSlide(vmaddr, image.slide);
    }
    return error.NotFound;
}

fn resolveFileOffset(image: Image, file_offset: u64) Error!usize {
    var it = try loadCommands(image.header);
    while (try it.next()) |load_cmd| {
        if (load_cmd.hdr.cmd != .SEGMENT_64) continue;
        for (sections(load_cmd) orelse return error.InvalidMachO) |sect| {
            const section = makeSection(sect);
            if (section.size == 0) continue;
            if (file_offset < section.offset or file_offset >= section.offset + section.size) continue;
            return addSlide(section.addr + (file_offset - section.offset), image.slide);
        }
    }
    return error.NotFound;
}

fn resolveGlobalFileOffset(image: Image, global_file_offset: u64) Error!usize {
    const slice_offset = try currentArchSliceOffset(image.name);
    if (global_file_offset < slice_offset) return error.NotFound;
    return resolveFileOffset(image, global_file_offset - slice_offset);
}

fn resolvePatternInImage(image: Image, scope: PatternScope, pattern: Pattern, remaining: *usize) ?usize {
    var it = loadCommands(image.header) catch return null;
    while (it.next() catch return null) |load_cmd| {
        if (load_cmd.hdr.cmd != .SEGMENT_64) continue;
        for (sections(load_cmd) orelse return null) |sect| {
            const section = makeSection(sect);
            if (!sectionMatches(section, scope)) continue;
            if (findPatternInSection(image, section, pattern, scope.result_offset, remaining)) |address| return address;
        }
    }
    return null;
}

fn findPatternInSection(image: Image, section: Section, pattern: Pattern, result_offset: isize, remaining: *usize) ?usize {
    if (section.size < pattern.bytes.len) return null;
    const start = addSlide(section.addr, image.slide) catch return null;
    const memory = @as([*]const u8, @ptrFromInt(start))[0..@intCast(section.size)];
    const last_start = memory.len - pattern.bytes.len;
    var index: usize = 0;
    while (index <= last_start) : (index += 1) {
        if (!patternMatches(memory[index..][0..pattern.bytes.len], pattern)) continue;
        if (remaining.* != 0) {
            remaining.* -= 1;
            continue;
        }
        const match_start: isize = @intCast(start + index);
        const address = match_start + result_offset;
        const section_start: isize = @intCast(start);
        const section_end: isize = @intCast(start + memory.len);
        if (address < section_start or address >= section_end) return null;
        return @intCast(address);
    }
    return null;
}

fn sectionMatches(section: Section, scope: PatternScope) bool {
    if (scope.segment) |segment| {
        if (!std.mem.eql(u8, section.segment, segment)) return false;
    }
    if (scope.section) |section_name| {
        if (!std.mem.eql(u8, section.section, section_name)) return false;
    }
    if (scope.segment == null and scope.section == null and !section.isCode()) return false;
    return true;
}

fn patternMatches(memory: []const u8, pattern: Pattern) bool {
    const mask = pattern.mask;
    for (pattern.bytes, 0..) |byte, index| {
        if (mask) |mask_bytes| {
            if (mask_bytes.len != 0 and mask_bytes[index] == 0) continue;
        }
        if (memory[index] != byte) return false;
    }
    return true;
}

const ParsedPattern = struct {
    bytes: []u8,
    mask: []u8,
};

fn parsePatternText(allocator: std.mem.Allocator, text: []const u8) Error!ParsedPattern {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var mask: std.ArrayList(u8) = .empty;
    errdefer mask.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |token| {
        if (isWildcardToken(token)) {
            try bytes.append(allocator, 0);
            try mask.append(allocator, 0);
            continue;
        }
        if (token.len != 2) return error.InvalidArgument;
        const byte = std.fmt.parseInt(u8, token, 16) catch return error.InvalidArgument;
        try bytes.append(allocator, byte);
        try mask.append(allocator, 0xff);
    }
    if (bytes.items.len == 0) return error.InvalidArgument;
    return .{
        .bytes = try bytes.toOwnedSlice(allocator),
        .mask = try mask.toOwnedSlice(allocator),
    };
}

fn isWildcardToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "?") or std.mem.eql(u8, token, "??") or std.mem.eql(u8, token, ".");
}

fn makeSection(sect: macho.section_64) Section {
    var local = sect;
    return .{
        .segment = local.segName(),
        .section = local.sectName(),
        .addr = local.addr,
        .size = local.size,
        .offset = local.offset,
        .flags = local.flags,
    };
}

fn sections(load_cmd: macho.LoadCommandIterator.LoadCommand) ?[]align(1) const macho.section_64 {
    return switch (load_cmd.hdr.cmd) {
        .SEGMENT_64 => load_cmd.getSections(),
        else => null,
    };
}

fn addSlide(vmaddr: u64, slide: isize) Error!usize {
    const address = @as(i128, @intCast(vmaddr)) + @as(i128, @intCast(slide));
    if (address <= 0 or address > std.math.maxInt(usize)) return error.NotFound;
    return @intCast(address);
}

fn currentArchSliceOffset(path: []const u8) Error!u64 {
    const io = std.Options.debug_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.NotFound;
    defer file.close(io);
    const stat = file.stat(io) catch return error.InvalidMachO;
    if (stat.size < @sizeOf(macho.fat_header)) return error.InvalidMachO;
    var file_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    var header_bytes: [@sizeOf(macho.fat_header)]u8 = undefined;
    reader.interface.readSliceAll(&header_bytes) catch return error.InvalidMachO;
    const magic = std.mem.readInt(u32, &header_bytes[0..4].*, .big);
    switch (magic) {
        macho.FAT_MAGIC, macho.FAT_MAGIC_64 => {},
        else => return 0,
    }
    const arch_count = std.mem.readInt(u32, &header_bytes[4..8].*, .big);
    const desired = currentCpuType() orelse return error.UnsupportedPlatform;
    var index: u32 = 0;
    while (index < arch_count) : (index += 1) {
        const cputype, const offset = try readFatArch(&reader, magic);
        if (cputype == desired) return offset;
    }
    return error.NotFound;
}

fn readFatArch(reader: anytype, magic: u32) Error!struct { macho.cpu_type_t, u64 } {
    if (magic == macho.FAT_MAGIC_64) {
        var arch_bytes: [@sizeOf(FatArch64)]u8 = undefined;
        reader.interface.readSliceAll(&arch_bytes) catch return error.InvalidMachO;
        const cputype_bits = std.mem.readInt(u32, &arch_bytes[0..4].*, .big);
        const cputype: macho.cpu_type_t = @bitCast(cputype_bits);
        const offset = std.mem.readInt(u64, &arch_bytes[8..16].*, .big);
        return .{ cputype, offset };
    }
    var arch_bytes: [@sizeOf(macho.fat_arch)]u8 = undefined;
    reader.interface.readSliceAll(&arch_bytes) catch return error.InvalidMachO;
    const cputype_bits = std.mem.readInt(u32, &arch_bytes[0..4].*, .big);
    const cputype: macho.cpu_type_t = @bitCast(cputype_bits);
    const offset = std.mem.readInt(u32, &arch_bytes[8..12].*, .big);
    return .{ cputype, offset };
}

fn currentCpuType() ?macho.cpu_type_t {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => macho.CPU_TYPE_ARM64,
        .x86_64 => macho.CPU_TYPE_X86_64,
        else => null,
    };
}

fn loadCommands(header: *const macho.mach_header_64) Error!macho.LoadCommandIterator {
    if (header.magic != macho.MH_MAGIC_64) return error.InvalidMachO;
    const raw: [*]const u8 = @ptrCast(header);
    return macho.LoadCommandIterator.init(header, raw[@sizeOf(macho.mach_header_64)..][0..header.sizeofcmds]);
}

fn imageMatches(image_name: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.mem.eql(u8, image_name, needle) or
        std.mem.eql(u8, std.fs.path.basename(image_name), needle) or
        std.mem.endsWith(u8, image_name, needle);
}

fn needsLeadingUnderscore(symbol: []const u8) bool {
    return symbol.len > 0 and symbol[0] != '_' and symbol[0] != '$';
}

fn symbolMatches(actual: []const u8, requested: []const u8, allow_underscore: bool) bool {
    if (std.mem.eql(u8, actual, requested)) return true;
    return allow_underscore and actual.len == requested.len + 1 and actual[0] == '_' and std.mem.eql(u8, actual[1..], requested);
}

fn isDarwin() bool {
    return comptime builtin.os.tag.isDarwin();
}

test "empty symbol is invalid" {
    try std.testing.expectError(error.InvalidArgument, resolveSymbol(null, ""));
}

test "pattern text parser accepts hex and wildcards" {
    const allocator = std.testing.allocator;
    const parsed = try parsePatternText(allocator, "48 89 ? . ff");
    defer allocator.free(parsed.bytes);
    defer allocator.free(parsed.mask);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x48, 0x89, 0x00, 0x00, 0xff }, parsed.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xff, 0x00, 0x00, 0xff }, parsed.mask);
}

test "pattern matcher honors zero-mask wildcard bytes" {
    const memory = [_]u8{ 0xaa, 0x11, 0xcc };
    const bytes = [_]u8{ 0xaa, 0xbb, 0xcc };
    const mask = [_]u8{ 0xff, 0x00, 0xff };
    try std.testing.expect(patternMatches(&memory, .{ .bytes = &bytes, .mask = &mask }));
    try std.testing.expect(!patternMatches(&memory, .{ .bytes = &bytes, .mask = null }));
}
