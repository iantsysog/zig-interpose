const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("../api.zig");
const debug = @import("../debug/dwarf.zig");
const images = @import("../macho/images.zig");
const memory = @import("../platform/darwin/memory.zig");
const objc = @import("../runtime/objc.zig");
const swift = @import("../runtime/swift.zig");
const trampoline = @import("../backend/trampoline/mod.zig");

pub const Runtime = struct {
    id: c.zi_runtime_t = c.ZI_NULL_RUNTIME,
    allocator: Allocator,
    hooks: std.ArrayList(*Hook) = .empty,
    conflicts: std.AutoHashMap(usize, *Hook),
    lock: std.atomic.Mutex = .unlocked,
    registry_refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    next_call_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    last_error: [512:0]u8 = [_:0]u8{0} ** 512,
    registry_closing: bool = false,
    destroyed: bool = false,
};

pub const Hook = struct {
    id: c.zi_hook_t = c.ZI_NULL_HOOK,
    owner: *Runtime,
    target_key: usize = 0,
    active: ActiveHook = .none,
    enabled: bool = false,
    removed: bool = false,
};

const Registry = struct {
    lock: std.atomic.Mutex = .unlocked,
    next_id: u64 = 1,
    runtimes: std.AutoHashMap(c.zi_runtime_t, *Runtime),
    hooks: std.AutoHashMap(c.zi_hook_t, *Hook),
    initialized: bool = false,
};

var registry: Registry = .{
    .runtimes = undefined,
    .hooks = undefined,
};

const ActiveHook = union(enum) {
    none,
    patch: PatchHook,
    trampoline: trampoline.Installation,
    objc_method: objc.Replacement,
    swift_slot: swift.SlotPatch,
};

const PatchHook = struct {
    address: usize,
    original: []u8,
    replacement: []u8,
    racy: bool,
};

const Error = error{
    InvalidArgument,
    UnsupportedPlatform,
    UnsupportedOperation,
    UnsupportedInstruction,
    NotFound,
    OutOfMemory,
    AccessDenied,
    GuardFailed,
    Conflict,
    InternalError,
    BufferTooSmall,
    ReentrantCall,
    SymbolAmbiguous,
};

pub fn create(out_runtime: *?*Runtime) c.zi_status_t {
    const allocator = std.heap.smp_allocator;
    const rt = allocator.create(Runtime) catch return .ZI_OUT_OF_MEMORY;
    rt.* = .{
        .allocator = allocator,
        .conflicts = std.AutoHashMap(usize, *Hook).init(allocator),
    };
    out_runtime.* = rt;
    return .ZI_OK;
}

pub fn createHandle(out_runtime: *c.zi_runtime_t) c.zi_status_t {
    var rt: ?*Runtime = null;
    const status = create(&rt);
    if (status != .ZI_OK) return status;
    const runtime_ptr = rt.?;
    registerRuntime(runtime_ptr) catch {
        _ = destroy(runtime_ptr);
        return .ZI_OUT_OF_MEMORY;
    };
    out_runtime.* = runtime_ptr.id;
    return .ZI_OK;
}

pub fn destroyHandle(handle: c.zi_runtime_t) c.zi_status_t {
    const rt = beginRuntimeDestroy(handle) orelse return .ZI_INVALID_ARGUMENT;
    waitForRuntimeRefs(rt);
    return destroy(rt);
}

pub fn resolveRuntime(handle: c.zi_runtime_t) ?*Runtime {
    if (handle == c.ZI_NULL_RUNTIME) return null;
    lockRegistry();
    defer registry.lock.unlock();
    ensureRegistryLocked();
    const rt = registry.runtimes.get(handle) orelse return null;
    if (rt.registry_closing) return null;
    _ = rt.registry_refs.fetchAdd(1, .acq_rel);
    return rt;
}

pub fn resolveHook(handle: c.zi_hook_t) ?*Hook {
    if (handle == c.ZI_NULL_HOOK) return null;
    lockRegistry();
    defer registry.lock.unlock();
    ensureRegistryLocked();
    const hook = registry.hooks.get(handle) orelse return null;
    if (hook.owner.registry_closing) return null;
    _ = hook.owner.registry_refs.fetchAdd(1, .acq_rel);
    return hook;
}

