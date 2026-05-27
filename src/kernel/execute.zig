const std = @import("std");

const abi = @import("../abi/types.zig");
const plan = @import("plan.zig");
const platform = @import("../platform/mod.zig");
const trampoline = @import("../backend/trampoline/mod.zig");
const swift = @import("../runtime/swift.zig");
const objc = @import("../runtime/objc.zig");
const interface = @import("../platform/interface.zig");

pub const Error = interface.Error;

pub const ActivePatchBytes = struct {
    address: usize,
    original: []u8,
    replacement: []u8,
    racy: bool,
};

pub const ActiveReplaceSite = struct {
    installation: trampoline.Installation,
};

pub const ActiveReplaceSlot = struct {
    patch: swift.SlotPatch,
};

pub const ActiveObjcObjectReplace = struct {
    replacement: objc.Replacement,
};

pub const ActiveOperation = union(plan.Kind) {
    patch_bytes: ActivePatchBytes,
    replace_site: ActiveReplaceSite,
    replace_slot: ActiveReplaceSlot,
    objc_object_replace: ActiveObjcObjectReplace,
};

pub fn instantiate(allocator: std.mem.Allocator, compiled: plan.OperationPlan) Error!ActiveOperation {
    return switch (compiled) {
        .patch_bytes => |patch| instantiatePatchBytes(allocator, patch),
        .replace_site => |replace| instantiateReplaceSite(replace),
        .replace_slot => |replace| instantiateReplaceSlot(replace),
        .objc_object_replace => |replace| instantiateObjcObjectReplace(replace),
    };
}

pub fn enable(active: *ActiveOperation) Error!void {
    switch (active.*) {
        .patch_bytes => |patch| try platform.darwin.writeCode(patch.address, patch.replacement, patch.original, patch.racy),
        .replace_site => |replace| trampoline.enable(replace.installation) catch |err| return mapTrampoline(err),
        .replace_slot => |slot| swift.applySlot(slot.patch) catch |err| return mapSwift(err),
        .objc_object_replace => |replacement| objc.applyObjectReplace(replacement.replacement) catch |err| return mapObjc(err),
    }
}

pub fn disable(active: *ActiveOperation) Error!void {
    switch (active.*) {
        .patch_bytes => |patch| try platform.darwin.writeCode(patch.address, patch.original, patch.replacement, patch.racy),
        .replace_site => |replace| trampoline.disable(replace.installation) catch |err| return mapTrampoline(err),
        .replace_slot => |slot| swift.restoreSlot(slot.patch) catch |err| return mapSwift(err),
        .objc_object_replace => |replacement| objc.restoreObjectReplace(replacement.replacement) catch |err| return mapObjc(err),
    }
}

pub fn remove(active: *ActiveOperation, allocator: std.mem.Allocator) Error!void {
    switch (active.*) {
        .patch_bytes => |patch| {
            try platform.darwin.writeCode(patch.address, patch.original, patch.replacement, patch.racy);
            allocator.free(patch.original);
            allocator.free(patch.replacement);
        },
        .replace_site => |replace| {
            trampoline.remove(replace.installation) catch |err| return mapTrampoline(err);
            trampoline.free(replace.installation);
        },
        .replace_slot => |slot| swift.restoreSlot(slot.patch) catch |err| return mapSwift(err),
        .objc_object_replace => |replacement| {
            objc.restoreObjectReplace(replacement.replacement) catch |err| return mapObjc(err);
            objc.free(allocator, replacement.replacement);
        },
    }
}

fn instantiatePatchBytes(allocator: std.mem.Allocator, patch: plan.PatchBytesPlan) Error!ActiveOperation {
    const replacement_copy = allocator.dupe(u8, patch.replacement) catch return error.OutOfMemory;
    errdefer allocator.free(replacement_copy);
    const original = allocator.alloc(u8, replacement_copy.len) catch return error.OutOfMemory;
    errdefer allocator.free(original);
    const address = @intFromPtr(patch.site.address.?);
    const current = @as([*]const u8, @ptrFromInt(address))[0..replacement_copy.len];
    @memcpy(original, current);
    if (patch.expected) |expected| {
        if (!std.mem.eql(u8, current, expected)) return error.GuardFailed;
    }
    try platform.darwin.writeCode(address, replacement_copy, original, patch.racy);
    return .{ .patch_bytes = .{
        .address = address,
        .original = original,
        .replacement = replacement_copy,
        .racy = patch.racy,
    } };
}

fn instantiateReplaceSite(replace: plan.ReplaceSitePlan) Error!ActiveOperation {
    const installation = trampoline.replace(replace.site.address, replace.replacement, .{ .racy = replace.racy }) catch |err| return mapTrampoline(err);
    if (replace.original_out) |out| out.* = installation.original;
    return .{ .replace_site = .{ .installation = installation } };
}

fn instantiateReplaceSlot(replace: plan.ReplaceSlotPlan) Error!ActiveOperation {
    const patch = swift.replaceSlot(replace.slot.address.?, replace.replacement) catch |err| return mapSwift(err);
    if (replace.original_out) |out| out.* = patch.original;
    return .{ .replace_slot = .{ .patch = patch } };
}

fn instantiateObjcObjectReplace(replace: plan.ObjcObjectReplacePlan) Error!ActiveOperation {
    const spec: abi.zi_objc_object_replace_spec_t = .{
        .size = @sizeOf(abi.zi_objc_object_replace_spec_t),
        .object = replace.object,
        .selector_name = replace.selector_name,
        .replacement = replace.replacement,
        .original_out = replace.original_out,
        .flags = replace.flags,
        .options = replace.options,
    };
    const installed = objc.installObjectReplace(&spec) catch |err| return mapObjc(err);
    return .{ .objc_object_replace = .{ .replacement = installed } };
}

fn mapTrampoline(err: trampoline.Error) Error {
    return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.UnsupportedOperation => error.UnsupportedOperation,
        error.UnsupportedInstruction => error.UnsupportedInstruction,
        error.InvalidArgument => error.InvalidArgument,
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.AccessDenied,
        error.GuardFailed => error.GuardFailed,
        error.Conflict => error.Conflict,
    };
}

fn mapSwift(err: swift.Error) Error {
    return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.UnsupportedOperation => error.UnsupportedOperation,
        error.InvalidArgument => error.InvalidArgument,
        error.NotFound => error.NotFound,
        error.AccessDenied => error.AccessDenied,
        error.GuardFailed => error.GuardFailed,
        error.Conflict => error.Conflict,
        error.Ambiguous => error.SymbolAmbiguous,
    };
}

fn mapObjc(err: objc.Error) Error {
    return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.UnsupportedOperation => error.UnsupportedOperation,
        error.InvalidArgument => error.InvalidArgument,
        error.NotFound => error.NotFound,
        error.Conflict => error.Conflict,
    };
}
