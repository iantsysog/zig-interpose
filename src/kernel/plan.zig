const abi = @import("../abi/types.zig");

pub const Kind = enum {
    patch_bytes,
    replace_site,
    replace_slot,
    objc_object_replace,
};

pub const PatchBytesPlan = struct {
    site: abi.zi_exec_site_t,
    replacement: []const u8,
    expected: ?[]const u8,
    racy: bool,
};

pub const ReplaceSitePlan = struct {
    site: abi.zi_exec_site_t,
    replacement: ?*anyopaque,
    original_out: ?*?*anyopaque,
    racy: bool,
};

pub const ReplaceSlotPlan = struct {
    slot: abi.zi_data_slot_t,
    replacement: ?*anyopaque,
    original_out: ?*?*anyopaque,
};

pub const ObjcObjectReplacePlan = struct {
    object: ?*anyopaque,
    selector_name: ?[*:0]const u8,
    replacement: ?*anyopaque,
    original_out: ?*?*anyopaque,
    flags: u32,
    options: abi.zi_install_options_t,
};

pub const OperationPlan = union(Kind) {
    patch_bytes: PatchBytesPlan,
    replace_site: ReplaceSitePlan,
    replace_slot: ReplaceSlotPlan,
    objc_object_replace: ObjcObjectReplacePlan,
};
