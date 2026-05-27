pub const ZI_CONTEXT_INTEGER_REGISTER_COUNT: usize = 32;
pub const ZI_CONTEXT_VECTOR_REGISTER_COUNT: usize = 32;
pub const ZI_CONTEXT_VECTOR_REGISTER_BYTES: usize = 16;
pub const ZI_IMAGE_UUID_BYTES: usize = 16;
pub const ZI_INSTALL_ALLOW_RACY_PATCH: u32 = 1 << 0;
pub const ZI_OBJC_ALLOW_KVO_CLASS_MISMATCH: u32 = 1 << 0;
pub const ZI_OBJC_ALLOW_DANGEROUS_SELECTOR: u32 = 1 << 1;

pub const zi_status_t = enum(c_int) {
    ZI_OK = 0,
    ZI_INVALID_ARGUMENT = 1,
    ZI_UNSUPPORTED_PLATFORM = 2,
    ZI_UNSUPPORTED_OPERATION = 3,
    ZI_UNSUPPORTED_INSTRUCTION = 4,
    ZI_NOT_FOUND = 5,
    ZI_OUT_OF_MEMORY = 6,
    ZI_ACCESS_DENIED = 7,
    ZI_GUARD_FAILED = 8,
    ZI_CONFLICT = 9,
    ZI_INTERNAL_ERROR = 10,
    ZI_BUFFER_TOO_SMALL = 11,
    ZI_REENTRANT_CALL = 12,
    ZI_SYMBOL_AMBIGUOUS = 13,
};

pub const zi_arch_t = enum(c_int) {
    ZI_ARCH_UNKNOWN = 0,
    ZI_ARCH_ARM64 = 1,
    ZI_ARCH_ARM64E = 2,
    ZI_ARCH_X86_64 = 3,
};

pub const zi_target_kind_t = enum(c_int) {
    ZI_TARGET_EXEC_SITE = 1,
    ZI_TARGET_DATA_SLOT = 2,
};

pub const zi_macho_offset_kind_t = enum(c_int) {
    ZI_MACHO_OFFSET_VMADDR = 0,
    ZI_MACHO_OFFSET_FILE = 1,
    ZI_MACHO_OFFSET_GLOBAL_FILE = 2,
};

pub const zi_return_kind_t = enum(c_int) {
    ZI_RETURN_KIND_UNKNOWN = 0,
    ZI_RETURN_KIND_VOID = 1,
    ZI_RETURN_KIND_INTEGER = 2,
    ZI_RETURN_KIND_POINTER = 3,
    ZI_RETURN_KIND_FLOAT = 4,
    ZI_RETURN_KIND_DOUBLE = 5,
    ZI_RETURN_KIND_SMALL_AGGREGATE = 6,
    ZI_RETURN_KIND_FLOAT_AGGREGATE = 7,
    ZI_RETURN_KIND_SRET = 8,
    ZI_RETURN_KIND_RAW_REGISTERS = 9,
};

pub const zi_entry_action_t = enum(c_int) {
    ZI_ENTRY_ACTION_CONTINUE = 0,
    ZI_ENTRY_ACTION_SKIP_ORIGINAL = 1,
    ZI_ENTRY_ACTION_DISABLE_HOOK = 2,
};

pub const zi_return_action_t = enum(c_int) {
    ZI_RETURN_ACTION_CONTINUE = 0,
    ZI_RETURN_ACTION_REPLACE_RETURN = 1,
    ZI_RETURN_ACTION_DISABLE_HOOK = 2,
};

pub const zi_swift_lookup_kind_t = enum(c_int) {
    ZI_SWIFT_LOOKUP_MANGLED_SYMBOL = 0,
    ZI_SWIFT_LOOKUP_DEMANGLED_SYMBOL = 1,
    ZI_SWIFT_LOOKUP_MODULE_TYPE_MEMBER = 2,
    ZI_SWIFT_LOOKUP_PROTOCOL_REQUIREMENT = 3,
    ZI_SWIFT_LOOKUP_METADATA_SLOT = 4,
    ZI_SWIFT_LOOKUP_WITNESS_SLOT = 5,
};

pub const zi_runtime_t = ?*anyopaque;
pub const zi_hook_t = ?*anyopaque;

pub const zi_bytes_t = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

pub const zi_guard_t = extern struct {
    expected: zi_bytes_t = .{},
    expected_sha256: zi_bytes_t = .{},
};

pub const zi_cstr_t = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

pub const zi_pattern_t = extern struct {
    bytes: zi_bytes_t = .{},
    mask: zi_bytes_t = .{},
};

