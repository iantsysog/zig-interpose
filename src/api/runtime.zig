const std = @import("std");

const abi = @import("../abi/types.zig");
const kernel = @import("../kernel/mod.zig");
const platform = @import("../platform/mod.zig");
const swift = @import("../runtime/swift.zig");
const objc = @import("../runtime/objc.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    hooks: std.ArrayList(*Hook) = .empty,
    closed: bool = false,
};

pub const Hook = struct {
    owner: *Runtime,
    target_key: usize,
    lifecycle: kernel.state.Lifecycle = .enabled,
    active: kernel.execute.ActiveOperation,
};

pub fn openRuntime(out_runtime: *abi.zi_runtime_t) abi.zi_status_t {
    const allocator = std.heap.smp_allocator;
    const runtime = allocator.create(Runtime) catch return .ZI_OUT_OF_MEMORY;
    runtime.* = .{ .allocator = allocator };
    out_runtime.* = @ptrCast(runtime);
    return .ZI_OK;
}

pub fn closeRuntime(rt: abi.zi_runtime_t) abi.zi_status_t {
    const runtime = castRuntime(rt) orelse return .ZI_INVALID_ARGUMENT;
    if (runtime.closed) return .ZI_OK;
    for (runtime.hooks.items) |hook| {
        if (hook.lifecycle != .removed) {
            kernel.execute.remove(&hook.active, runtime.allocator) catch |err| return mapError(err);
            hook.lifecycle = .removed;
        }
        runtime.allocator.destroy(hook);
    }
    runtime.hooks.deinit(runtime.allocator);
    runtime.closed = true;
    runtime.allocator.destroy(runtime);
    return .ZI_OK;
}

pub fn resetRuntime(rt: abi.zi_runtime_t) abi.zi_status_t {
    const runtime = castRuntime(rt) orelse return .ZI_INVALID_ARGUMENT;
    if (runtime.closed) return .ZI_INVALID_ARGUMENT;
    for (runtime.hooks.items) |hook| {
        if (hook.lifecycle == .removed) continue;
        kernel.execute.remove(&hook.active, runtime.allocator) catch |err| return mapError(err);
        hook.lifecycle = .removed;
    }
    return .ZI_OK;
}

pub fn enableHook(hook_handle: abi.zi_hook_t) abi.zi_status_t {
    const hook = castHook(hook_handle) orelse return .ZI_INVALID_ARGUMENT;
    const runtime = hook.owner;
    if (runtime.closed) return .ZI_INVALID_ARGUMENT;
    return switch (hook.lifecycle) {
        .enabled => .ZI_OK,
        .disabled => blk: {
            kernel.execute.enable(&hook.active) catch |err| break :blk mapError(err);
            hook.lifecycle = .enabled;
            break :blk .ZI_OK;
        },
        .removed => .ZI_OK,
    };
}

pub fn disableHook(hook_handle: abi.zi_hook_t) abi.zi_status_t {
    const hook = castHook(hook_handle) orelse return .ZI_INVALID_ARGUMENT;
    const runtime = hook.owner;
    if (runtime.closed) return .ZI_INVALID_ARGUMENT;
    return switch (hook.lifecycle) {
        .disabled => .ZI_OK,
        .enabled => blk: {
            kernel.execute.disable(&hook.active) catch |err| break :blk mapError(err);
            hook.lifecycle = .disabled;
            break :blk .ZI_OK;
        },
        .removed => .ZI_OK,
    };
}

pub fn removeHook(hook_handle: abi.zi_hook_t) abi.zi_status_t {
    const hook = castHook(hook_handle) orelse return .ZI_INVALID_ARGUMENT;
    const runtime = hook.owner;
    if (runtime.closed) return .ZI_INVALID_ARGUMENT;
    if (hook.lifecycle == .removed) return .ZI_OK;
    kernel.execute.remove(&hook.active, runtime.allocator) catch |err| return mapError(err);
    hook.lifecycle = .removed;
    return .ZI_OK;
}

pub fn resolveSymbol(rt: abi.zi_runtime_t, query: *const abi.zi_symbol_query_t, out_site: *abi.zi_exec_site_t) abi.zi_status_t {
    _ = rt;
    if (query.size != @sizeOf(abi.zi_symbol_query_t) or query.symbol_name == null) return .ZI_INVALID_ARGUMENT;
    const symbol_name = std.mem.span(query.symbol_name.?);
    const image_name = if (query.image_name) |z| std.mem.span(z) else null;
    const address = platform.darwin.resolveSymbol(image_name, symbol_name) catch |err| return mapError(err);
    out_site.* = .{
        .size = @sizeOf(abi.zi_exec_site_t),
        .kind = .ZI_TARGET_EXEC_SITE,
        .arch = platform.darwin.currentArch(),
        .address = @ptrFromInt(address),
        .image_name = query.image_name,
        .symbol_name = query.symbol_name,
        .flags = query.flags,
    };
    return .ZI_OK;
}

