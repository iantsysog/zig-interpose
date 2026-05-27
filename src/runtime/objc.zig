const std = @import("std");
const builtin = @import("builtin");

const abi = @import("../abi/types.zig");

pub const Error = error{
    UnsupportedPlatform,
    UnsupportedOperation,
    InvalidArgument,
    NotFound,
    Conflict,
};

const Class = *opaque {};
const Method = *opaque {};
const SEL = *opaque {};
const IMP = ?*anyopaque;

const HelperResult = extern struct {
    state: ?*anyopaque = null,
    owner: ?Class = null,
    object: ?*anyopaque = null,
    object_original_class: ?Class = null,
    selector: SEL,
    types: ?[*:0]const u8 = null,
    original: IMP = null,
    replacement: IMP = null,
    conflict_key: usize = 0,
};

extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "c" fn object_getClass(obj: ?*anyopaque) ?Class;
extern "c" fn object_setClass(obj: ?*anyopaque, cls: Class) ?Class;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn class_getInstanceMethod(cls: Class, name: SEL) ?Method;
extern "c" fn class_getClassMethod(cls: Class, name: SEL) ?Method;
extern "c" fn method_getImplementation(method: Method) IMP;
extern "c" fn method_getTypeEncoding(method: Method) ?[*:0]const u8;
extern "c" fn method_setImplementation(method: Method, imp: IMP) IMP;
extern "c" fn class_replaceMethod(cls: Class, name: SEL, imp: IMP, types: ?[*:0]const u8) bool;
extern "c" fn zi_objc_dynamic_subclass_install(spec: *const abi.zi_objc_object_replace_spec_t, out_result: *HelperResult) abi.zi_status_t;
extern "c" fn zi_objc_dynamic_subclass_apply(state: ?*anyopaque) abi.zi_status_t;
extern "c" fn zi_objc_dynamic_subclass_restore(state: ?*anyopaque) abi.zi_status_t;
extern "c" fn zi_objc_dynamic_subclass_free(state: ?*anyopaque) void;

pub const Replacement = struct {
    mode: Mode,
    method: ?Method = null,
    owner: ?Class = null,
    object: ?*anyopaque = null,
    object_original_class: ?Class = null,
    selector: SEL,
    types: ?[*:0]const u8 = null,
    original: IMP = null,
    replacement: IMP = null,
    user_data: ?*anyopaque = null,
    helper_state: ?*anyopaque = null,

    pub fn conflictKey(self: Replacement) usize {
        const base = if (self.object) |object| @intFromPtr(object) else @intFromPtr(self.owner orelse return @intFromPtr(self.selector));
        return base ^ (@intFromPtr(self.selector) << 1);
    }
};

pub const Mode = enum {
    direct_replace,
    dynamic_subclass,
};

pub fn resolveMethodAddress(class_name: [*:0]const u8, selector_name: [*:0]const u8, is_class_method: bool) Error!usize {
    if (!isDarwin()) return error.UnsupportedPlatform;
    const cls = objc_getClass(class_name) orelse return error.NotFound;
    const sel = sel_registerName(selector_name);
    const method = if (is_class_method) class_getClassMethod(cls, sel) else class_getInstanceMethod(cls, sel);
    return @intFromPtr(method_getImplementation(method orelse return error.NotFound) orelse return error.NotFound);
}

pub fn installObjectReplace(spec: *const abi.zi_objc_object_replace_spec_t) Error!Replacement {
    if (!isDarwin()) return error.UnsupportedPlatform;
    const selector_name = spec.selector_name orelse return error.InvalidArgument;
    if (isDangerousSelector(std.mem.span(selector_name)) and (spec.flags & abi.ZI_OBJC_ALLOW_DANGEROUS_SELECTOR) == 0) return error.Conflict;
    return dynamicSubclass(spec, selector_name);
}

pub fn applyObjectReplace(replacement: Replacement) Error!void {
    switch (replacement.mode) {
        .direct_replace => try applyDirect(replacement),
        .dynamic_subclass => try applyDynamicSubclass(replacement),
    }
}

pub fn restoreObjectReplace(replacement: Replacement) Error!void {
    switch (replacement.mode) {
        .direct_replace => try restoreDirect(replacement),
        .dynamic_subclass => try restoreDynamicSubclass(replacement),
    }
}