pub const zi_return_value_t = extern struct {
    size: usize = @sizeOf(zi_return_value_t),
    kind: zi_return_kind_t = .ZI_RETURN_KIND_UNKNOWN,
    flags: u32 = 0,
    integer: [2]u64 = [_]u64{0} ** 2,
    fp: [2]f64 = [_]f64{0} ** 2,
    vector: [2][ZI_CONTEXT_VECTOR_REGISTER_BYTES]u8 = [_][ZI_CONTEXT_VECTOR_REGISTER_BYTES]u8{[_]u8{0} ** ZI_CONTEXT_VECTOR_REGISTER_BYTES} ** 2,
    pointer: ?*anyopaque = null,
    sret_pointer: ?*anyopaque = null,
    byte_count: usize = 0,
};

pub const zi_exec_site_t = extern struct {
    size: usize = @sizeOf(zi_exec_site_t),
    kind: zi_target_kind_t = .ZI_TARGET_EXEC_SITE,
    arch: zi_arch_t = .ZI_ARCH_UNKNOWN,
    address: ?*anyopaque = null,
    image_name: ?[*:0]const u8 = null,
    symbol_name: ?[*:0]const u8 = null,
    flags: u32 = 0,
};

pub const zi_data_slot_t = extern struct {
    size: usize = @sizeOf(zi_data_slot_t),
    kind: zi_target_kind_t = .ZI_TARGET_DATA_SLOT,
    address: ?*?*anyopaque = null,
    image_name: ?[*:0]const u8 = null,
    symbol_name: ?[*:0]const u8 = null,
    flags: u32 = 0,
};

pub const zi_entry_frame_t = extern struct {
    size: usize = @sizeOf(zi_entry_frame_t),
    arch: zi_arch_t = .ZI_ARCH_UNKNOWN,
    flags: u32 = 0,
    hook: zi_hook_t = null,
    site: zi_exec_site_t = .{},
    original: ?*anyopaque = null,
    replacement: ?*anyopaque = null,
    pc: ?*anyopaque = null,
    sp: ?*anyopaque = null,
    fp: ?*anyopaque = null,
    lr: ?*anyopaque = null,
    return_address: ?*anyopaque = null,
    integer_registers: [ZI_CONTEXT_INTEGER_REGISTER_COUNT]usize = [_]usize{0} ** ZI_CONTEXT_INTEGER_REGISTER_COUNT,
    vector_registers: [ZI_CONTEXT_VECTOR_REGISTER_COUNT][ZI_CONTEXT_VECTOR_REGISTER_BYTES]u8 = [_][ZI_CONTEXT_VECTOR_REGISTER_BYTES]u8{[_]u8{0} ** ZI_CONTEXT_VECTOR_REGISTER_BYTES} ** ZI_CONTEXT_VECTOR_REGISTER_COUNT,
    objc_self: ?*anyopaque = null,
    objc_cmd: ?*anyopaque = null,
    user_data: ?*anyopaque = null,
    thread_id: usize = 0,
    call_id: u64 = 0,
    return_value: zi_return_value_t = .{},
};

pub const zi_return_frame_t = extern struct {
    size: usize = @sizeOf(zi_return_frame_t),
    arch: zi_arch_t = .ZI_ARCH_UNKNOWN,
    flags: u32 = 0,
    hook: zi_hook_t = null,
    site: zi_exec_site_t = .{},
    original: ?*anyopaque = null,
    replacement: ?*anyopaque = null,
    pc: ?*anyopaque = null,
    sp: ?*anyopaque = null,
    fp: ?*anyopaque = null,
    lr: ?*anyopaque = null,
    return_address: ?*anyopaque = null,
    integer_registers: [ZI_CONTEXT_INTEGER_REGISTER_COUNT]usize = [_]usize{0} ** ZI_CONTEXT_INTEGER_REGISTER_COUNT,
    vector_registers: [ZI_CONTEXT_VECTOR_REGISTER_COUNT][ZI_CONTEXT_VECTOR_REGISTER_BYTES]u8 = [_][ZI_CONTEXT_VECTOR_REGISTER_BYTES]u8{[_]u8{0} ** ZI_CONTEXT_VECTOR_REGISTER_BYTES} ** ZI_CONTEXT_VECTOR_REGISTER_COUNT,
    objc_self: ?*anyopaque = null,
    objc_cmd: ?*anyopaque = null,
    user_data: ?*anyopaque = null,
    thread_id: usize = 0,
    call_id: u64 = 0,
    return_value: zi_return_value_t = .{},
};

pub const zi_entry_callback_fn = ?*const fn (*zi_entry_frame_t) callconv(.c) zi_entry_action_t;
pub const zi_return_callback_fn = ?*const fn (*zi_return_frame_t) callconv(.c) zi_return_action_t;