pub fn releaseRuntime(rt: *Runtime) void {
    _ = rt.registry_refs.fetchSub(1, .acq_rel);
}

pub fn releaseHook(hook: *Hook) void {
    releaseRuntime(hook.owner);
}

pub fn installInlineReplacementHandle(rt: *Runtime, spec: *const c.zi_inline_replacement_spec_t, out_hook: *c.zi_hook_t) c.zi_status_t {
    var hook: ?*Hook = null;
    const status = installInlineReplacement(rt, spec, &hook);
    if (status == .ZI_OK) out_hook.* = hook.?.id;
    return status;
}

pub fn installPatchHandle(rt: *Runtime, spec: *const c.zi_patch_spec_t, out_hook: *c.zi_hook_t) c.zi_status_t {
    var hook: ?*Hook = null;
    const status = installPatch(rt, spec, &hook);
    if (status == .ZI_OK) out_hook.* = hook.?.id;
    return status;
}

pub fn installCallProbeHandle(rt: *Runtime, spec: *const c.zi_call_probe_spec_t, out_hook: *c.zi_hook_t) c.zi_status_t {
    var hook: ?*Hook = null;
    const status = installCallProbe(rt, spec, &hook);
    if (status == .ZI_OK) out_hook.* = hook.?.id;
    return status;
}

pub fn installObjcMethodHandle(rt: *Runtime, spec: *const c.zi_objc_method_spec_t, out_hook: *c.zi_hook_t) c.zi_status_t {
    var hook: ?*Hook = null;
    const status = installObjcMethod(rt, spec, &hook);
    if (status == .ZI_OK) out_hook.* = hook.?.id;
    return status;
}

pub fn installSwiftSlotHandle(rt: *Runtime, spec: *const c.zi_swift_slot_spec_t, out_hook: *c.zi_hook_t) c.zi_status_t {
    var hook: ?*Hook = null;
    const status = installSwiftSlot(rt, spec, &hook);
    if (status == .ZI_OK) out_hook.* = hook.?.id;
    return status;
}

pub fn destroy(rt: *Runtime) c.zi_status_t {
    lock(rt);
    if (rt.destroyed) {
        rt.lock.unlock();
        return .ZI_OK;
    }
    const status = clearLocked(rt);
    if (status != .ZI_OK) {
        rt.lock.unlock();
        return status;
    }
    for (rt.hooks.items) |hook| {
        unregisterHook(hook);
        freeActiveLocked(rt, hook);
        rt.allocator.destroy(hook);
    }
    rt.hooks.clearAndFree(rt.allocator);
    rt.conflicts.deinit();
    rt.destroyed = true;
    rt.lock.unlock();
    rt.allocator.destroy(rt);
    return .ZI_OK;
}

pub fn clear(rt: *Runtime) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    return clearLocked(rt);
}

pub fn lastError(rt: *const Runtime) [*:0]const u8 {
    return &rt.last_error;
}

pub fn failUnlocked(rt: *Runtime, status: c.zi_status_t, message: []const u8) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    return failLocked(rt, status, message);
}

pub fn installInlineReplacement(rt: *Runtime, spec: *const c.zi_inline_replacement_spec_t, out_hook: *?*Hook) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_inline_replacement_spec_t, spec.size) catch |err| return statusFromErrorLocked(rt, err);
    if ((spec.flags & ~c.ZI_INSTALL_ALLOW_RACY_PATCH) != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "unknown inline replacement flags");
    const replacement = spec.replacement orelse return failLocked(rt, .ZI_INVALID_ARGUMENT, "replacement function is required");
    const target = resolveTarget(spec.target, spec.image_name, spec.symbol_name) catch |err| return statusFromErrorLocked(rt, err);
    const hook = createHookLocked(rt) catch return failLocked(rt, .ZI_OUT_OF_MEMORY, "out of memory creating hook");
    errdefer destroyUnregisteredHookLocked(rt, hook);
    hook.target_key = target;
    checkConflictLocked(rt, target) catch |err| return statusFromErrorLocked(rt, err);
    const installation = trampoline.replace(@ptrFromInt(target), replacement, .{ .racy = (spec.flags & c.ZI_INSTALL_ALLOW_RACY_PATCH) != 0 }) catch |err| return statusFromErrorLocked(rt, mapTrampolineError(err));
    if (spec.original_out) |out| out.* = installation.original;
    hook.active = .{ .trampoline = installation };
    hook.enabled = true;
    registerHookLocked(rt, hook) catch |err| {
        trampoline.remove(installation) catch |remove_err| return statusFromErrorLocked(rt, mapTrampolineError(remove_err));
        destroyUnregisteredHookLocked(rt, hook);
        return statusFromErrorLocked(rt, err);
    };
    out_hook.* = hook;
    return okLocked(rt);
}