pub fn resolveImageOffset(rt: abi.zi_runtime_t, query: *const abi.zi_image_offset_query_t, out_site: *abi.zi_exec_site_t) abi.zi_status_t {
    _ = rt;
    if (query.size != @sizeOf(abi.zi_image_offset_query_t) or query.image_name == null) return .ZI_INVALID_ARGUMENT;
    const image_name = std.mem.span(query.image_name.?);
    const address = platform.darwin.resolveImageOffset(image_name, query.offset, query.kind) catch |err| return mapError(err);
    out_site.* = .{
        .size = @sizeOf(abi.zi_exec_site_t),
        .kind = .ZI_TARGET_EXEC_SITE,
        .arch = platform.darwin.currentArch(),
        .address = @ptrFromInt(address),
        .image_name = query.image_name,
        .symbol_name = null,
        .flags = query.flags,
    };
    return .ZI_OK;
}

pub fn resolvePatternBytes(rt: abi.zi_runtime_t, query: *const abi.zi_pattern_bytes_query_t, out_site: *abi.zi_exec_site_t) abi.zi_status_t {
    _ = rt;
    if (query.size != @sizeOf(abi.zi_pattern_bytes_query_t)) return .ZI_INVALID_ARGUMENT;
    const address = platform.darwin.resolvePatternBytes(
        if (query.image_name) |z| std.mem.span(z) else null,
        if (query.segment_name) |z| std.mem.span(z) else null,
        if (query.section_name) |z| std.mem.span(z) else null,
        query.pattern,
        query.occurrence,
        query.result_offset,
    ) catch |err| return mapError(err);
    out_site.* = .{
        .size = @sizeOf(abi.zi_exec_site_t),
        .kind = .ZI_TARGET_EXEC_SITE,
        .arch = platform.darwin.currentArch(),
        .address = @ptrFromInt(address),
        .image_name = query.image_name,
        .symbol_name = null,
        .flags = query.flags,
    };
    return .ZI_OK;
}

pub fn resolvePatternText(rt: abi.zi_runtime_t, query: *const abi.zi_pattern_text_query_t, out_site: *abi.zi_exec_site_t) abi.zi_status_t {
    _ = rt;
    if (query.size != @sizeOf(abi.zi_pattern_text_query_t) or query.pattern_text == null) return .ZI_INVALID_ARGUMENT;
    const address = platform.darwin.resolvePatternText(
        std.heap.smp_allocator,
        if (query.image_name) |z| std.mem.span(z) else null,
        if (query.segment_name) |z| std.mem.span(z) else null,
        if (query.section_name) |z| std.mem.span(z) else null,
        std.mem.span(query.pattern_text.?),
        query.occurrence,
        query.result_offset,
    ) catch |err| return mapError(err);
    out_site.* = .{
        .size = @sizeOf(abi.zi_exec_site_t),
        .kind = .ZI_TARGET_EXEC_SITE,
        .arch = platform.darwin.currentArch(),
        .address = @ptrFromInt(address),
        .image_name = query.image_name,
        .symbol_name = null,
        .flags = query.flags,
    };
    return .ZI_OK;
}

pub fn resolveObjcMethod(rt: abi.zi_runtime_t, query: *const abi.zi_objc_method_query_t, out_site: *abi.zi_exec_site_t) abi.zi_status_t {
    _ = rt;
    if (query.size != @sizeOf(abi.zi_objc_method_query_t) or query.class_name == null or query.selector_name == null) return .ZI_INVALID_ARGUMENT;
    const address = objc.resolveMethodAddress(query.class_name.?, query.selector_name.?, query.is_class_method) catch |err| return mapError(err);
    out_site.* = .{
        .size = @sizeOf(abi.zi_exec_site_t),
        .kind = .ZI_TARGET_EXEC_SITE,
        .arch = platform.darwin.currentArch(),
        .address = @ptrFromInt(address),
        .image_name = null,
        .symbol_name = query.selector_name,
        .flags = query.flags,
    };
    return .ZI_OK;
}

pub fn resolveSwiftSlot(rt: abi.zi_runtime_t, query: *const abi.zi_swift_slot_query_t, out_slot: *abi.zi_data_slot_t) abi.zi_status_t {
    _ = rt;
    if (query.size != @sizeOf(abi.zi_swift_slot_query_t)) return .ZI_INVALID_ARGUMENT;
    const slot = swift.lookupSlot(query) catch |err| return mapError(err);
    out_slot.* = .{
        .size = @sizeOf(abi.zi_data_slot_t),
        .kind = .ZI_TARGET_DATA_SLOT,
        .address = slot,
        .image_name = query.image_name,
        .symbol_name = query.mangled_name orelse query.demangled_name,
        .flags = query.flags,
    };
    return .ZI_OK;
}

pub fn installPatchBytes(rt: abi.zi_runtime_t, spec: *const abi.zi_patch_bytes_spec_t, out_hook: *abi.zi_hook_t) abi.zi_status_t {
    const runtime = castRuntime(rt) orelse return .ZI_INVALID_ARGUMENT;
    if (runtime.closed) return .ZI_INVALID_ARGUMENT;
    const compiled = kernel.compile.patchBytes(spec) catch |err| return mapError(err);
    return installLocked(runtime, compiled, out_hook);
}