pub const zi_install_options_t = extern struct {
    size: usize = @sizeOf(zi_install_options_t),
    flags: u32 = 0,
    user_data: ?*anyopaque = null,
};

pub const zi_symbol_query_t = extern struct {
    size: usize = @sizeOf(zi_symbol_query_t),
    image_name: ?[*:0]const u8 = null,
    symbol_name: ?[*:0]const u8 = null,
    flags: u32 = 0,
};

pub const zi_image_offset_query_t = extern struct {
    size: usize = @sizeOf(zi_image_offset_query_t),
    image_name: ?[*:0]const u8 = null,
    offset: u64 = 0,
    kind: zi_macho_offset_kind_t = .ZI_MACHO_OFFSET_VMADDR,
    flags: u32 = 0,
};

pub const zi_pattern_bytes_query_t = extern struct {
    size: usize = @sizeOf(zi_pattern_bytes_query_t),
    image_name: ?[*:0]const u8 = null,
    segment_name: ?[*:0]const u8 = null,
    section_name: ?[*:0]const u8 = null,
    pattern: zi_pattern_t = .{},
    occurrence: usize = 0,
    result_offset: isize = 0,
    flags: u32 = 0,
};

pub const zi_pattern_text_query_t = extern struct {
    size: usize = @sizeOf(zi_pattern_text_query_t),
    image_name: ?[*:0]const u8 = null,
    segment_name: ?[*:0]const u8 = null,
    section_name: ?[*:0]const u8 = null,
    pattern_text: ?[*:0]const u8 = null,
    occurrence: usize = 0,
    result_offset: isize = 0,
    flags: u32 = 0,
};

pub const zi_objc_method_query_t = extern struct {
    size: usize = @sizeOf(zi_objc_method_query_t),
    class_name: ?[*:0]const u8 = null,
    selector_name: ?[*:0]const u8 = null,
    is_class_method: bool = false,
    flags: u32 = 0,
};

pub const zi_swift_slot_query_t = extern struct {
    size: usize = @sizeOf(zi_swift_slot_query_t),
    kind: zi_swift_lookup_kind_t = .ZI_SWIFT_LOOKUP_MANGLED_SYMBOL,
    image_name: ?[*:0]const u8 = null,
    module_name: ?[*:0]const u8 = null,
    type_name: ?[*:0]const u8 = null,
    member_name: ?[*:0]const u8 = null,
    protocol_name: ?[*:0]const u8 = null,
    requirement_name: ?[*:0]const u8 = null,
    mangled_name: ?[*:0]const u8 = null,
    demangled_name: ?[*:0]const u8 = null,
    metadata: ?*anyopaque = null,
    witness_table: ?*anyopaque = null,
    slot_index: usize = 0,
    entry_count: usize = 0,
    flags: u32 = 0,
};

pub const zi_patch_bytes_spec_t = extern struct {
    size: usize = @sizeOf(zi_patch_bytes_spec_t),
    site: zi_exec_site_t = .{},
    replacement: zi_bytes_t = .{},
    guard: zi_guard_t = .{},
    options: zi_install_options_t = .{},
};

pub const zi_replace_site_spec_t = extern struct {
    size: usize = @sizeOf(zi_replace_site_spec_t),
    site: zi_exec_site_t = .{},
    replacement: ?*anyopaque = null,
    original_out: ?*?*anyopaque = null,
    options: zi_install_options_t = .{},
};

pub const zi_instrument_site_spec_t = extern struct {
    size: usize = @sizeOf(zi_instrument_site_spec_t),
    site: zi_exec_site_t = .{},
    entry_callback: zi_entry_callback_fn = null,
    return_callback: zi_return_callback_fn = null,
    expected_return_kind: zi_return_kind_t = .ZI_RETURN_KIND_UNKNOWN,
    expected_return_size: usize = 0,
    options: zi_install_options_t = .{},
};

pub const zi_replace_slot_spec_t = extern struct {
    size: usize = @sizeOf(zi_replace_slot_spec_t),
    slot: zi_data_slot_t = .{},
    replacement: ?*anyopaque = null,
    original_out: ?*?*anyopaque = null,
    options: zi_install_options_t = .{},
};

pub const zi_objc_object_replace_spec_t = extern struct {
    size: usize = @sizeOf(zi_objc_object_replace_spec_t),
    object: ?*anyopaque = null,
    selector_name: ?[*:0]const u8 = null,
    replacement: ?*anyopaque = null,
    original_out: ?*?*anyopaque = null,
    flags: u32 = 0,
    options: zi_install_options_t = .{},
};

