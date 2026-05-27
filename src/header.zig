const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const HeaderError = error{
    UnsupportedAbiDeclaration,
    UnsupportedType,
    UnsupportedExpression,
    UnsupportedFunction,
    OutOfMemory,
};

// https://github.com/ziglang/zig/issues/9698#issuecomment-3067093430

pub fn generate(allocator: Allocator, source: [:0]const u8) ![]const u8 {
    var ast = try Ast.parse(allocator, source, .zig);
    defer ast.deinit(allocator);

    var ctx = Context{
        .allocator = allocator,
        .ast = &ast,
        .out = .empty,
    };
    errdefer ctx.out.deinit(allocator);

    try ctx.out.appendSlice(allocator,
        \\#ifndef ZIG_INTERPOSE_H
        \\#define ZIG_INTERPOSE_H
        \\
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
        \\#if defined(_WIN32)
        \\#define ZI_EXPORT __declspec(dllexport)
        \\#else
        \\#define ZI_EXPORT __attribute__((visibility("default")))
        \\#endif
        \\
        \\
    );

    const root_decls = ast.rootDecls();
    for (root_decls) |decl| {
        try ctx.emitDecl(decl, .types);
    }
    for (root_decls) |decl| {
        try ctx.emitDecl(decl, .exports);
    }

    try ctx.out.appendSlice(allocator,
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif
        \\
    );

    return try ctx.out.toOwnedSlice(allocator);
}

const Pass = enum {
    types,
    exports,
};

