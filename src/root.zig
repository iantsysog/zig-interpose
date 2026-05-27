const std = @import("std");

pub const c = @import("api.zig");
pub const abi = @import("abi/types.zig");
pub const api = @import("api/mod.zig");
pub const kernel = @import("kernel/mod.zig");
pub const platform = @import("platform/mod.zig");
pub const arch = @import("arch/mod.zig");
pub const lang = @import("lang/mod.zig");
pub const image = @import("macho/images.zig");
pub const memory = @import("platform/darwin/memory.zig");

pub const Status = c.zi_status_t;
pub const Arch = c.zi_arch_t;
pub const TargetKind = c.zi_target_kind_t;
pub const ReturnKind = c.zi_return_kind_t;
pub const EntryAction = c.zi_entry_action_t;
pub const ReturnAction = c.zi_return_action_t;
pub const SwiftLookupKind = c.zi_swift_lookup_kind_t;
pub const Runtime = c.zi_runtime_t;
pub const Hook = c.zi_hook_t;
pub const Bytes = c.zi_bytes_t;
pub const Guard = c.zi_guard_t;
pub const CStr = c.zi_cstr_t;
pub const MachOOffsetKind = c.zi_macho_offset_kind_t;
pub const Pattern = c.zi_pattern_t;
pub const ReturnValue = c.zi_return_value_t;
pub const ExecSite = c.zi_exec_site_t;
pub const DataSlot = c.zi_data_slot_t;
pub const EntryFrame = c.zi_entry_frame_t;
pub const ReturnFrame = c.zi_return_frame_t;
pub const InstallOptions = c.zi_install_options_t;
pub const SymbolQuery = c.zi_symbol_query_t;
pub const ImageOffsetQuery = c.zi_image_offset_query_t;
pub const PatternBytesQuery = c.zi_pattern_bytes_query_t;
pub const PatternTextQuery = c.zi_pattern_text_query_t;
pub const ObjcMethodQuery = c.zi_objc_method_query_t;
pub const SwiftSlotQuery = c.zi_swift_slot_query_t;
pub const PatchBytesSpec = c.zi_patch_bytes_spec_t;
pub const ReplaceSiteSpec = c.zi_replace_site_spec_t;
pub const InstrumentSiteSpec = c.zi_instrument_site_spec_t;
pub const ReplaceSlotSpec = c.zi_replace_slot_spec_t;
pub const ObjcObjectReplaceSpec = c.zi_objc_object_replace_spec_t;
pub const DebugFileLine = c.zi_debug_file_line_t;

pub fn openRuntime() ?Runtime {
    var runtime: Runtime = null;
    if (c.zi_runtime_open(&runtime) != .ZI_OK) return null;
    return runtime;
}

test {
    std.testing.refAllDecls(@This());
}
