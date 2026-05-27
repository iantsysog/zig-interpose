const std = @import("std");
const builtin = @import("builtin");

const c = @import("../../api.zig");
const memory = @import("../../platform/darwin/memory.zig");
const arm64 = @import("arm64.zig");
const x86_64 = @import("x86_64.zig");

pub const Error = error{
    UnsupportedPlatform,
    UnsupportedOperation,
    UnsupportedInstruction,
    InvalidArgument,
    OutOfMemory,
    AccessDenied,
    GuardFailed,
    Conflict,
};

pub const Options = struct {
    racy: bool = false,
};

pub const ProbeCallbacks = struct {
    entry_callback: c.zi_entry_callback_fn = null,
    return_callback: c.zi_return_callback_fn = null,
    user_data: ?*anyopaque = null,
    return_kind: c.zi_return_kind_t = .ZI_RETURN_KIND_UNKNOWN,
    return_size: usize = 0,
};

pub const InstallationKind = enum {
    replacement,
    probe,
};

pub const ProbeMetadata = struct {
    callbacks: ProbeCallbacks,
};

pub const Installation = struct {
    kind: InstallationKind = .replacement,
    target: usize,
    original: ?*anyopaque,
    original_bytes: []u8,
    patch_bytes: []u8,
    trampoline: memory.ExecutableMemory,
    racy: bool,
    probe: ?*ProbeMetadata = null,
};

pub fn replace(target: ?*anyopaque, replacement: ?*anyopaque, options: Options) Error!Installation {
    if (target == null or replacement == null) return error.InvalidArgument;
    return installJump(@intFromPtr(target.?), @intFromPtr(replacement.?), options);
}

pub fn instrument(target: ?*anyopaque, callbacks: ProbeCallbacks, options: Options) Error!Installation {
    _ = callbacks;
    _ = options;
    if (!comptime builtin.os.tag.isDarwin()) return error.UnsupportedPlatform;
    if (target == null) return error.InvalidArgument;
    return error.UnsupportedOperation;
}

pub fn enable(installation: Installation) Error!void {
    try memory.write(installation.target, installation.patch_bytes, .{ .expected = installation.original_bytes, .racy = installation.racy });
}

pub fn disable(installation: Installation) Error!void {
    try memory.write(installation.target, installation.original_bytes, .{ .expected = installation.patch_bytes, .racy = installation.racy });
}

pub fn remove(installation: Installation) Error!void {
    try disable(installation);
}

pub fn free(installation: Installation) void {
    std.heap.smp_allocator.free(installation.original_bytes);
    std.heap.smp_allocator.free(installation.patch_bytes);
    memory.releaseExecutable(installation.trampoline);
    if (installation.probe) |probe| std.heap.smp_allocator.destroy(probe);
}

fn installJump(target: usize, destination: usize, options: Options) Error!Installation {
    if (!comptime builtin.os.tag.isDarwin()) return error.UnsupportedPlatform;
    const plan = try makePlan(target, destination);
    const original = try std.heap.smp_allocator.alloc(u8, plan.patch_len);
    errdefer std.heap.smp_allocator.free(original);
    const current = @as([*]const u8, @ptrFromInt(target))[0..plan.patch_len];
    @memcpy(original, current);
    var trampoline_memory = try allocateTrampoline(plan.emitted_len);
    errdefer memory.releaseExecutable(trampoline_memory);
    try copyTrampoline(&trampoline_memory, original[0..plan.relocated_len], target, plan.relocated_len);
    const patch = try std.heap.smp_allocator.alloc(u8, plan.patch_len);
    errdefer std.heap.smp_allocator.free(patch);
    writeNops(patch);
    _ = try writePatchJump(patch, target, destination, plan);
    try memory.write(target, patch, .{ .expected = original, .racy = options.racy });
    return .{
        .kind = .replacement,
        .target = target,
        .original = trampoline_memory.executableSlice().ptr,
        .original_bytes = original,
        .patch_bytes = patch,
        .trampoline = trampoline_memory,
        .racy = options.racy,
    };
}

const Plan = struct {
    patch_len: usize,
    relocated_len: usize,
    emitted_len: usize,
    prefers_near: bool = false,
};