pub fn installReplaceSite(rt: abi.zi_runtime_t, spec: *const abi.zi_replace_site_spec_t, out_hook: *abi.zi_hook_t) abi.zi_status_t {
    const runtime = castRuntime(rt) orelse return .ZI_INVALID_ARGUMENT;
    if (runtime.closed) return .ZI_INVALID_ARGUMENT;
    const compiled = kernel.compile.replaceSite(spec) catch |err| return mapError(err);
    return installLocked(runtime, compiled, out_hook);
}

pub fn installInstrumentSite(rt: abi.zi_runtime_t, spec: *const abi.zi_instrument_site_spec_t, out_hook: *abi.zi_hook_t) abi.zi_status_t {
    _ = rt;
    _ = spec;
    _ = out_hook;
    return .ZI_UNSUPPORTED_OPERATION;
}

pub fn installReplaceSlot(rt: abi.zi_runtime_t, spec: *const abi.zi_replace_slot_spec_t, out_hook: *abi.zi_hook_t) abi.zi_status_t {
    const runtime = castRuntime(rt) orelse return .ZI_INVALID_ARGUMENT;
    if (runtime.closed) return .ZI_INVALID_ARGUMENT;
    const compiled = kernel.compile.replaceSlot(spec) catch |err| return mapError(err);
    return installLocked(runtime, compiled, out_hook);
}

pub fn installObjcObjectReplace(rt: abi.zi_runtime_t, spec: *const abi.zi_objc_object_replace_spec_t, out_hook: *abi.zi_hook_t) abi.zi_status_t {
    const runtime = castRuntime(rt) orelse return .ZI_INVALID_ARGUMENT;
    if (runtime.closed) return .ZI_INVALID_ARGUMENT;
    const compiled = kernel.compile.objcObjectReplace(spec) catch |err| return mapError(err);
    return installLocked(runtime, compiled, out_hook);
}

pub fn debugLookupFileLine(rt: abi.zi_runtime_t, request: *abi.zi_debug_file_line_t) abi.zi_status_t {
    _ = rt;
    if (request.size != @sizeOf(abi.zi_debug_file_line_t)) return .ZI_INVALID_ARGUMENT;
    platform.darwin.debugLookup(request) catch |err| return mapError(err);
    return .ZI_OK;
}

fn installLocked(runtime: *Runtime, compiled: kernel.plan.OperationPlan, out_hook: *abi.zi_hook_t) abi.zi_status_t {
    const target_key = switch (compiled) {
        .patch_bytes => |patch| @intFromPtr(patch.site.address.?),
        .replace_site => |replace| @intFromPtr(replace.site.address.?),
        .replace_slot => |replace| @intFromPtr(replace.slot.address.?),
        .objc_object_replace => |replace| @intFromPtr(replace.object.?) ^ (@intFromPtr(replace.selector_name.?) << 1),
    };
    for (runtime.hooks.items) |existing| {
        if (existing.lifecycle != .removed and existing.target_key == target_key) return .ZI_CONFLICT;
    }
    const hook = runtime.allocator.create(Hook) catch return .ZI_OUT_OF_MEMORY;
    errdefer runtime.allocator.destroy(hook);
    const active = kernel.execute.instantiate(runtime.allocator, compiled) catch |err| return mapError(err);
    hook.* = .{
        .owner = runtime,
        .target_key = target_key,
        .active = active,
    };
    runtime.hooks.append(runtime.allocator, hook) catch {
        kernel.execute.remove(&hook.active, runtime.allocator) catch {};
        runtime.allocator.destroy(hook);
        return .ZI_OUT_OF_MEMORY;
    };
    out_hook.* = @ptrCast(hook);
    return .ZI_OK;
}

fn castRuntime(rt: abi.zi_runtime_t) ?*Runtime {
    const raw = rt orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn castHook(hook: abi.zi_hook_t) ?*Hook {
    const raw = hook orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn mapError(err: anyerror) abi.zi_status_t {
    return switch (err) {
        error.InvalidArgument => .ZI_INVALID_ARGUMENT,
        error.UnsupportedPlatform => .ZI_UNSUPPORTED_PLATFORM,
        error.UnsupportedOperation => .ZI_UNSUPPORTED_OPERATION,
        error.UnsupportedInstruction => .ZI_UNSUPPORTED_INSTRUCTION,
        error.NotFound => .ZI_NOT_FOUND,
        error.OutOfMemory => .ZI_OUT_OF_MEMORY,
        error.AccessDenied => .ZI_ACCESS_DENIED,
        error.GuardFailed => .ZI_GUARD_FAILED,
        error.Conflict => .ZI_CONFLICT,
        error.InternalError => .ZI_INTERNAL_ERROR,
        error.BufferTooSmall => .ZI_BUFFER_TOO_SMALL,
        error.ReentrantCall => .ZI_REENTRANT_CALL,
        error.SymbolAmbiguous => .ZI_SYMBOL_AMBIGUOUS,
        else => .ZI_INTERNAL_ERROR,
    };
}
