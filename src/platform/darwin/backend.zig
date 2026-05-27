const std = @import("std");
const builtin = @import("builtin");

const abi = @import("../../abi/types.zig");
const debug = @import("../../debug/dwarf.zig");
const images = @import("../../macho/images.zig");
const memory = @import("memory.zig");
const interface = @import("../interface.zig");

pub const Error = interface.Error;
pub const ExecutableMemory = memory.ExecutableMemory;

pub fn currentArch() abi.zi_arch_t {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => .ZI_ARCH_ARM64,
        .x86_64 => .ZI_ARCH_X86_64,
        else => .ZI_ARCH_UNKNOWN,
    };
}

pub fn resolveSymbol(image_name: ?[]const u8, symbol_name: []const u8) Error!usize {
    return images.resolveSymbol(image_name, symbol_name) catch |err| return mapImageError(err);
}

pub fn resolveImageOffset(image_name: []const u8, offset: u64, kind: abi.zi_macho_offset_kind_t) Error!usize {
    const offset_kind: images.OffsetKind = switch (kind) {
        .ZI_MACHO_OFFSET_VMADDR => .vmaddr,
        .ZI_MACHO_OFFSET_FILE => .file,
        .ZI_MACHO_OFFSET_GLOBAL_FILE => .global_file,
    };
    return images.resolveOffset(image_name, offset, offset_kind) catch |err| return mapImageError(err);
}

pub fn resolvePatternBytes(image_name: ?[]const u8, segment_name: ?[]const u8, section_name: ?[]const u8, pattern: abi.zi_pattern_t, occurrence: usize, result_offset: isize) Error!usize {
    const bytes = if (pattern.bytes.len == 0) return error.InvalidArgument else (pattern.bytes.ptr orelse return error.InvalidArgument)[0..pattern.bytes.len];
    const mask = if (pattern.mask.len == 0) null else (pattern.mask.ptr orelse return error.InvalidArgument)[0..pattern.mask.len];
    return images.resolvePattern(.{
        .image = image_name,
        .segment = segment_name,
        .section = section_name,
        .occurrence = occurrence,
        .result_offset = result_offset,
    }, .{
        .bytes = bytes,
        .mask = mask,
    }) catch |err| return mapImageError(err);
}

pub fn resolvePatternText(allocator: std.mem.Allocator, image_name: ?[]const u8, segment_name: ?[]const u8, section_name: ?[]const u8, text: []const u8, occurrence: usize, result_offset: isize) Error!usize {
    return images.resolvePatternText(allocator, .{
        .image = image_name,
        .segment = segment_name,
        .section = section_name,
        .occurrence = occurrence,
        .result_offset = result_offset,
    }, text) catch |err| return mapImageError(err);
}

pub fn writeCode(address: usize, replacement: []const u8, expected: ?[]const u8, racy: bool) Error!void {
    memory.write(address, replacement, .{ .expected = expected, .racy = racy }) catch |err| return mapMemoryError(err);
}

pub fn writePointer(slot: *?*anyopaque, replacement: ?*anyopaque, expected: ?*anyopaque) Error!void {
    memory.writePointer(slot, replacement, expected) catch |err| return mapMemoryError(err);
}

pub fn debugLookup(request: *abi.zi_debug_file_line_t) Error!void {
    debug.lookupFileLine(request) catch |err| return mapDebugError(err);
}

fn mapImageError(err: images.Error) Error {
    return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.InvalidArgument => error.InvalidArgument,
        error.InvalidMachO => error.InternalError,
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.NotFound,
        error.Ambiguous => error.SymbolAmbiguous,
    };
}

fn mapMemoryError(err: memory.Error) Error {
    return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.UnsupportedOperation => error.UnsupportedOperation,
        error.InvalidArgument => error.InvalidArgument,
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.AccessDenied,
        error.GuardFailed => error.GuardFailed,
        error.Conflict => error.Conflict,
    };
}

fn mapDebugError(err: debug.Error) Error {
    return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.UnsupportedOperation => error.UnsupportedOperation,
        error.InvalidArgument => error.InvalidArgument,
        error.NotFound => error.NotFound,
        error.OutOfMemory => error.OutOfMemory,
        error.BufferTooSmall => error.BufferTooSmall,
        error.InternalError => error.InternalError,
    };
}