pub fn installPatch(rt: *Runtime, spec: *const c.zi_patch_spec_t, out_hook: *?*Hook) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_patch_spec_t, spec.size) catch |err| return statusFromErrorLocked(rt, err);
    if ((spec.flags & ~c.ZI_INSTALL_ALLOW_RACY_PATCH) != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "unknown patch flags");
    const hook = createHookLocked(rt) catch return failLocked(rt, .ZI_OUT_OF_MEMORY, "out of memory creating hook");
    errdefer destroyUnregisteredHookLocked(rt, hook);
    const patch = buildPatchHookLocked(rt, spec) catch |err| return statusFromErrorLocked(rt, err);
    hook.target_key = patch.address;
    checkConflictLocked(rt, patch.address) catch |err| {
        rt.allocator.free(patch.original);
        rt.allocator.free(patch.replacement);
        return statusFromErrorLocked(rt, err);
    };
    hook.active = .{ .patch = patch };
    hook.enabled = true;
    registerHookLocked(rt, hook) catch |err| {
        uninstallActiveLocked(rt, hook) catch {};
        freeActiveLocked(rt, hook);
        destroyUnregisteredHookLocked(rt, hook);
        return statusFromErrorLocked(rt, err);
    };
    out_hook.* = hook;
    return okLocked(rt);
}

pub fn installCallProbe(rt: *Runtime, spec: *const c.zi_call_probe_spec_t, out_hook: *?*Hook) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_call_probe_spec_t, spec.size) catch |err| return statusFromErrorLocked(rt, err);
    if ((spec.flags & ~c.ZI_INSTALL_ALLOW_RACY_PATCH) != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "unknown call probe flags");
    if (spec.entry_callback == null and spec.return_callback == null) return failLocked(rt, .ZI_INVALID_ARGUMENT, "entry or return callback is required");
    const target = resolveTarget(spec.target, spec.image_name, spec.symbol_name) catch |err| return statusFromErrorLocked(rt, err);
    const hook = createHookLocked(rt) catch return failLocked(rt, .ZI_OUT_OF_MEMORY, "out of memory creating hook");
    errdefer destroyUnregisteredHookLocked(rt, hook);
    hook.target_key = target;
    checkConflictLocked(rt, target) catch |err| return statusFromErrorLocked(rt, err);
    const installation = trampoline.instrument(@ptrFromInt(target), .{
        .entry_callback = spec.entry_callback,
        .return_callback = spec.return_callback,
        .user_data = spec.user_data,
        .return_kind = spec.expected_return_kind,
        .return_size = spec.expected_return_size,
    }, .{ .racy = (spec.flags & c.ZI_INSTALL_ALLOW_RACY_PATCH) != 0 }) catch |err| return statusFromErrorLocked(rt, mapTrampolineError(err));
    hook.active = .{ .trampoline = installation };
    hook.enabled = true;
    registerHookLocked(rt, hook) catch |err| {
        trampoline.remove(installation) catch |remove_err| return statusFromErrorLocked(rt, mapTrampolineError(remove_err));
        destroyUnregisteredHookLocked(rt, hook);
        return statusFromErrorLocked(rt, err);
    };
    out_hook.* = hook;
    return okLocked(rt);
}

