const std = @import("std");
const builtin = @import("builtin");

const c = @import("../api.zig");
const images = @import("../macho/images.zig");
const memory = @import("../platform/darwin/memory.zig");

pub const Error = error{
    UnsupportedPlatform,
    UnsupportedOperation,
    InvalidArgument,
    NotFound,
    AccessDenied,
    GuardFailed,
    Conflict,
    Ambiguous,
};

pub const SlotPatch = struct {
    slot: *?*anyopaque,
    original: ?*anyopaque,
    replacement: ?*anyopaque,
};

const ClassMetadata = extern struct {
    kind: usize,
    superclass: ?*anyopaque,
    cache_data_0: usize,
    cache_data_1: usize,
    data: usize,
    flags: u32,
    instance_address_point: u32,
    instance_size: u32,
    instance_align_mask: u16,
    reserved: u16,
    class_size: u32,
    class_address_point: u32,
    description: ?*anyopaque,
    ivar_destroyer: ?*anyopaque,
};

const ClassDescriptorPrefix = extern struct {
    flags: u32,
    parent: i32,
    name: i32,
    access_function: i32,
    fields: i32,
    superclass_type: i32,
    metadata_negative_size_in_words: u32,
    metadata_positive_size_in_words: u32,
    num_immediate_members: u32,
    num_fields: u32,
    field_offset_vector_offset: u32,
};

const VTableHeader = extern struct {
    offset: u32,
    size: u32,
};

pub fn lookupSlot(query: *const c.zi_swift_slot_query_t) Error!*?*anyopaque {
    if (query.flags != 0) return error.UnsupportedOperation;
    return switch (query.kind) {
        .ZI_SWIFT_LOOKUP_MANGLED_SYMBOL => lookupMangledSlot(query),
        .ZI_SWIFT_LOOKUP_DEMANGLED_SYMBOL => lookupDemangledSlot(query),
        .ZI_SWIFT_LOOKUP_MODULE_TYPE_MEMBER => lookupModuleTypeMember(query),
        .ZI_SWIFT_LOOKUP_PROTOCOL_REQUIREMENT => lookupProtocolRequirement(query),
        .ZI_SWIFT_LOOKUP_METADATA_SLOT => resolveVTableSlot(query.metadata, query.slot_index),
        .ZI_SWIFT_LOOKUP_WITNESS_SLOT => resolveWitnessSlot(query.witness_table, query.slot_index, query.entry_count),
    };
}

pub fn replaceSlot(slot: *?*anyopaque, replacement: ?*anyopaque) Error!SlotPatch {
    if (replacement == null) return error.InvalidArgument;
    const patch: SlotPatch = .{ .slot = slot, .original = slot.*, .replacement = replacement };
    try applySlot(patch);
    return patch;
}

pub fn resolveVTableSlot(metadata_ptr: ?*anyopaque, slot_index: usize) Error!*?*anyopaque {
    if (!isDarwin()) return error.UnsupportedPlatform;
    const metadata_opaque = metadata_ptr orelse return error.InvalidArgument;
    const metadata: *const ClassMetadata = @ptrCast(@alignCast(metadata_opaque));
    const descriptor = classDescriptor(metadata) orelse return error.InvalidArgument;
    const vtable_header = vtableHeader(descriptor);
    if (vtable_header.size == 0) return error.InvalidArgument;
    if (slot_index >= vtable_header.size) return error.InvalidArgument;
    const words: [*]?*anyopaque = @ptrCast(@constCast(metadata));
    return &words[(try vtableOffset(metadata, descriptor, vtable_header)) + slot_index];
}

pub fn resolveWitnessSlot(witness_table_ptr: ?*anyopaque, entry_index: usize, entry_count: usize) Error!*?*anyopaque {
    if (!isDarwin()) return error.UnsupportedPlatform;
    const witness_table = witness_table_ptr orelse return error.InvalidArgument;
    if (entry_count != 0 and entry_index >= entry_count) return error.InvalidArgument;
    const words: [*]?*anyopaque = @ptrCast(@alignCast(witness_table));
    return &words[1 + entry_index];
}

