const std = @import("std");
const builtin = @import("builtin");

const c = @import("../api.zig");
const images = @import("../macho/images.zig");

pub const Error = error{
    UnsupportedPlatform,
    UnsupportedOperation,
    InvalidArgument,
    NotFound,
    OutOfMemory,
    BufferTooSmall,
    InternalError,
};

pub fn lookupFileLine(request: *c.zi_debug_file_line_t) Error!void {
    if (request.address == null) return error.InvalidArgument;
    if (request.file_buffer_len != 0 and request.file_buffer == null) return error.InvalidArgument;
    if (request.function_buffer_len != 0 and request.function_buffer == null) return error.InvalidArgument;
    if (request.image_uuid_len != 0 and request.image_uuid_out == null) return error.InvalidArgument;
    if (!isDarwin()) return error.UnsupportedPlatform;
    initializeOutputs(request);

    const address = @intFromPtr(request.address.?);
    const io = std.Options.debug_io;
    const self_info = std.debug.getSelfDebugInfo() catch return error.NotFound;

    var symbol_fallback = std.heap.stackFallback(@sizeOf(std.debug.Symbol) * 2, std.debug.getDebugInfoAllocator());
    const symbol_allocator = symbol_fallback.get();
    var text_arena = std.heap.ArenaAllocator.init(std.debug.getDebugInfoAllocator());
    defer text_arena.deinit();

    var symbols = std.ArrayList(std.debug.Symbol).initCapacity(symbol_allocator, 1) catch return error.OutOfMemory;
    defer symbols.deinit(symbol_allocator);

    self_info.getSymbols(io, symbol_allocator, text_arena.allocator(), address, false, &symbols) catch |err| {
        return mapDebugError(err);
    };
    if (symbols.items.len == 0) return error.NotFound;

    const symbol = symbols.items[0];
    if (symbol.source_location) |source| {
        try writeBuffer(request.file_buffer, request.file_buffer_len, request.required_file_len_out, source.file_name);
        if (request.line_out) |out| out.* = @intCast(source.line);
        if (request.column_out) |out| out.* = @intCast(source.column);
    }
    if (symbol.name) |name| {
        try writeBuffer(request.function_buffer, request.function_buffer_len, request.required_function_len_out, name);
    }

    if (request.image_uuid_out) |uuid_out| {
        const image = images.imageContainingAddress(address) catch return error.NotFound;
        _ = images.imageUuid(image.header, uuid_out[0..request.image_uuid_len]) catch |err| switch (err) {
            error.NotFound => {},
            error.InvalidArgument, error.InvalidMachO => return error.InternalError,
            else => return error.InternalError,
        };
    }

    if (symbol.source_location == null and symbol.name == null) return error.NotFound;
}

fn isDarwin() bool {
    return comptime builtin.os.tag.isDarwin();
}

fn initializeOutputs(request: *c.zi_debug_file_line_t) void {
    if (request.required_file_len_out) |out| out.* = 0;
    if (request.required_function_len_out) |out| out.* = 0;
    if (request.line_out) |out| out.* = 0;
    if (request.column_out) |out| out.* = 0;
    if (request.image_uuid_out) |out| @memset(out[0..@min(request.image_uuid_len, c.ZI_IMAGE_UUID_BYTES)], 0);
}

fn writeBuffer(buffer: ?[*]u8, buffer_len: usize, required_len_out: ?*usize, text: []const u8) Error!void {
    if (required_len_out) |out| out.* = text.len + 1;
    if (buffer_len == 0 or buffer == null) {
        if (text.len != 0) return error.BufferTooSmall;
        return;
    }
    if (buffer_len < text.len + 1) return error.BufferTooSmall;
    const writable = buffer.?[0..buffer_len];
    @memcpy(writable[0..text.len], text);
    writable[text.len] = 0;
}

fn mapDebugError(err: std.debug.SelfInfoError) Error {
    return switch (err) {
        error.MissingDebugInfo => error.NotFound,
        error.UnsupportedDebugInfo => error.NotFound,
        error.InvalidDebugInfo => error.InternalError,
        error.ReadFailed => error.InternalError,
        error.OutOfMemory => error.OutOfMemory,
        error.Unexpected => error.InternalError,
        error.Canceled => error.InternalError,
    };
}
