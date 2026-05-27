const std = @import("std");

const zi = @import("interpose");
const builtin = @import("builtin");

extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern "c" fn objc_msgSend() callconv(.c) void;

pub export fn resolverAnchor() callconv(.c) void {}

test "symbol and debug lookup resolve current image addresses" {
    var rt: zi.Runtime = null;
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_runtime_open(&rt));
    defer _ = zi.c.zi_runtime_close(rt);

    var site: zi.ExecSite = undefined;
    var query: zi.SymbolQuery = .{ .symbol_name = "resolverAnchor" };
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_resolve_symbol(rt, &query, &site));
    try std.testing.expect(site.address != null);

    var file_buf: [512]u8 = undefined;
    var fn_buf: [256]u8 = undefined;
    var file_len: usize = 0;
    var fn_len: usize = 0;
    var request: zi.DebugFileLine = .{
        .address = site.address,
        .file_buffer = &file_buf,
        .file_buffer_len = file_buf.len,
        .function_buffer = &fn_buf,
        .function_buffer_len = fn_buf.len,
        .required_file_len_out = &file_len,
        .required_function_len_out = &fn_len,
    };
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_debug_lookup_file_line(rt, &request));
    try std.testing.expect(file_len > 0);
    try std.testing.expect(fn_len > 0);
}

test "objc method resolution returns executable site on darwin" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;

    var rt: zi.Runtime = null;
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_runtime_open(&rt));
    defer _ = zi.c.zi_runtime_close(rt);

    var site: zi.ExecSite = undefined;
    var query: zi.ObjcMethodQuery = .{
        .class_name = "NSObject",
        .selector_name = "description",
    };
    const status = zi.c.zi_resolve_objc_method(rt, &query, &site);
    if (objc_getClass("NSObject") == null or sel_registerName("description") == null) return error.SkipZigTest;
    try std.testing.expectEqual(zi.Status.ZI_OK, status);
    try std.testing.expect(site.address != null);
    _ = objc_msgSend;
}

test "swift slot resolution rejects invalid empty query" {
    var rt: zi.Runtime = null;
    try std.testing.expectEqual(zi.Status.ZI_OK, zi.c.zi_runtime_open(&rt));
    defer _ = zi.c.zi_runtime_close(rt);

    var slot: zi.DataSlot = undefined;
    var query: zi.SwiftSlotQuery = .{};
    try std.testing.expectEqual(zi.Status.ZI_INVALID_ARGUMENT, zi.c.zi_resolve_swift_slot(rt, &query, &slot));
}