pub fn isMangledSymbol(symbol: []const u8) bool {
    return std.mem.startsWith(u8, symbol, "$s") or
        std.mem.startsWith(u8, symbol, "$S") or
        std.mem.startsWith(u8, symbol, "_T") or
        std.mem.startsWith(u8, symbol, "_Tt");
}

pub fn applySlot(patch: SlotPatch) Error!void {
    try writePointer(patch.slot, patch.replacement, patch.original);
}

pub fn restoreSlot(patch: SlotPatch) Error!void {
    try writePointer(patch.slot, patch.original, patch.replacement);
}

fn lookupMangledSlot(query: *const c.zi_swift_slot_query_t) Error!*?*anyopaque {
    if (!isDarwin()) return error.UnsupportedPlatform;
    const mangled_z = query.mangled_name orelse return error.InvalidArgument;
    const mangled = std.mem.span(mangled_z);
    if (!isMangledSymbol(mangled)) return error.InvalidArgument;
    const image = if (query.image_name) |image_z| std.mem.span(image_z) else null;
    const address = images.resolveSymbol(image, mangled) catch |err| return mapImageError(err);
    return @ptrFromInt(address);
}

fn lookupDemangledSlot(query: *const c.zi_swift_slot_query_t) Error!*?*anyopaque {
    if (!isDarwin()) return error.UnsupportedPlatform;
    _ = query.demangled_name orelse return error.InvalidArgument;
    // Demangled lookup requires a Swift image cache and swift_demangle pass.
    return error.NotFound;
}

fn lookupModuleTypeMember(query: *const c.zi_swift_slot_query_t) Error!*?*anyopaque {
    if (query.module_name == null or query.type_name == null or query.member_name == null) return error.InvalidArgument;
    return error.NotFound;
}

fn lookupProtocolRequirement(query: *const c.zi_swift_slot_query_t) Error!*?*anyopaque {
    if (query.protocol_name == null or query.requirement_name == null) return error.InvalidArgument;
    if (query.witness_table) |_| return resolveWitnessSlot(query.witness_table, query.slot_index, query.entry_count);
    return error.NotFound;
}

fn writePointer(slot: *?*anyopaque, replacement: ?*anyopaque, expected: ?*anyopaque) Error!void {
    memory.writePointer(slot, replacement, expected) catch |err| return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.InvalidArgument => error.InvalidArgument,
        error.OutOfMemory => error.AccessDenied,
        error.AccessDenied => error.AccessDenied,
        error.GuardFailed => error.GuardFailed,
        error.Conflict => error.Conflict,
        error.UnsupportedOperation => error.Conflict,
    };
}

fn classDescriptor(metadata: *const ClassMetadata) ?*const ClassDescriptorPrefix {
    const data = metadata.data & ~@as(usize, 0x7);
    if (data == 0) return null;
    return @ptrFromInt(data);
}

fn vtableHeader(descriptor: *const ClassDescriptorPrefix) *const VTableHeader {
    const after_prefix = @intFromPtr(descriptor) + @sizeOf(ClassDescriptorPrefix);
    return @ptrFromInt(after_prefix + descriptor.num_immediate_members * @sizeOf(usize));
}

fn vtableOffset(metadata: *const ClassMetadata, descriptor: *const ClassDescriptorPrefix, header: *const VTableHeader) Error!usize {
    if (!hasResilientSuperclass(descriptor)) return header.offset;
    const superclass: *const ClassMetadata = @ptrCast(@alignCast(metadata.superclass orelse return error.InvalidArgument));
    return try superclassSizeInWords(superclass) + header.offset;
}

fn hasResilientSuperclass(descriptor: *const ClassDescriptorPrefix) bool {
    const kind_specific_flags = descriptor.flags >> 16;
    return (kind_specific_flags & (1 << 13)) != 0;
}

