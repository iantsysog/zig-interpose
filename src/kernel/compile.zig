const abi = @import("../abi/types.zig");
const plan = @import("plan.zig");
const interface = @import("../platform/interface.zig");

pub const Error = interface.Error;

pub fn patchBytes(spec: *const abi.zi_patch_bytes_spec_t) Error!plan.OperationPlan {
    if (spec.size != @sizeOf(abi.zi_patch_bytes_spec_t)) return error.InvalidArgument;
    if (spec.site.size != @sizeOf(abi.zi_exec_site_t) or spec.site.kind != .ZI_TARGET_EXEC_SITE or spec.site.address == null) return error.InvalidArgument;
    if (spec.replacement.len == 0 or spec.replacement.ptr == null) return error.InvalidArgument;
    if (spec.options.size != @sizeOf(abi.zi_install_options_t)) return error.InvalidArgument;
    if ((spec.options.flags & ~abi.ZI_INSTALL_ALLOW_RACY_PATCH) != 0) return error.UnsupportedOperation;
    const replacement = spec.replacement.ptr.?[0..spec.replacement.len];
    const expected = if (spec.guard.expected.len == 0) null else (spec.guard.expected.ptr orelse return error.InvalidArgument)[0..spec.guard.expected.len];
    if (expected) |guard| if (guard.len != replacement.len) return error.InvalidArgument;
    return .{ .patch_bytes = .{
        .site = spec.site,
        .replacement = replacement,
        .expected = expected,
        .racy = (spec.options.flags & abi.ZI_INSTALL_ALLOW_RACY_PATCH) != 0,
    } };
}

pub fn replaceSite(spec: *const abi.zi_replace_site_spec_t) Error!plan.OperationPlan {
    if (spec.size != @sizeOf(abi.zi_replace_site_spec_t)) return error.InvalidArgument;
    if (spec.site.size != @sizeOf(abi.zi_exec_site_t) or spec.site.kind != .ZI_TARGET_EXEC_SITE or spec.site.address == null) return error.InvalidArgument;
    if (spec.replacement == null) return error.InvalidArgument;
    if (spec.options.size != @sizeOf(abi.zi_install_options_t)) return error.InvalidArgument;
    if ((spec.options.flags & ~abi.ZI_INSTALL_ALLOW_RACY_PATCH) != 0) return error.UnsupportedOperation;
    return .{ .replace_site = .{
        .site = spec.site,
        .replacement = spec.replacement,
        .original_out = spec.original_out,
        .racy = (spec.options.flags & abi.ZI_INSTALL_ALLOW_RACY_PATCH) != 0,
    } };
}

pub fn replaceSlot(spec: *const abi.zi_replace_slot_spec_t) Error!plan.OperationPlan {
    if (spec.size != @sizeOf(abi.zi_replace_slot_spec_t)) return error.InvalidArgument;
    if (spec.slot.size != @sizeOf(abi.zi_data_slot_t) or spec.slot.kind != .ZI_TARGET_DATA_SLOT or spec.slot.address == null) return error.InvalidArgument;
    if (spec.replacement == null) return error.InvalidArgument;
    if (spec.options.size != @sizeOf(abi.zi_install_options_t)) return error.InvalidArgument;
    if (spec.options.flags != 0) return error.UnsupportedOperation;
    return .{ .replace_slot = .{
        .slot = spec.slot,
        .replacement = spec.replacement,
        .original_out = spec.original_out,
    } };
}

pub fn objcObjectReplace(spec: *const abi.zi_objc_object_replace_spec_t) Error!plan.OperationPlan {
    if (spec.size != @sizeOf(abi.zi_objc_object_replace_spec_t)) return error.InvalidArgument;
    if (spec.object == null or spec.selector_name == null or spec.replacement == null) return error.InvalidArgument;
    if (spec.options.size != @sizeOf(abi.zi_install_options_t)) return error.InvalidArgument;
    if ((spec.flags & ~(abi.ZI_OBJC_ALLOW_KVO_CLASS_MISMATCH | abi.ZI_OBJC_ALLOW_DANGEROUS_SELECTOR)) != 0) return error.UnsupportedOperation;
    if (spec.options.flags != 0) return error.UnsupportedOperation;
    return .{ .objc_object_replace = .{
        .object = spec.object,
        .selector_name = spec.selector_name,
        .replacement = spec.replacement,
        .original_out = spec.original_out,
        .flags = spec.flags,
        .options = spec.options,
    } };
}
