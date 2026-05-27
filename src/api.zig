const std = @import("std");

const abi = @import("abi/types.zig");
const runtime = @import("api/runtime.zig");

pub const ZI_CONTEXT_INTEGER_REGISTER_COUNT: usize = abi.ZI_CONTEXT_INTEGER_REGISTER_COUNT;
pub const ZI_CONTEXT_VECTOR_REGISTER_COUNT: usize = abi.ZI_CONTEXT_VECTOR_REGISTER_COUNT;
pub const ZI_CONTEXT_VECTOR_REGISTER_BYTES: usize = abi.ZI_CONTEXT_VECTOR_REGISTER_BYTES;
pub const ZI_IMAGE_UUID_BYTES: usize = abi.ZI_IMAGE_UUID_BYTES;
pub const ZI_INSTALL_ALLOW_RACY_PATCH: u32 = abi.ZI_INSTALL_ALLOW_RACY_PATCH;
pub const ZI_OBJC_ALLOW_KVO_CLASS_MISMATCH: u32 = abi.ZI_OBJC_ALLOW_KVO_CLASS_MISMATCH;
pub const ZI_OBJC_ALLOW_DANGEROUS_SELECTOR: u32 = abi.ZI_OBJC_ALLOW_DANGEROUS_SELECTOR;

pub const zi_status_t = abi.zi_status_t;
pub const zi_arch_t = abi.zi_arch_t;
pub const zi_target_kind_t = abi.zi_target_kind_t;
pub const zi_macho_offset_kind_t = abi.zi_macho_offset_kind_t;
pub const zi_return_kind_t = abi.zi_return_kind_t;
pub const zi_entry_action_t = abi.zi_entry_action_t;
pub const zi_return_action_t = abi.zi_return_action_t;
pub const zi_swift_lookup_kind_t = abi.zi_swift_lookup_kind_t;
pub const zi_runtime_t = abi.zi_runtime_t;
pub const zi_hook_t = abi.zi_hook_t;
pub const zi_bytes_t = abi.zi_bytes_t;
pub const zi_guard_t = abi.zi_guard_t;
pub const zi_cstr_t = abi.zi_cstr_t;
pub const zi_pattern_t = abi.zi_pattern_t;
pub const zi_return_value_t = abi.zi_return_value_t;
pub const zi_exec_site_t = abi.zi_exec_site_t;
pub const zi_data_slot_t = abi.zi_data_slot_t;
pub const zi_entry_frame_t = abi.zi_entry_frame_t;
pub const zi_return_frame_t = abi.zi_return_frame_t;
pub const zi_entry_callback_fn = abi.zi_entry_callback_fn;
pub const zi_return_callback_fn = abi.zi_return_callback_fn;
pub const zi_install_options_t = abi.zi_install_options_t;
pub const zi_symbol_query_t = abi.zi_symbol_query_t;
pub const zi_image_offset_query_t = abi.zi_image_offset_query_t;
pub const zi_pattern_bytes_query_t = abi.zi_pattern_bytes_query_t;
pub const zi_pattern_text_query_t = abi.zi_pattern_text_query_t;
pub const zi_objc_method_query_t = abi.zi_objc_method_query_t;
pub const zi_swift_slot_query_t = abi.zi_swift_slot_query_t;
pub const zi_patch_bytes_spec_t = abi.zi_patch_bytes_spec_t;
pub const zi_replace_site_spec_t = abi.zi_replace_site_spec_t;
pub const zi_instrument_site_spec_t = abi.zi_instrument_site_spec_t;
pub const zi_replace_slot_spec_t = abi.zi_replace_slot_spec_t;
pub const zi_objc_object_replace_spec_t = abi.zi_objc_object_replace_spec_t;
pub const zi_debug_file_line_t = abi.zi_debug_file_line_t;

pub export fn zi_status_name(status: zi_status_t) [*:0]const u8 {
    return abi.statusName(status);
}

pub export fn zi_runtime_open(out_runtime: ?*zi_runtime_t) zi_status_t {
    const out = out_runtime orelse return .ZI_INVALID_ARGUMENT;
    out.* = null;
    return runtime.openRuntime(out);
}

pub export fn zi_runtime_close(rt: zi_runtime_t) zi_status_t {
    return runtime.closeRuntime(rt);
}

pub export fn zi_runtime_reset(rt: zi_runtime_t) zi_status_t {
    return runtime.resetRuntime(rt);
}

pub export fn zi_hook_enable(hook: zi_hook_t) zi_status_t {
    return runtime.enableHook(hook);
}

pub export fn zi_hook_disable(hook: zi_hook_t) zi_status_t {
    return runtime.disableHook(hook);
}

pub export fn zi_hook_remove(hook: zi_hook_t) zi_status_t {
    return runtime.removeHook(hook);
}