fn superclassSizeInWords(superclass: *const ClassMetadata) Error!usize {
    if (superclass.class_size < superclass.class_address_point) return error.InvalidArgument;
    const size = superclass.class_size - superclass.class_address_point;
    if (size % @sizeOf(usize) != 0) return error.InvalidArgument;
    return size / @sizeOf(usize);
}

fn mapImageError(err: images.Error) Error {
    return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.InvalidArgument => error.InvalidArgument,
        error.InvalidMachO => error.NotFound,
        error.OutOfMemory => error.AccessDenied,
        error.NotFound => error.NotFound,
        error.Ambiguous => error.Ambiguous,
    };
}

fn isDarwin() bool {
    return comptime builtin.os.tag.isDarwin();
}

test "Swift mangled symbol prefixes" {
    try std.testing.expect(isMangledSymbol("$s4Demo3fooyyF"));
    try std.testing.expect(isMangledSymbol("_TtC4Demo3Foo"));
    try std.testing.expect(!isMangledSymbol("Demo.foo()"));
}

test "vtable slot resolver uses descriptor header offset" {
    const Descriptor = extern struct {
        prefix: ClassDescriptorPrefix,
        vtable: VTableHeader,
    };
    var descriptor align(8) = Descriptor{
        .prefix = .{
            .flags = 0,
            .parent = 0,
            .name = 0,
            .access_function = 0,
            .fields = 0,
            .superclass_type = 0,
            .metadata_negative_size_in_words = 0,
            .metadata_positive_size_in_words = 0,
            .num_immediate_members = 0,
            .num_fields = 0,
            .field_offset_vector_offset = 0,
        },
        .vtable = .{ .offset = 5, .size = 2 },
    };
    var metadata_words = [_]?*anyopaque{null} ** 8;
    metadata_words[4] = @ptrFromInt(@intFromPtr(&descriptor.prefix));
    const slot = try resolveVTableSlot(&metadata_words, 1);
    try std.testing.expectEqual(&metadata_words[6], slot);
    try std.testing.expectError(error.InvalidArgument, resolveVTableSlot(&metadata_words, 2));
}

test "vtable slot resolver handles resilient superclass offset" {
    const Descriptor = extern struct {
        prefix: ClassDescriptorPrefix,
        vtable: VTableHeader,
    };
    var descriptor align(8) = Descriptor{
        .prefix = .{
            .flags = (1 << 13) << 16,
            .parent = 0,
            .name = 0,
            .access_function = 0,
            .fields = 0,
            .superclass_type = 0,
            .metadata_negative_size_in_words = 0,
            .metadata_positive_size_in_words = 0,
            .num_immediate_members = 0,
            .num_fields = 0,
            .field_offset_vector_offset = 0,
        },
        .vtable = .{ .offset = 2, .size = 2 },
    };
    var superclass: ClassMetadata = .{
        .kind = 0,
        .superclass = null,
        .cache_data_0 = 0,
        .cache_data_1 = 0,
        .data = 0,
        .flags = 0,
        .instance_address_point = 0,
        .instance_size = 0,
        .instance_align_mask = 0,
        .reserved = 0,
        .class_size = 32,
        .class_address_point = 0,
        .description = null,
        .ivar_destroyer = null,
    };
    var metadata_words = [_]?*anyopaque{null} ** 8;
    metadata_words[1] = &superclass;
    metadata_words[4] = @ptrFromInt(@intFromPtr(&descriptor.prefix));
    const slot = try resolveVTableSlot(&metadata_words, 1);
    try std.testing.expectEqual(&metadata_words[7], slot);
}

test "witness slot resolver skips conformance descriptor" {
    var witness_table = [_]?*anyopaque{ null, @ptrFromInt(1), @ptrFromInt(2) };
    const slot = try resolveWitnessSlot(&witness_table, 1, 2);
    try std.testing.expectEqual(&witness_table[2], slot);
    try std.testing.expectError(error.InvalidArgument, resolveWitnessSlot(&witness_table, 2, 2));
}
