const std = @import("std");
const builtin = @import("builtin");
const threads = @import("threads.zig");

pub const Error = error{
    UnsupportedPlatform,
    UnsupportedOperation,
    InvalidArgument,
    OutOfMemory,
    AccessDenied,
    GuardFailed,
    Conflict,
};

pub const WriteOptions = struct {
    expected: ?[]const u8 = null,
    racy: bool = false,
};

extern "c" fn __clear_cache(start: ?*anyopaque, end: ?*anyopaque) void;
extern "c" fn pthread_jit_write_protect_supported_np() c_int;
extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;

pub const ExecutableMemory = struct {
    bytes: []align(std.heap.page_size_min) u8,
    jit: bool = false,

    pub fn executableSlice(self: ExecutableMemory) []align(std.heap.page_size_min) u8 {
        return self.bytes;
    }

    pub fn write(self: ExecutableMemory, offset: usize, source: []const u8) Error!void {
        if (offset > self.bytes.len or source.len > self.bytes.len - offset) return error.InvalidArgument;
        if (source.len == 0) return;
        if (self.jit) {
            pthread_jit_write_protect_np(0);
            @memcpy(self.bytes[offset..][0..source.len], source);
            pthread_jit_write_protect_np(1);
        } else {
            try protect(@intFromPtr(self.bytes.ptr) + offset, source.len, .{ .READ = true, .WRITE = true });
            @memcpy(self.bytes[offset..][0..source.len], source);
            try protect(@intFromPtr(self.bytes.ptr) + offset, source.len, .{ .READ = true, .EXEC = true });
        }
        flushInstructionCache(@intFromPtr(self.bytes.ptr) + offset, source.len);
    }
};

pub fn write(address: usize, replacement: []const u8, options: WriteOptions) Error!void {
    if (address == 0 or replacement.len == 0) return error.InvalidArgument;
    const transaction = threads.beginPatchTransaction(.{ .target = address, .len = replacement.len }, options.racy) catch |err| return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.UnsupportedOperation => error.UnsupportedOperation,
        error.AccessDenied => error.AccessDenied,
        error.Conflict => error.Conflict,
    };
    defer threads.endPatchTransaction(transaction);
    const dst = @as([*]u8, @ptrFromInt(address))[0..replacement.len];
    if (options.expected) |expected| {
        if (expected.len != replacement.len) return error.InvalidArgument;
        if (!std.mem.eql(u8, dst, expected)) return error.Conflict;
    }
    const original_protection = try queryProtection(address);
    try protectForWrite(address, replacement.len, original_protection);
    @memcpy(dst, replacement);
    flushInstructionCache(address, replacement.len);
    try protect(address, replacement.len, original_protection);
}

pub fn writePointer(slot: *?*anyopaque, replacement: ?*anyopaque, expected: ?*anyopaque) Error!void {
    if (slot.* != expected) return error.Conflict;
    const bytes = std.mem.asBytes(&replacement);
    const original_protection = try queryProtection(@intFromPtr(slot));
    try protectForWrite(@intFromPtr(slot), bytes.len, original_protection);
    slot.* = replacement;
    flushInstructionCache(@intFromPtr(slot), bytes.len);
    try protect(@intFromPtr(slot), bytes.len, original_protection);
}

pub fn allocateExecutable(length: usize) Error!ExecutableMemory {
    if (!isDarwin()) return error.UnsupportedPlatform;
    if (length == 0) return error.InvalidArgument;
    const aligned_len = std.mem.alignForward(usize, length, std.heap.pageSize());
    const use_jit = comptime builtin.cpu.arch.isAARCH64();
    if (use_jit and pthread_jit_write_protect_supported_np() == 0) return error.UnsupportedOperation;
    const memory = std.posix.mmap(
        null,
        aligned_len,
        if (use_jit) .{ .READ = true, .WRITE = true, .EXEC = true } else .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = use_jit },
        -1,
        0,
    ) catch |err| return mapMmapError(err);
    if (use_jit) {
        pthread_jit_write_protect_np(1);
        return .{ .bytes = memory, .jit = true };
    }
    protect(@intFromPtr(memory.ptr), memory.len, .{ .READ = true, .EXEC = true }) catch |err| {
        std.posix.munmap(memory);
        return err;
    };
    return .{ .bytes = memory, .jit = false };
}

pub fn releaseExecutable(memory: ExecutableMemory) void {
    if (memory.bytes.len != 0) std.posix.munmap(memory.bytes);
}

pub fn flushInstructionCache(address: usize, len: usize) void {
    if (len == 0) return;
    __clear_cache(@ptrFromInt(address), @ptrFromInt(address + len));
}

pub fn isDarwin() bool {
    return comptime builtin.os.tag.isDarwin();
}

fn protectForWrite(address: usize, len: usize, original: std.c.vm_prot_t) Error!void {
    var writable = original;
    writable.WRITE = true;
    writable.EXEC = false;
    writable.COPY = true;
    try protect(address, len, writable);
}

fn protect(address: usize, len: usize, protection: std.c.vm_prot_t) Error!void {
    if (!isDarwin()) return error.UnsupportedPlatform;
    const range = pageRange(address, len);
    const kr = std.c.mach_vm_protect(std.c.mach_task_self(), range.start, range.len, 0, protection);
    if (kr != 0) return error.AccessDenied;
}

fn queryProtection(address: usize) Error!std.c.vm_prot_t {
    if (!isDarwin()) return error.UnsupportedPlatform;
    if (address == 0) return error.InvalidArgument;
    var region_address: std.c.mach_vm_address_t = address;
    var region_size: std.c.mach_vm_size_t = 0;
    var info: std.c.vm_region_basic_info_64 = undefined;
    var info_count: std.c.mach_msg_type_number_t = std.c.VM.REGION.BASIC_INFO_COUNT;
    var object_name: std.c.mach_port_t = 0;
    const kr = std.c.mach_vm_region(
        std.c.mach_task_self(),
        &region_address,
        &region_size,
        std.c.VM.REGION.BASIC_INFO_64,
        @ptrCast(&info),
        &info_count,
        &object_name,
    );
    if (kr != 0) return error.AccessDenied;
    return info.protection;
}

fn mapMmapError(err: std.posix.MMapError) Error {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.AccessDenied,
    };
}

fn pageRange(address: usize, len: usize) struct { start: usize, len: usize } {
    const page_size = std.heap.pageSize();
    const alignment = std.mem.Alignment.fromByteUnits(page_size);
    const start = alignment.backward(address);
    const end = alignment.forward(address + len);
    return .{ .start = start, .len = end - start };
}

test "executable allocation rejects zero length" {
    if (!isDarwin()) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidArgument, allocateExecutable(0));
}