pub export fn zi_resolve_symbol(rt: zi_runtime_t, query: ?*const zi_symbol_query_t, out_site: ?*zi_exec_site_t) zi_status_t {
    const q = query orelse return .ZI_INVALID_ARGUMENT;
    const out = out_site orelse return .ZI_INVALID_ARGUMENT;
    return runtime.resolveSymbol(rt, q, out);
}

pub export fn zi_resolve_image_offset(rt: zi_runtime_t, query: ?*const zi_image_offset_query_t, out_site: ?*zi_exec_site_t) zi_status_t {
    const q = query orelse return .ZI_INVALID_ARGUMENT;
    const out = out_site orelse return .ZI_INVALID_ARGUMENT;
    return runtime.resolveImageOffset(rt, q, out);
}

pub export fn zi_resolve_pattern_bytes(rt: zi_runtime_t, query: ?*const zi_pattern_bytes_query_t, out_site: ?*zi_exec_site_t) zi_status_t {
    const q = query orelse return .ZI_INVALID_ARGUMENT;
    const out = out_site orelse return .ZI_INVALID_ARGUMENT;
    return runtime.resolvePatternBytes(rt, q, out);
}

pub export fn zi_resolve_pattern_text(rt: zi_runtime_t, query: ?*const zi_pattern_text_query_t, out_site: ?*zi_exec_site_t) zi_status_t {
    const q = query orelse return .ZI_INVALID_ARGUMENT;
    const out = out_site orelse return .ZI_INVALID_ARGUMENT;
    return runtime.resolvePatternText(rt, q, out);
}

pub export fn zi_resolve_objc_method(rt: zi_runtime_t, query: ?*const zi_objc_method_query_t, out_site: ?*zi_exec_site_t) zi_status_t {
    const q = query orelse return .ZI_INVALID_ARGUMENT;
    const out = out_site orelse return .ZI_INVALID_ARGUMENT;
    return runtime.resolveObjcMethod(rt, q, out);
}

pub export fn zi_resolve_swift_slot(rt: zi_runtime_t, query: ?*const zi_swift_slot_query_t, out_slot: ?*zi_data_slot_t) zi_status_t {
    const q = query orelse return .ZI_INVALID_ARGUMENT;
    const out = out_slot orelse return .ZI_INVALID_ARGUMENT;
    return runtime.resolveSwiftSlot(rt, q, out);
}

pub export fn zi_install_patch_bytes(rt: zi_runtime_t, spec: ?*const zi_patch_bytes_spec_t, out_hook: ?*zi_hook_t) zi_status_t {
    const s = spec orelse return .ZI_INVALID_ARGUMENT;
    const out = out_hook orelse return .ZI_INVALID_ARGUMENT;
    out.* = null;
    return runtime.installPatchBytes(rt, s, out);
}

pub export fn zi_install_replace_site(rt: zi_runtime_t, spec: ?*const zi_replace_site_spec_t, out_hook: ?*zi_hook_t) zi_status_t {
    const s = spec orelse return .ZI_INVALID_ARGUMENT;
    const out = out_hook orelse return .ZI_INVALID_ARGUMENT;
    out.* = null;
    return runtime.installReplaceSite(rt, s, out);
}

pub export fn zi_install_instrument_site(rt: zi_runtime_t, spec: ?*const zi_instrument_site_spec_t, out_hook: ?*zi_hook_t) zi_status_t {
    const s = spec orelse return .ZI_INVALID_ARGUMENT;
    const out = out_hook orelse return .ZI_INVALID_ARGUMENT;
    out.* = null;
    return runtime.installInstrumentSite(rt, s, out);
}

pub export fn zi_install_replace_slot(rt: zi_runtime_t, spec: ?*const zi_replace_slot_spec_t, out_hook: ?*zi_hook_t) zi_status_t {
    const s = spec orelse return .ZI_INVALID_ARGUMENT;
    const out = out_hook orelse return .ZI_INVALID_ARGUMENT;
    out.* = null;
    return runtime.installReplaceSlot(rt, s, out);
}

pub export fn zi_install_objc_object_replace(rt: zi_runtime_t, spec: ?*const zi_objc_object_replace_spec_t, out_hook: ?*zi_hook_t) zi_status_t {
    const s = spec orelse return .ZI_INVALID_ARGUMENT;
    const out = out_hook orelse return .ZI_INVALID_ARGUMENT;
    out.* = null;
    return runtime.installObjcObjectReplace(rt, s, out);
}

pub export fn zi_debug_lookup_file_line(rt: zi_runtime_t, request: ?*zi_debug_file_line_t) zi_status_t {
    const req = request orelse return .ZI_INVALID_ARGUMENT;
    return runtime.debugLookupFileLine(rt, req);
}

test {
    std.testing.refAllDecls(@This());
}