pub const zi_debug_file_line_t = extern struct {
    size: usize = @sizeOf(zi_debug_file_line_t),
    address: ?*anyopaque = null,
    file_buffer: ?[*]u8 = null,
    file_buffer_len: usize = 0,
    function_buffer: ?[*]u8 = null,
    function_buffer_len: usize = 0,
    line_out: ?*u32 = null,
    column_out: ?*u32 = null,
    image_uuid_out: ?[*]u8 = null,
    image_uuid_len: usize = 0,
    required_file_len_out: ?*usize = null,
    required_function_len_out: ?*usize = null,
    flags: u32 = 0,
};

pub fn zi_status_name(status: zi_status_t) [*:0]const u8 {
    _ = status;
    return "";
}

pub fn zi_runtime_open(out_runtime: ?*zi_runtime_t) zi_status_t {
    _ = out_runtime;
    return .ZI_OK;
}

pub fn zi_runtime_close(rt: zi_runtime_t) zi_status_t {
    _ = rt;
    return .ZI_OK;
}

pub fn zi_runtime_reset(rt: zi_runtime_t) zi_status_t {
    _ = rt;
    return .ZI_OK;
}

pub fn zi_hook_enable(hook: zi_hook_t) zi_status_t {
    _ = hook;
    return .ZI_OK;
}

pub fn zi_hook_disable(hook: zi_hook_t) zi_status_t {
    _ = hook;
    return .ZI_OK;
}

pub fn zi_hook_remove(hook: zi_hook_t) zi_status_t {
    _ = hook;
    return .ZI_OK;
}

pub fn zi_resolve_symbol(rt: zi_runtime_t, query: ?*const zi_symbol_query_t, out_site: ?*zi_exec_site_t) zi_status_t {
    _ = rt;
    _ = query;
    _ = out_site;
    return .ZI_OK;
}

pub fn zi_resolve_image_offset(rt: zi_runtime_t, query: ?*const zi_image_offset_query_t, out_site: ?*zi_exec_site_t) zi_status_t {
    _ = rt;
    _ = query;
    _ = out_site;
    return .ZI_OK;
}

pub fn zi_resolve_pattern_bytes(rt: zi_runtime_t, query: ?*const zi_pattern_bytes_query_t, out_site: ?*zi_exec_site_t) zi_status_t {
    _ = rt;
    _ = query;
    _ = out_site;
    return .ZI_OK;
}

pub fn zi_resolve_pattern_text(rt: zi_runtime_t, query: ?*const zi_pattern_text_query_t, out_site: ?*zi_exec_site_t) zi_status_t {
    _ = rt;
    _ = query;
    _ = out_site;
    return .ZI_OK;
}

pub fn zi_resolve_objc_method(rt: zi_runtime_t, query: ?*const zi_objc_method_query_t, out_site: ?*zi_exec_site_t) zi_status_t {
    _ = rt;
    _ = query;
    _ = out_site;
    return .ZI_OK;
}

pub fn zi_resolve_swift_slot(rt: zi_runtime_t, query: ?*const zi_swift_slot_query_t, out_slot: ?*zi_data_slot_t) zi_status_t {
    _ = rt;
    _ = query;
    _ = out_slot;
    return .ZI_OK;
}

pub fn zi_install_patch_bytes(rt: zi_runtime_t, spec: ?*const zi_patch_bytes_spec_t, out_hook: ?*zi_hook_t) zi_status_t {
    _ = rt;
    _ = spec;
    _ = out_hook;
    return .ZI_OK;
}

pub fn zi_install_replace_site(rt: zi_runtime_t, spec: ?*const zi_replace_site_spec_t, out_hook: ?*zi_hook_t) zi_status_t {
    _ = rt;
    _ = spec;
    _ = out_hook;
    return .ZI_OK;
}

pub fn zi_install_instrument_site(rt: zi_runtime_t, spec: ?*const zi_instrument_site_spec_t, out_hook: ?*zi_hook_t) zi_status_t {
    _ = rt;
    _ = spec;
    _ = out_hook;
    return .ZI_OK;
}

pub fn zi_install_replace_slot(rt: zi_runtime_t, spec: ?*const zi_replace_slot_spec_t, out_hook: ?*zi_hook_t) zi_status_t {
    _ = rt;
    _ = spec;
    _ = out_hook;
    return .ZI_OK;
}

pub fn zi_install_objc_object_replace(rt: zi_runtime_t, spec: ?*const zi_objc_object_replace_spec_t, out_hook: ?*zi_hook_t) zi_status_t {
    _ = rt;
    _ = spec;
    _ = out_hook;
    return .ZI_OK;
}

pub fn zi_debug_lookup_file_line(rt: zi_runtime_t, request: ?*zi_debug_file_line_t) zi_status_t {
    _ = rt;
    _ = request;
    return .ZI_OK;
}