pub fn free(allocator: std.mem.Allocator, replacement: Replacement) void {
    _ = allocator;
    if (replacement.helper_state) |state| zi_objc_dynamic_subclass_free(state);
}

fn directReplace(class_name: [*:0]const u8, selector_name: [*:0]const u8, replacement: IMP, user_data: ?*anyopaque) Error!Replacement {
    const cls = objc_getClass(class_name) orelse return error.NotFound;
    const sel = sel_registerName(selector_name);
    const owner = cls;
    const method = class_getInstanceMethod(cls, sel) orelse return error.NotFound;
    const result: Replacement = .{
        .mode = .direct_replace,
        .method = method,
        .owner = owner,
        .selector = sel,
        .types = method_getTypeEncoding(method),
        .original = method_getImplementation(method),
        .replacement = replacement,
        .user_data = user_data,
    };
    try applyDirect(result);
    return result;
}

fn dynamicSubclass(spec: *const abi.zi_objc_object_replace_spec_t, selector_name: [*:0]const u8) Error!Replacement {
    if (spec.replacement == null) return error.InvalidArgument;
    if (spec.object == null) return error.InvalidArgument;
    _ = selector_name;

    var helper: HelperResult = .{ .selector = undefined };
    const status = zi_objc_dynamic_subclass_install(spec, &helper);
    switch (status) {
        .ZI_OK => {},
        .ZI_INVALID_ARGUMENT => return error.InvalidArgument,
        .ZI_UNSUPPORTED_OPERATION => return error.UnsupportedOperation,
        .ZI_NOT_FOUND => return error.NotFound,
        .ZI_OUT_OF_MEMORY => return error.UnsupportedOperation,
        .ZI_CONFLICT => return error.Conflict,
        else => return error.UnsupportedOperation,
    }
    return .{
        .mode = .dynamic_subclass,
        .owner = helper.owner,
        .object = helper.object,
        .object_original_class = helper.object_original_class,
        .selector = helper.selector,
        .types = helper.types,
        .original = helper.original,
        .replacement = helper.replacement,
        .user_data = spec.options.user_data,
        .helper_state = helper.state,
    };
}

fn applyDirect(replacement: Replacement) Error!void {
    const method = replacement.method orelse return error.InvalidArgument;
    const owner = replacement.owner orelse return error.InvalidArgument;
    if (method_getImplementation(method) != replacement.original) return error.Conflict;
    _ = class_replaceMethod(owner, replacement.selector, replacement.replacement, replacement.types);
    _ = method_setImplementation(method, replacement.replacement);
}

fn restoreDirect(replacement: Replacement) Error!void {
    const method = replacement.method orelse return error.InvalidArgument;
    if (method_getImplementation(method) != replacement.replacement) return error.Conflict;
    _ = method_setImplementation(method, replacement.original);
}

fn applyDynamicSubclass(replacement: Replacement) Error!void {
    const status = zi_objc_dynamic_subclass_apply(replacement.helper_state);
    switch (status) {
        .ZI_OK => {},
        .ZI_INVALID_ARGUMENT => return error.InvalidArgument,
        .ZI_CONFLICT => return error.Conflict,
        else => return error.UnsupportedOperation,
    }
}

fn restoreDynamicSubclass(replacement: Replacement) Error!void {
    const status = zi_objc_dynamic_subclass_restore(replacement.helper_state);
    switch (status) {
        .ZI_OK => {},
        .ZI_INVALID_ARGUMENT => return error.InvalidArgument,
        else => return error.UnsupportedOperation,
    }
}

fn isDangerousSelector(selector: []const u8) bool {
    return std.mem.eql(u8, selector, "retain") or
        std.mem.eql(u8, selector, "release") or
        std.mem.eql(u8, selector, "autorelease") or
        std.mem.eql(u8, selector, "dealloc") or
        std.mem.eql(u8, selector, "forwardInvocation:");
}

fn isDarwin() bool {
    return comptime builtin.os.tag.isDarwin();
}

test "dangerous selector gate" {
    try std.testing.expect(isDangerousSelector("dealloc"));
    try std.testing.expect(!isDangerousSelector("description"));
}