pub fn installObjcMethod(rt: *Runtime, spec: *const c.zi_objc_method_spec_t, out_hook: *?*Hook) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_objc_method_spec_t, spec.size) catch |err| return statusFromErrorLocked(rt, err);
    const known_flags = c.ZI_OBJC_ALLOW_KVO_CLASS_MISMATCH | c.ZI_OBJC_ALLOW_DANGEROUS_SELECTOR | c.ZI_OBJC_REQUIRE_AOP_FORWARDING;
    if ((spec.flags & ~known_flags) != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "unknown Objective-C flags");
    const hook = createHookLocked(rt) catch return failLocked(rt, .ZI_OUT_OF_MEMORY, "out of memory creating hook");
    errdefer destroyUnregisteredHookLocked(rt, hook);
    const result = objc.install(spec) catch |err| return statusFromErrorLocked(rt, mapObjcError(err));
    if (spec.original_out) |out| out.* = result.original;
    hook.target_key = result.conflictKey();
    checkConflictLocked(rt, hook.target_key) catch |err| {
        objc.restore(result) catch {};
        return statusFromErrorLocked(rt, err);
    };
    hook.active = .{ .objc_method = result };
    hook.enabled = true;
    registerHookLocked(rt, hook) catch |err| {
        objc.restore(result) catch |restore_err| return statusFromErrorLocked(rt, mapObjcError(restore_err));
        destroyUnregisteredHookLocked(rt, hook);
        return statusFromErrorLocked(rt, err);
    };
    out_hook.* = hook;
    return okLocked(rt);
}

pub fn installSwiftSlot(rt: *Runtime, spec: *const c.zi_swift_slot_spec_t, out_hook: *?*Hook) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_swift_slot_spec_t, spec.size) catch |err| return statusFromErrorLocked(rt, err);
    if (spec.flags != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "unknown Swift slot flags");
    const slot = resolveSwiftSlotFromSpec(spec) catch |err| return statusFromErrorLocked(rt, err);
    const replacement = spec.replacement orelse return failLocked(rt, .ZI_INVALID_ARGUMENT, "Swift slot replacement is required");
    const hook = createHookLocked(rt) catch return failLocked(rt, .ZI_OUT_OF_MEMORY, "out of memory creating hook");
    errdefer destroyUnregisteredHookLocked(rt, hook);
    hook.target_key = @intFromPtr(slot);
    checkConflictLocked(rt, hook.target_key) catch |err| return statusFromErrorLocked(rt, err);
    const result = swift.replaceSlot(slot, replacement) catch |err| return statusFromErrorLocked(rt, mapSwiftError(err));
    if (spec.original_out) |out| out.* = result.original;
    hook.active = .{ .swift_slot = result };
    hook.enabled = true;
    registerHookLocked(rt, hook) catch |err| {
        swift.restoreSlot(result) catch |restore_err| return statusFromErrorLocked(rt, mapSwiftError(restore_err));
        destroyUnregisteredHookLocked(rt, hook);
        return statusFromErrorLocked(rt, err);
    };
    out_hook.* = hook;
    return okLocked(rt);
}

pub fn lookupSwiftSlot(rt: *Runtime, query: *const c.zi_swift_slot_query_t, out_slot: *?*?*anyopaque) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_swift_slot_query_t, query.size) catch |err| return statusFromErrorLocked(rt, err);
    if (query.flags != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "unknown Swift query flags");
    out_slot.* = resolveSwiftSlot(query) catch |err| return statusFromErrorLocked(rt, err);
    return okLocked(rt);
}

pub fn resolveMachOOffset(rt: *Runtime, spec: *const c.zi_macho_offset_spec_t, out_address: *?*anyopaque) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_macho_offset_spec_t, spec.size) catch |err| return statusFromErrorLocked(rt, err);
    if (spec.flags != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "Mach-O offset resolver accepts no flags");
    const image_name = spec.image_name orelse return failLocked(rt, .ZI_INVALID_ARGUMENT, "Mach-O image is required");
    const kind = mapMachOOffsetKind(spec.kind);
    const address = images.resolveOffset(std.mem.span(image_name), spec.offset, kind) catch |err| return statusFromErrorLocked(rt, mapImageError(err));
    out_address.* = @ptrFromInt(address);
    return okLocked(rt);
}