fn makePlan(target: usize, destination: usize) Error!Plan {
    const code = @as([*]const u8, @ptrFromInt(target))[0..64];
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => .{
            .patch_len = arm64.patch_len,
            .relocated_len = try mapArm64(arm64.relocationLength(code, arm64.patch_len)),
            .emitted_len = try mapArm64(arm64.relocatedLength(code[0..try mapArm64(arm64.relocationLength(code, arm64.patch_len))])),
        },
        .x86_64 => blk: {
            const near = x86_64.canEncodeRelativeJump(target, destination);
            const required = if (near) x86_64.near_jump_len else x86_64.absolute_jump_len;
            const relocated_len = try mapX86(x86_64.relocationLength(code, required));
            break :blk .{
                .patch_len = relocated_len,
                .relocated_len = relocated_len,
                .emitted_len = try mapX86(x86_64.relocatedLength(code[0..relocated_len])),
                .prefers_near = near,
            };
        },
        else => error.UnsupportedPlatform,
    };
}

fn allocateTrampoline(emitted_len: usize) Error!memory.ExecutableMemory {
    const len = std.mem.alignForward(usize, emitted_len + maxJumpLen(), std.heap.pageSize());
    return memory.allocateExecutable(len) catch |err| return mapMemoryError(err);
}

fn copyTrampoline(out: *memory.ExecutableMemory, relocated: []const u8, source_address: usize, relocated_len: usize) Error!void {
    const scratch = std.heap.smp_allocator.alloc(u8, out.bytes.len) catch return error.OutOfMemory;
    defer std.heap.smp_allocator.free(scratch);
    const emitted_len = try relocateCode(scratch, relocated, source_address);
    if (scratch.len < emitted_len + maxJumpLen()) return error.UnsupportedInstruction;
    const jump_len = try writeAbsoluteJump(scratch[emitted_len..], source_address + relocated_len);
    try out.write(0, scratch[0 .. emitted_len + jump_len]);
}

fn writePatchJump(out: []u8, source: usize, destination: usize, plan: Plan) Error!usize {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => mapArm64(arm64.writeAbsoluteJump(out, destination)),
        .x86_64 => if (plan.prefers_near)
            mapX86(x86_64.writeRelativeJump(out, source, destination))
        else
            mapX86(x86_64.writeAbsoluteJump(out, destination)),
        else => error.UnsupportedPlatform,
    };
}

fn writeAbsoluteJump(out: []u8, destination: usize) Error!usize {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => mapArm64(arm64.writeAbsoluteJump(out, destination)),
        .x86_64 => mapX86(x86_64.writeAbsoluteJump(out, destination)),
        else => error.UnsupportedPlatform,
    };
}

fn writeNops(out: []u8) void {
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => {
            var index: usize = 0;
            while (index + 4 <= out.len) : (index += 4) {
                std.mem.writeInt(u32, out[index..][0..4], 0xd503201f, .little);
            }
        },
        .x86_64 => @memset(out, 0x90),
        else => @memset(out, 0),
    }
}

fn maxJumpLen() usize {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => arm64.jump_len,
        .x86_64 => x86_64.absolute_jump_len,
        else => 0,
    };
}

fn relocateCode(out: []u8, relocated: []const u8, source_address: usize) Error!usize {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => mapArm64(arm64.relocate(out, relocated, source_address)),
        .x86_64 => mapX86(x86_64.relocate(out, relocated, source_address, @intFromPtr(out.ptr))),
        else => error.UnsupportedPlatform,
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

fn mapArm64(value: arm64.Error!usize) Error!usize {
    return value catch error.UnsupportedInstruction;
}

fn mapX86(value: x86_64.Error!usize) Error!usize {
    return value catch error.UnsupportedInstruction;
}

test "invalid replacement arguments are rejected" {
    try std.testing.expectError(error.InvalidArgument, replace(null, @ptrFromInt(1), .{ .racy = true }));
    try std.testing.expectError(error.InvalidArgument, replace(@ptrFromInt(1), null, .{ .racy = true }));
}
