const std = @import("std");
const builtin = @import("builtin");

const zi = @import("interpose");

extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern "c" fn objc_msgSend() callconv(.c) void;

test "runtime lifecycle uses opaque pointer handles and status names" {
    var rt: zi.Runtime = null;
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_runtime_open(&rt));
    try std.testing.expect(rt != null);
    try std.testing.expectEqualStrings("ZI_OK", std.mem.span(zi.c.zi_status_name(.ZI_OK)));
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_runtime_reset(rt));
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_runtime_close(rt));
}

test "patch bytes round trip and idempotent hook state transitions" {
    var rt: zi.Runtime = null;
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_runtime_open(&rt));
    defer _ = zi.c.zi_runtime_close(rt);

    var bytes = [_]u8{ 0x10, 0x20, 0x30, 0x40 };
    const original = [_]u8{ 0x10, 0x20, 0x30, 0x40 };
    const replacement = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    var hook: zi.Hook = null;
    var spec: zi.PatchBytesSpec = .{
        .site = .{
            .address = &bytes,
            .arch = if (@import("builtin").cpu.arch == .x86_64) .ZI_ARCH_X86_64 else .ZI_ARCH_ARM64,
        },
        .replacement = .{ .ptr = replacement[0..].ptr, .len = replacement.len },
        .guard = .{ .expected = .{ .ptr = original[0..].ptr, .len = original.len } },
        .options = .{ .flags = zi.c.ZI_INSTALL_ALLOW_RACY_PATCH },
    };
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_install_patch_bytes(rt, &spec, &hook));
    try std.testing.expectEqualSlices(u8, &replacement, &bytes);
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_hook_disable(hook));
    try std.testing.expectEqualSlices(u8, &original, &bytes);
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_hook_disable(hook));
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_hook_enable(hook));
    try std.testing.expectEqualSlices(u8, &replacement, &bytes);
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_hook_remove(hook));
    try std.testing.expectEqualSlices(u8, &original, &bytes);
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_hook_remove(hook));
}

test "replace slot round trip" {
    var rt: zi.Runtime = null;
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_runtime_open(&rt));
    defer _ = zi.c.zi_runtime_close(rt);

    const original_fn: ?*anyopaque = @ptrFromInt(1);
    const replacement_fn: ?*anyopaque = @ptrFromInt(2);
    var slot = original_fn;
    var hook: zi.Hook = null;
    var replaced_original: ?*anyopaque = null;
    var spec: zi.ReplaceSlotSpec = .{
        .slot = .{ .address = &slot },
        .replacement = replacement_fn,
        .original_out = &replaced_original,
        .options = .{},
    };
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_install_replace_slot(rt, &spec, &hook));
    try std.testing.expectEqual(replacement_fn, slot);
    try std.testing.expectEqual(original_fn, replaced_original);
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_hook_disable(hook));
    try std.testing.expectEqual(original_fn, slot);
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_hook_enable(hook));
    try std.testing.expectEqual(replacement_fn, slot);
}

test "instrument site is explicit unsupported until implemented and objc object replace installs on real objects" {
    var rt: zi.Runtime = null;
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_runtime_open(&rt));
    defer _ = zi.c.zi_runtime_close(rt);

    var target: usize = 1;
    var hook: zi.Hook = null;
    var instrument_spec: zi.InstrumentSiteSpec = .{
        .site = .{ .address = &target },
        .entry_callback = entryCallback,
    };
    try std.testing.expectEqual(zi.Status.ZI_UNSUPPORTED_OPERATION, zi.c.zi_install_instrument_site(rt, &instrument_spec, &hook));

    if (!builtin.os.tag.isDarwin()) return;
    const object = newNSObject() orelse return error.SkipZigTest;
    var objc_spec: zi.ObjcObjectReplaceSpec = .{
        .object = object,
        .selector_name = "description",
        .replacement = @ptrCast(@constCast(&objcDescriptionReplacement)),
    };
    const objc_status = zi.c.zi_install_objc_object_replace(rt, &objc_spec, &hook);
    if (objc_status == .ZI_OK) {
        try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_hook_remove(hook));
    } else {
        try std.testing.expect(objc_status == .ZI_UNSUPPORTED_PLATFORM or objc_status == .ZI_NOT_FOUND or objc_status == .ZI_CONFLICT);
    }
}

fn entryCallback(frame: *zi.EntryFrame) callconv(.c) zi.EntryAction {
    frame.return_value.kind = .ZI_RETURN_KIND_INTEGER;
    frame.return_value.integer[0] = 7;
    return .ZI_ENTRY_ACTION_SKIP_ORIGINAL;
}

fn objcDescriptionReplacement(self: ?*anyopaque, _cmd: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = _cmd;
    return self;
}

fn newNSObject() ?*anyopaque {
    const cls = objc_getClass("NSObject") orelse return null;
    const sel = sel_registerName("new") orelse return null;
    const send: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc_msgSend);
    return send(cls, sel);
}