pub fn resolvePattern(rt: *Runtime, spec: *const c.zi_pattern_spec_t, out_address: *?*anyopaque) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_pattern_spec_t, spec.size) catch |err| return statusFromErrorLocked(rt, err);
    if (spec.flags != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "pattern resolver accepts no flags");
    const pattern_bytes = requiredBytes(spec.pattern.bytes) orelse return failLocked(rt, .ZI_INVALID_ARGUMENT, "pattern bytes are required");
    const mask = optionalBytes(spec.pattern.mask);
    const address = images.resolvePattern(patternScope(spec), .{ .bytes = pattern_bytes, .mask = mask }) catch |err| return statusFromErrorLocked(rt, mapImageError(err));
    out_address.* = @ptrFromInt(address);
    return okLocked(rt);
}

pub fn resolvePatternText(rt: *Runtime, spec: *const c.zi_pattern_text_spec_t, out_address: *?*anyopaque) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_pattern_text_spec_t, spec.size) catch |err| return statusFromErrorLocked(rt, err);
    if (spec.flags != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "pattern text resolver accepts no flags");
    const pattern_text = spec.pattern_text orelse return failLocked(rt, .ZI_INVALID_ARGUMENT, "pattern text is required");
    const address = images.resolvePatternText(rt.allocator, patternTextScope(spec), std.mem.span(pattern_text)) catch |err| return statusFromErrorLocked(rt, mapImageError(err));
    out_address.* = @ptrFromInt(address);
    return okLocked(rt);
}

pub fn resolveSwiftSymbol(rt: *Runtime, spec: *const c.zi_swift_symbol_spec_t, out_address: *?*anyopaque) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_swift_symbol_spec_t, spec.size) catch |err| return statusFromErrorLocked(rt, err);
    if (spec.flags != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "Swift symbol resolver accepts no flags");
    const symbol_name = spec.symbol_name orelse return failLocked(rt, .ZI_INVALID_ARGUMENT, "Swift symbol name is required");
    const symbol = std.mem.span(symbol_name);
    if (!swift.isMangledSymbol(symbol)) return failLocked(rt, .ZI_INVALID_ARGUMENT, "Swift symbol must be mangled");
    const image_name = if (spec.image_name) |value| std.mem.span(value) else null;
    const address = images.resolveSymbol(image_name, symbol) catch |err| return statusFromErrorLocked(rt, mapImageError(err));
    out_address.* = @ptrFromInt(address);
    return okLocked(rt);
}

pub fn debugLookupFileLine(rt: *Runtime, request: *c.zi_debug_file_line_t) c.zi_status_t {
    lock(rt);
    defer rt.lock.unlock();
    if (rt.destroyed) return failLocked(rt, .ZI_INVALID_ARGUMENT, "runtime is destroyed");
    validateStructSize(c.zi_debug_file_line_t, request.size) catch |err| return statusFromErrorLocked(rt, err);
    if (request.flags != 0) return failLocked(rt, .ZI_UNSUPPORTED_OPERATION, "debug file-line lookup accepts no flags");
    debug.lookupFileLine(request) catch |err| return statusFromErrorLocked(rt, mapDebugError(err));
    return okLocked(rt);
}

pub fn enable(hook: *Hook) c.zi_status_t {
    const rt = hook.owner;
    lock(rt);
    defer rt.lock.unlock();
    if (hook.removed) return okLocked(rt);
    if (hook.enabled) return okLocked(rt);
    checkConflictLocked(rt, hook.target_key) catch |err| return statusFromErrorLocked(rt, err);
    reinstallActiveLocked(rt, hook) catch |err| return statusFromErrorLocked(rt, err);
    hook.enabled = true;
    registerConflictLocked(rt, hook) catch |err| return statusFromErrorLocked(rt, err);
    return okLocked(rt);
}

pub fn disable(hook: *Hook) c.zi_status_t {
    const rt = hook.owner;
    lock(rt);
    defer rt.lock.unlock();
    if (hook.removed) return okLocked(rt);
    if (!hook.enabled) return okLocked(rt);
    uninstallActiveLocked(rt, hook) catch |err| return statusFromErrorLocked(rt, err);
    unregisterConflictLocked(rt, hook);
    hook.enabled = false;
    return okLocked(rt);
}