const Context = struct {
    allocator: Allocator,
    ast: *Ast,
    out: std.ArrayList(u8),

    fn emitDecl(ctx: *Context, decl: Ast.Node.Index, pass: Pass) HeaderError!void {
        if (!ctx.isPub(decl)) return;
        const tag = ctx.nodeTag(decl);
        switch (tag) {
            .simple_var_decl => {
                if (pass == .types) try ctx.emitConstDecl(decl);
            },
            .fn_decl, .global_var_decl => {
                if (pass == .exports) try ctx.emitFunctionDecl(decl);
            },
            .test_decl => {},
            else => return error.UnsupportedAbiDeclaration,
        }
    }

    fn emitConstDecl(ctx: *Context, decl: Ast.Node.Index) HeaderError!void {
        const var_decl = ctx.ast.simpleVarDecl(decl);
        const name = ctx.tokenSlice(var_decl.ast.mut_token + 1);
        const type_node = var_decl.ast.type_node.unwrap();
        const init_node = var_decl.ast.init_node.unwrap() orelse return error.UnsupportedAbiDeclaration;

        if (type_node) |typed| {
            const type_source = ctx.nodeSource(typed);
            if (std.mem.eql(u8, type_source, "usize") or std.mem.eql(u8, type_source, "u32")) {
                const value = try ctx.translateExpr(init_node);
                try ctx.out.print(ctx.allocator, "#define {s} {s}\n", .{ name, value });
                return;
            }
            if (std.mem.eql(u8, type_source, "zi_runtime_t") or std.mem.eql(u8, type_source, "zi_hook_t")) {
                const value = try ctx.translateExpr(init_node);
                try ctx.out.print(ctx.allocator, "#define {s} {s}\n", .{ name, value });
                return;
            }
            return error.UnsupportedAbiDeclaration;
        }

        switch (ctx.nodeTag(init_node)) {
            .container_decl_arg, .container_decl_arg_trailing => try ctx.emitEnum(name, init_node),
            .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing => try ctx.emitExternStruct(name, init_node),
            .identifier => try ctx.emitAlias(name, init_node),
            .fn_proto_simple, .fn_proto_multi, .fn_proto_one => try ctx.emitCallbackTypedef(name, init_node),
            .optional_type => {
                const type_source = ctx.nodeSource(init_node);
                if (std.mem.startsWith(u8, type_source, "?*const fn (")) {
                    try ctx.emitCallbackTypedefFromType(name, type_source);
                } else {
                    try ctx.emitAliasFromSource(name, type_source);
                }
            },
            else => return error.UnsupportedAbiDeclaration,
        }
    }

    fn emitAlias(ctx: *Context, name: []const u8, init_node: Ast.Node.Index) HeaderError!void {
        try ctx.emitAliasFromSource(name, ctx.nodeSource(init_node));
    }

    fn emitAliasFromSource(ctx: *Context, name: []const u8, target: []const u8) HeaderError!void {
        const c_type = try ctx.translateType(target, .value);
        try ctx.out.print(ctx.allocator, "typedef {s} {s};\n\n", .{ c_type.base, name });
    }

    fn emitEnum(ctx: *Context, name: []const u8, node: Ast.Node.Index) HeaderError!void {
        var buffer: [2]Ast.Node.Index = undefined;
        const decl = ctx.ast.fullContainerDecl(&buffer, node) orelse return error.UnsupportedAbiDeclaration;
        if (!std.mem.eql(u8, ctx.tokenSlice(decl.ast.main_token), "enum")) return error.UnsupportedAbiDeclaration;
        if (!std.mem.startsWith(u8, std.mem.trim(u8, ctx.nodeSource(node), " \n\r\t"), "enum(c_int)")) return error.UnsupportedAbiDeclaration;
        try ctx.out.print(ctx.allocator, "typedef enum {s} {{\n", .{name});
        for (decl.ast.members) |member| {
            if (ctx.nodeTag(member) != .container_field_init) return error.UnsupportedAbiDeclaration;
            const main_token = ctx.nodeMainToken(member);
            const field_name = ctx.tokenSlice(main_token);
            const value_node = ctx.nodeData(member).node_and_opt_node[1].unwrap() orelse return error.UnsupportedAbiDeclaration;
            const value = try ctx.translateExpr(value_node);
            try ctx.out.print(ctx.allocator, "    {s} = {s},\n", .{ field_name, value });
        }
        try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{name});
    }

    fn emitExternStruct(ctx: *Context, name: []const u8, node: Ast.Node.Index) HeaderError!void {
        var buffer: [2]Ast.Node.Index = undefined;
        const decl = ctx.ast.fullContainerDecl(&buffer, node) orelse return error.UnsupportedAbiDeclaration;
        if (!std.mem.startsWith(u8, std.mem.trim(u8, ctx.nodeSource(node), " \n\r\t"), "extern struct")) return error.UnsupportedAbiDeclaration;
        try ctx.out.print(ctx.allocator, "typedef struct {s} {{\n", .{name});
        for (decl.ast.members) |member| {
            if (ctx.nodeTag(member) != .container_field_init) return error.UnsupportedAbiDeclaration;
            const field_name = ctx.tokenSlice(ctx.nodeMainToken(member));
            const type_node = ctx.nodeData(member).node_and_opt_node[0];
            const type_source = ctx.nodeSource(type_node);
            const c_type = try ctx.translateType(type_source, .field);
            try ctx.emitField(c_type, field_name);
        }
        try ctx.out.print(ctx.allocator, "}} {s};\n\n", .{name});
    }

    fn emitCallbackTypedef(ctx: *Context, name: []const u8, node: Ast.Node.Index) HeaderError!void {
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = ctx.ast.fullFnProto(&buffer, node) orelse return error.UnsupportedFunction;
        if (proto.ast.callconv_expr.unwrap() == null) return error.UnsupportedFunction;
        const return_node = proto.ast.return_type.unwrap() orelse return error.UnsupportedFunction;
        const return_type = try ctx.translateType(ctx.nodeSource(return_node), .value);
        try ctx.out.print(ctx.allocator, "typedef {s} (*{s})(", .{ return_type.base, name });
        var it = proto.iterate(ctx.ast);
        var first = true;
        while (it.next()) |param| {
            if (!first) try ctx.out.appendSlice(ctx.allocator, ", ");
            first = false;
            const type_node = param.type_expr orelse return error.UnsupportedFunction;
            const param_type = try ctx.translateType(ctx.nodeSource(type_node), .value);
            try ctx.out.appendSlice(ctx.allocator, param_type.base);
        }
        if (first) try ctx.out.appendSlice(ctx.allocator, "void");
        try ctx.out.appendSlice(ctx.allocator, ");\n\n");
    }

    fn emitCallbackTypedefFromType(ctx: *Context, name: []const u8, type_source: []const u8) HeaderError!void {
        if (!std.mem.startsWith(u8, type_source, "?*const fn (")) return error.UnsupportedFunction;
        const params_start = "?*const fn (".len;
        const params_end = std.mem.indexOf(u8, type_source[params_start..], ") callconv(.c) ") orelse return error.UnsupportedFunction;
        const params = type_source[params_start .. params_start + params_end];
        const return_type_source = type_source[params_start + params_end + ") callconv(.c) ".len ..];
        const return_type = try ctx.translateType(return_type_source, .value);
        try ctx.out.print(ctx.allocator, "typedef {s} (*{s})(", .{ return_type.base, name });
        if (std.mem.trim(u8, params, " \n\r\t").len == 0) {
            try ctx.out.appendSlice(ctx.allocator, "void");
        } else {
            var it = std.mem.splitScalar(u8, params, ',');
            var first = true;
            while (it.next()) |raw_param| {
                if (!first) try ctx.out.appendSlice(ctx.allocator, ", ");
                first = false;
                const param = std.mem.trim(u8, raw_param, " \n\r\t");
                const param_type = try ctx.translateType(param, .value);
                try ctx.out.appendSlice(ctx.allocator, param_type.base);
            }
        }
        try ctx.out.appendSlice(ctx.allocator, ");\n\n");
    }

    fn emitFunctionDecl(ctx: *Context, decl: Ast.Node.Index) HeaderError!void {
        var buffer: [1]Ast.Node.Index = undefined;
        const proto_node = ctx.nodeData(decl).node_and_node[0];
        const proto = ctx.ast.fullFnProto(&buffer, proto_node) orelse return error.UnsupportedFunction;
        const name = ctx.tokenSlice(proto.name_token orelse return error.UnsupportedFunction);
        const return_node = proto.ast.return_type.unwrap() orelse return error.UnsupportedFunction;
        const return_type = try ctx.translateType(ctx.nodeSource(return_node), .return_value);
        try ctx.out.print(ctx.allocator, "ZI_EXPORT {s} {s}(", .{ return_type.base, name });
        var it = proto.iterate(ctx.ast);
        var first = true;
        while (it.next()) |param| {
            if (!first) try ctx.out.appendSlice(ctx.allocator, ", ");
            first = false;
            const type_node = param.type_expr orelse return error.UnsupportedFunction;
            const param_type = try ctx.translateType(ctx.nodeSource(type_node), .value);
            try ctx.out.appendSlice(ctx.allocator, param_type.base);
            if (param.name_token) |name_token| {
                try ctx.out.append(ctx.allocator, ' ');
                try ctx.out.appendSlice(ctx.allocator, ctx.tokenSlice(name_token));
            }
        }
        if (first) try ctx.out.appendSlice(ctx.allocator, "void");
        try ctx.out.appendSlice(ctx.allocator, ");\n\n");
    }

    fn emitField(ctx: *Context, c_type: CType, name: []const u8) HeaderError!void {
        if (c_type.array_suffix) |suffix| {
            try ctx.out.print(ctx.allocator, "    {s} {s}{s};\n", .{ c_type.base, name, suffix });
        } else {
            try ctx.out.print(ctx.allocator, "    {s} {s};\n", .{ c_type.base, name });
        }
    }

    fn translateType(ctx: *Context, zig_type: []const u8, context: TypeContext) HeaderError!CType {
        const trimmed = std.mem.trim(u8, zig_type, " \n\r\t");
        if (std.mem.eql(u8, trimmed, "void")) return CType.scalar("void");
        if (std.mem.eql(u8, trimmed, "bool")) return CType.scalar("bool");
        if (std.mem.eql(u8, trimmed, "u8")) return CType.scalar("uint8_t");
        if (std.mem.eql(u8, trimmed, "u32")) return CType.scalar("uint32_t");
        if (std.mem.eql(u8, trimmed, "u64")) return CType.scalar("uint64_t");
        if (std.mem.eql(u8, trimmed, "usize")) return CType.scalar("size_t");
        if (std.mem.eql(u8, trimmed, "isize")) return CType.scalar("intptr_t");
        if (std.mem.eql(u8, trimmed, "f64")) return CType.scalar("double");
        if (std.mem.eql(u8, trimmed, "c_int")) return CType.scalar("int");
        if (std.mem.eql(u8, trimmed, "[*:0]const u8")) return CType.scalar("const char *");
        if (std.mem.eql(u8, trimmed, "?[*:0]const u8")) return CType.scalar("const char *");
        if (std.mem.eql(u8, trimmed, "?*anyopaque")) return CType.scalar("void *");
        if (std.mem.eql(u8, trimmed, "*anyopaque")) return CType.scalar("void *");
        if (std.mem.eql(u8, trimmed, "?*const anyopaque")) return CType.scalar("const void *");
        if (std.mem.eql(u8, trimmed, "[*]u8") or std.mem.eql(u8, trimmed, "?[*]u8")) return CType.scalar("uint8_t *");
        if (std.mem.eql(u8, trimmed, "[*]const u8") or std.mem.eql(u8, trimmed, "?[*]const u8")) return CType.scalar("const uint8_t *");
        if (std.mem.eql(u8, trimmed, "?*u32")) return CType.scalar("uint32_t *");
        if (std.mem.eql(u8, trimmed, "?*usize")) return CType.scalar("size_t *");
        if (std.mem.eql(u8, trimmed, "?*?*anyopaque")) return CType.scalar("void **");
        if (std.mem.eql(u8, trimmed, "?*?*?*anyopaque")) return CType.scalar("void ***");
        if (std.mem.eql(u8, trimmed, "?*?*zi_hook_t")) return CType.scalar("zi_hook_t *");
        if (std.mem.eql(u8, trimmed, "?*zi_hook_t")) return CType.scalar("zi_hook_t *");
        if (std.mem.eql(u8, trimmed, "?*zi_runtime_t")) return CType.scalar("zi_runtime_t *");
        if (std.mem.eql(u8, trimmed, "?*const zi_runtime_t")) return CType.scalar("const zi_runtime_t *");
        if (std.mem.eql(u8, trimmed, "?*zi_debug_file_line_t")) return CType.scalar("zi_debug_file_line_t *");
        if (std.mem.startsWith(u8, trimmed, "?*const ")) {
            const inner = trimmed["?*const ".len..];
            const inner_type = try ctx.translateType(inner, .value);
            if (inner_type.array_suffix != null) return error.UnsupportedType;
            return CType.scalar(try std.fmt.allocPrint(ctx.allocator, "const {s} *", .{inner_type.base}));
        }
        if (std.mem.startsWith(u8, trimmed, "*const ")) {
            const inner = trimmed["*const ".len..];
            const inner_type = try ctx.translateType(inner, .value);
            if (inner_type.array_suffix != null) return error.UnsupportedType;
            return CType.scalar(try std.fmt.allocPrint(ctx.allocator, "const {s} *", .{inner_type.base}));
        }
        if (std.mem.startsWith(u8, trimmed, "*")) {
            const inner = trimmed[1..];
            const inner_type = try ctx.translateType(inner, .value);
            if (inner_type.array_suffix != null) return error.UnsupportedType;
            return CType.scalar(try std.fmt.allocPrint(ctx.allocator, "{s} *", .{inner_type.base}));
        }
        if (std.mem.startsWith(u8, trimmed, "?*")) {
            const inner = trimmed[2..];
            const inner_type = try ctx.translateType(inner, .value);
            if (inner_type.array_suffix != null) return error.UnsupportedType;
            return CType.scalar(try std.fmt.allocPrint(ctx.allocator, "{s} *", .{inner_type.base}));
        }
        if (std.mem.startsWith(u8, trimmed, "[")) {
            return ctx.translateArrayType(trimmed);
        }
        if (context == .return_value and std.mem.eql(u8, trimmed, "[*:0]const u8")) return CType.scalar("const char *");
        if (std.mem.startsWith(u8, trimmed, "runtime.")) return error.UnsupportedType;
        if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| return error.UnsupportedType;
        return CType.scalar(trimmed);
    }

    fn translateArrayType(ctx: *Context, trimmed: []const u8) HeaderError!CType {
        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return error.UnsupportedType;
        const len_expr = trimmed[1..close];
        const child = trimmed[close + 1 ..];
        const child_type = try ctx.translateType(child, .field);
        if (child_type.array_suffix) |suffix| {
            return .{
                .base = child_type.base,
                .array_suffix = try std.fmt.allocPrint(ctx.allocator, "[{s}]{s}", .{ len_expr, suffix }),
            };
        }
        return .{
            .base = child_type.base,
            .array_suffix = try std.fmt.allocPrint(ctx.allocator, "[{s}]", .{len_expr}),
        };
    }

    fn translateExpr(ctx: *Context, node: Ast.Node.Index) HeaderError![]const u8 {
        const source = std.mem.trim(u8, ctx.nodeSource(node), " \n\r\t");
        if (std.mem.eql(u8, source, "null")) return "0";
        if (std.mem.eql(u8, source, "false")) return "false";
        if (std.mem.eql(u8, source, "true")) return "true";
        if (std.mem.startsWith(u8, source, ".")) return source[1..];
        if (std.mem.startsWith(u8, source, "@sizeOf(")) return try ctx.translateSizeOf(source);
        if (ctx.nodeTag(node) == .number_literal or ctx.nodeTag(node) == .identifier) return source;
        if (ctx.nodeTag(node) == .shl) {
            const data = ctx.nodeData(node).node_and_node;
            const lhs = try ctx.translateExpr(data[0]);
            const rhs = try ctx.translateExpr(data[1]);
            return try std.fmt.allocPrint(ctx.allocator, "({s} << {s})", .{ lhs, rhs });
        }
        if (ctx.nodeTag(node) == .builtin_call_two) return try ctx.translateSizeOf(source);
        return error.UnsupportedExpression;
    }

    fn translateSizeOf(ctx: *Context, source: []const u8) HeaderError![]const u8 {
        if (!std.mem.startsWith(u8, source, "@sizeOf(") or !std.mem.endsWith(u8, source, ")")) return error.UnsupportedExpression;
        const inner = source["@sizeOf(".len .. source.len - 1];
        return try std.fmt.allocPrint(ctx.allocator, "sizeof({s})", .{inner});
    }

    fn isPub(ctx: *Context, node: Ast.Node.Index) bool {
        const main = ctx.nodeMainToken(node);
        if (main == 0) return false;
        if (ctx.tokenTag(main - 1) == .keyword_pub) return true;
        return main >= 2 and ctx.tokenTag(main - 1) == .keyword_export and ctx.tokenTag(main - 2) == .keyword_pub;
    }

    fn nodeSource(ctx: *Context, node: Ast.Node.Index) []const u8 {
        return ctx.ast.getNodeSource(node);
    }

    fn tokenSlice(ctx: *Context, token: Ast.TokenIndex) []const u8 {
        return ctx.ast.tokenSlice(token);
    }

    fn nodeTag(ctx: *Context, node: Ast.Node.Index) Ast.Node.Tag {
        return ctx.ast.nodes.items(.tag)[@intFromEnum(node)];
    }

    fn nodeData(ctx: *Context, node: Ast.Node.Index) Ast.Node.Data {
        return ctx.ast.nodes.items(.data)[@intFromEnum(node)];
    }

    fn nodeMainToken(ctx: *Context, node: Ast.Node.Index) Ast.TokenIndex {
        return ctx.ast.nodes.items(.main_token)[@intFromEnum(node)];
    }

    fn tokenTag(ctx: *Context, token: Ast.TokenIndex) std.zig.Token.Tag {
        return ctx.ast.tokens.items(.tag)[token];
    }
};

const TypeContext = enum {
    value,
    field,
    return_value,
};

const CType = struct {
    base: []const u8,
    array_suffix: ?[]const u8 = null,

    fn scalar(value: []const u8) CType {
        return .{ .base = value };
    }
};

test "unsupported public ABI declarations fail generation" {
    const source =
        \\pub const bad_enum_t = enum {
        \\    BAD = 0,
        \\};
        \\
    ;
    try std.testing.expectError(error.UnsupportedAbiDeclaration, generate(std.testing.allocator, source));
}