pub fn remove(hook: *Hook) c.zi_status_t {
    const rt = hook.owner;
    lock(rt);
    defer rt.lock.unlock();
    if (hook.removed) return okLocked(rt);
    if (hook.enabled) {
        uninstallActiveLocked(rt, hook) catch |err| return statusFromErrorLocked(rt, err);
        unregisterConflictLocked(rt, hook);
    }
    hook.enabled = false;
    hook.removed = true;
    return okLocked(rt);
}

pub fn isEnabled(hook: *const Hook) bool {
    return !hook.removed and hook.enabled;
}

fn clearLocked(rt: *Runtime) c.zi_status_t {
    var i = rt.hooks.items.len;
    while (i > 0) {
        i -= 1;
        const hook = rt.hooks.items[i];
        if (!hook.removed and hook.enabled) {
            uninstallActiveLocked(rt, hook) catch |err| return statusFromErrorLocked(rt, err);
            unregisterConflictLocked(rt, hook);
        }
        hook.enabled = false;
        hook.removed = true;
    }
    return okLocked(rt);
}

fn lock(rt: *Runtime) void {
    while (!rt.lock.tryLock()) std.atomic.spinLoopHint();
}

fn lockRegistry() void {
    while (!registry.lock.tryLock()) std.atomic.spinLoopHint();
}

fn ensureRegistryLocked() void {
    if (registry.initialized) return;
    registry.runtimes = std.AutoHashMap(c.zi_runtime_t, *Runtime).init(std.heap.smp_allocator);
    registry.hooks = std.AutoHashMap(c.zi_hook_t, *Hook).init(std.heap.smp_allocator);
    registry.initialized = true;
}

fn registerRuntime(rt: *Runtime) Allocator.Error!void {
    lockRegistry();
    defer registry.lock.unlock();
    ensureRegistryLocked();
    const id = registry.next_id;
    registry.next_id += 1;
    rt.id = id;
    rt.registry_closing = false;
    try registry.runtimes.put(id, rt);
}

fn beginRuntimeDestroy(handle: c.zi_runtime_t) ?*Runtime {
    if (handle == c.ZI_NULL_RUNTIME) return null;
    lockRegistry();
    defer registry.lock.unlock();
    ensureRegistryLocked();
    const rt = registry.runtimes.get(handle) orelse return null;
    rt.registry_closing = true;
    _ = registry.runtimes.remove(handle);
    return rt;
}

fn waitForRuntimeRefs(rt: *Runtime) void {
    while (rt.registry_refs.load(.acquire) != 0) std.atomic.spinLoopHint();
}

fn registerHook(hook: *Hook) Allocator.Error!void {
    lockRegistry();
    defer registry.lock.unlock();
    ensureRegistryLocked();
    const id = registry.next_id;
    registry.next_id += 1;
    hook.id = id;
    try registry.hooks.put(id, hook);
}

fn unregisterHook(hook: *Hook) void {
    if (hook.id == c.ZI_NULL_HOOK) return;
    lockRegistry();
    defer registry.lock.unlock();
    ensureRegistryLocked();
    _ = registry.hooks.remove(hook.id);
    hook.id = c.ZI_NULL_HOOK;
}

fn createHookLocked(rt: *Runtime) Allocator.Error!*Hook {
    const hook = try rt.allocator.create(Hook);
    hook.* = .{ .owner = rt };
    return hook;
}

fn destroyUnregisteredHookLocked(rt: *Runtime, hook: *Hook) void {
    unregisterHook(hook);
    rt.allocator.destroy(hook);
}

fn registerHookLocked(rt: *Runtime, hook: *Hook) Error!void {
    try registerConflictLocked(rt, hook);
    errdefer unregisterConflictLocked(rt, hook);
    rt.hooks.append(rt.allocator, hook) catch return error.OutOfMemory;
    errdefer rt.hooks.items.len -= 1;
    registerHook(hook) catch return error.OutOfMemory;
}

fn registerConflictLocked(rt: *Runtime, hook: *Hook) Error!void {
    if (hook.target_key == 0) return;
    rt.conflicts.put(hook.target_key, hook) catch return error.OutOfMemory;
}

fn unregisterConflictLocked(rt: *Runtime, hook: *Hook) void {
    if (hook.target_key == 0) return;
    if (rt.conflicts.get(hook.target_key) == hook) _ = rt.conflicts.remove(hook.target_key);
}

fn checkConflictLocked(rt: *Runtime, key: usize) Error!void {
    if (key == 0) return;
    if (rt.conflicts.get(key)) |existing| {
        if (!existing.removed and existing.enabled) return error.Conflict;
    }
}

fn reinstallActiveLocked(rt: *Runtime, hook: *Hook) Error!void {
    switch (hook.active) {
        .none => {},
        .patch => |patch| memory.write(patch.address, patch.replacement, .{ .expected = patch.original, .racy = patch.racy }) catch |err| return mapMemoryError(err),
        .trampoline => |installation| try trampoline.enable(installation),
        .objc_method => |replacement| try objc.apply(replacement),
        .swift_slot => |slot_patch| swift.applySlot(slot_patch) catch |err| return mapSwiftError(err),
    }
    _ = rt;
}

fn uninstallActiveLocked(rt: *Runtime, hook: *Hook) Error!void {
    switch (hook.active) {
        .none => {},
        .patch => |patch| memory.write(patch.address, patch.original, .{ .expected = patch.replacement, .racy = patch.racy }) catch |err| return mapMemoryError(err),
        .trampoline => |installation| try trampoline.disable(installation),
        .objc_method => |replacement| try objc.restore(replacement),
        .swift_slot => |slot_patch| swift.restoreSlot(slot_patch) catch |err| return mapSwiftError(err),
    }
    _ = rt;
}

fn freeActiveLocked(rt: *Runtime, hook: *Hook) void {
    switch (hook.active) {
        .none => {},
        .patch => |patch| {
            rt.allocator.free(patch.original);
            rt.allocator.free(patch.replacement);
        },
        .trampoline => |installation| trampoline.free(installation),
        .objc_method => |replacement| objc.free(rt.allocator, replacement),
        .swift_slot => {},
    }
    hook.active = .none;
}

fn validateStructSize(comptime T: type, size: usize) Error!void {
    if (size != @sizeOf(T)) return error.InvalidArgument;
}

fn buildPatchHookLocked(rt: *Runtime, spec: *const c.zi_patch_spec_t) Error!PatchHook {
    const address = @intFromPtr(spec.address orelse return error.InvalidArgument);
    const replacement = requiredBytes(spec.replacement) orelse return error.InvalidArgument;
    if (replacement.len == 0) return error.InvalidArgument;
    const racy = (spec.flags & c.ZI_INSTALL_ALLOW_RACY_PATCH) != 0;
    try validateSourceGuard(spec.guard, address, replacement.len);
    const current = @as([*]const u8, @ptrFromInt(address))[0..replacement.len];
    if (optionalBytes(spec.guard.expected)) |expected| {
        if (expected.len != replacement.len) return error.InvalidArgument;
        if (!std.mem.eql(u8, current, expected)) return error.GuardFailed;
    }
    const original = rt.allocator.alloc(u8, replacement.len) catch return error.OutOfMemory;
    errdefer rt.allocator.free(original);
    @memcpy(original, current);
    const replacement_copy = rt.allocator.alloc(u8, replacement.len) catch return error.OutOfMemory;
    errdefer rt.allocator.free(replacement_copy);
    @memcpy(replacement_copy, replacement);
    memory.write(address, replacement_copy, .{ .expected = original, .racy = racy }) catch |err| return mapMemoryError(err);
    return .{ .address = address, .original = original, .replacement = replacement_copy, .racy = racy };
}

fn resolveTarget(address: ?*anyopaque, image_name_z: ?[*:0]const u8, symbol_name_z: ?[*:0]const u8) Error!usize {
    if (address) |ptr| return @intFromPtr(ptr);
    const symbol_name = symbol_name_z orelse return error.InvalidArgument;
    const image_name = if (image_name_z) |value| std.mem.span(value) else null;
    return images.resolveSymbol(image_name, std.mem.span(symbol_name)) catch |err| return mapImageError(err);
}

fn resolveSwiftSlotFromSpec(spec: *const c.zi_swift_slot_spec_t) Error!*?*anyopaque {
    if (spec.slot) |slot| return slot;
    return resolveSwiftSlot(&spec.query);
}

fn patternScope(spec: *const c.zi_pattern_spec_t) images.PatternScope {
    return .{
        .image = if (spec.image_name) |value| std.mem.span(value) else null,
        .segment = if (spec.segment_name) |value| std.mem.span(value) else null,
        .section = if (spec.section_name) |value| std.mem.span(value) else null,
        .occurrence = spec.occurrence,
        .result_offset = spec.result_offset,
    };
}

fn patternTextScope(spec: *const c.zi_pattern_text_spec_t) images.PatternScope {
    return .{
        .image = if (spec.image_name) |value| std.mem.span(value) else null,
        .segment = if (spec.segment_name) |value| std.mem.span(value) else null,
        .section = if (spec.section_name) |value| std.mem.span(value) else null,
        .occurrence = spec.occurrence,
        .result_offset = spec.result_offset,
    };
}

fn resolveSwiftSlot(query: *const c.zi_swift_slot_query_t) Error!*?*anyopaque {
    validateStructSize(c.zi_swift_slot_query_t, query.size) catch |err| return err;
    if (query.flags != 0) return error.UnsupportedOperation;
    return swift.lookupSlot(query) catch |err| return mapSwiftError(err);
}

fn mapMachOOffsetKind(kind: c.zi_macho_offset_kind_t) images.OffsetKind {
    return switch (kind) {
        .ZI_MACHO_OFFSET_VMADDR => .vmaddr,
        .ZI_MACHO_OFFSET_FILE => .file,
        .ZI_MACHO_OFFSET_GLOBAL_FILE => .global_file,
    };
}

fn validateSourceGuard(guard: c.zi_guard_t, address: usize, len: usize) Error!void {
    if (optionalBytes(guard.expected_sha256)) |expected_hash| {
        if (expected_hash.len != 32) return error.InvalidArgument;
        const current = @as([*]const u8, @ptrFromInt(address))[0..len];
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(current, &digest, .{});
        if (!std.mem.eql(u8, &digest, expected_hash)) return error.GuardFailed;
    }
}

fn requiredBytes(value: c.zi_bytes_t) ?[]const u8 {
    const ptr = value.ptr orelse return null;
    return ptr[0..value.len];
}

fn optionalBytes(value: c.zi_bytes_t) ?[]const u8 {
    const ptr = value.ptr orelse return null;
    return ptr[0..value.len];
}

fn okLocked(rt: *Runtime) c.zi_status_t {
    rt.last_error[0] = 0;
    return .ZI_OK;
}

fn failLocked(rt: *Runtime, status: c.zi_status_t, message: []const u8) c.zi_status_t {
    setLastErrorLocked(rt, message);
    return status;
}

fn statusFromErrorLocked(rt: *Runtime, err: Error) c.zi_status_t {
    const status: c.zi_status_t = switch (err) {
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
    };
    setLastErrorLocked(rt, @errorName(err));
    return status;
}

fn setLastErrorLocked(rt: *Runtime, message: []const u8) void {
    const len = @min(message.len, rt.last_error.len - 1);
    @memcpy(rt.last_error[0..len], message[0..len]);
    rt.last_error[len] = 0;
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

fn mapTrampolineError(err: trampoline.Error) Error {
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

fn mapObjcError(err: objc.Error) Error {
    return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.UnsupportedOperation => error.UnsupportedOperation,
        error.InvalidArgument => error.InvalidArgument,
        error.NotFound => error.NotFound,
        error.Conflict => error.Conflict,
    };
}

fn mapSwiftError(err: swift.Error) Error {
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

test "runtime lifecycle and per-runtime error" {
    var rt: ?*Runtime = null;
    try std.testing.expectEqual(c.zi_status_t.ZI_OK, create(&rt));
    try std.testing.expectEqualStrings("", std.mem.span(lastError(rt.?)));
    try std.testing.expectEqual(c.zi_status_t.ZI_UNSUPPORTED_OPERATION, failUnlocked(rt.?, .ZI_UNSUPPORTED_OPERATION, "flag required"));
    try std.testing.expectEqualStrings("flag required", std.mem.span(lastError(rt.?)));
    try std.testing.expectEqual(c.zi_status_t.ZI_OK, clear(rt.?));
    try std.testing.expectEqual(c.zi_status_t.ZI_OK, destroy(rt.?));
}
