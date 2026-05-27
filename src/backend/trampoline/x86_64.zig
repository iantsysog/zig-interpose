const std = @import("std");

pub const near_jump_len = 5;
pub const absolute_jump_len = 12;
pub const jump_len = absolute_jump_len;

pub const Error = error{UnsupportedInstruction};

pub const BranchKind = enum {
    none,
    call_rel32,
    jmp_rel8,
    jmp_rel32,
    jcc_rel8,
    jcc_rel32,
    rip_relative_memory,
};

pub const DecodedInstruction = struct {
    len: usize,
    branch: BranchKind = .none,
    displacement_offset: usize = 0,
    displacement_width: usize = 0,
};

pub fn relocatedLength(code: []const u8) Error!usize {
    var total: usize = 0;
    var index: usize = 0;
    while (index < code.len) {
        const instruction = try decode(code[index..]);
        total += relocatedInstructionLength(code[index .. index + instruction.len], instruction);
        index += instruction.len;
    }
    return total;
}

pub fn relocationLength(code: []const u8, required_len: usize) Error!usize {
    var index: usize = 0;
    while (index < required_len) {
        index += (try decode(code[index..])).len;
    }
    return index;
}

pub fn relocate(out: []u8, code: []const u8, source_address: usize, destination_address: usize) Error!usize {
    var code_index: usize = 0;
    var out_index: usize = 0;
    while (code_index < code.len) {
        const instruction = try decode(code[code_index..]);
        const raw = code[code_index .. code_index + instruction.len];
        out_index += try relocateInstruction(
            out[out_index..],
            raw,
            instruction,
            source_address + code_index,
            destination_address + out_index,
        );
        code_index += instruction.len;
    }
    return out_index;
}

pub fn decode(code: []const u8) Error!DecodedInstruction {
    if (code.len == 0) return error.UnsupportedInstruction;
    var index: usize = 0;
    while (index < code.len and isLegacyPrefix(code[index])) : (index += 1) {}
    if (index < code.len and isRexPrefix(code[index])) index += 1;
    if (index >= code.len) return error.UnsupportedInstruction;

    const opcode_start = index;
    const opcode = code[index];
    index += 1;
    switch (opcode) {
        0x0f => return decodeTwoByte(code, opcode_start, index),
        0xe8 => return rel(code, index, 4, .call_rel32),
        0xe9 => return rel(code, index, 4, .jmp_rel32),
        0xeb => return rel(code, index, 1, .jmp_rel8),
        0x70...0x7f => return rel(code, index, 1, .jcc_rel8),
        0x55, 0x53, 0x57, 0x56, 0x5d, 0xc3, 0x90 => return .{ .len = index },
        0x50...0x5f => return .{ .len = index },
        0x68 => return require(code, index + 4),
        0x6a => return require(code, index + 1),
        0xb8...0xbf => return require(code, index + immediateWidth(code[0..index])),
        0x89, 0x8b, 0x8d, 0x8f, 0x01, 0x03, 0x29, 0x2b, 0x31, 0x33, 0x39, 0x3b, 0x83, 0x85, 0xff => return modRmInstruction(code, index, immediateForOpcode(opcode)),
        0xc7 => return modRmInstruction(code, index, 4),
        0xf2, 0xf3 => return decode(code[index - 1 ..]),
        else => return error.UnsupportedInstruction,
    }
}

pub fn writeAbsoluteJump(out: []u8, target: usize) Error!usize {
    if (out.len < absolute_jump_len) return error.UnsupportedInstruction;
    out[0] = 0x48;
    out[1] = 0xb8;
    std.mem.writeInt(u64, out[2..10], target, .little);
    out[10] = 0xff;
    out[11] = 0xe0;
    return absolute_jump_len;
}

pub fn writeRelativeJump(out: []u8, source: usize, target: usize) Error!usize {
    if (out.len < near_jump_len) return error.UnsupportedInstruction;
    const delta = @as(i128, @intCast(target)) - @as(i128, @intCast(source + near_jump_len));
    if (delta < std.math.minInt(i32) or delta > std.math.maxInt(i32)) return error.UnsupportedInstruction;
    out[0] = 0xe9;
    std.mem.writeInt(i32, out[1..5], @intCast(delta), .little);
    return near_jump_len;
}

pub fn canEncodeRelativeJump(source: usize, target: usize) bool {
    const delta = @as(i128, @intCast(target)) - @as(i128, @intCast(source + near_jump_len));
    return delta >= std.math.minInt(i32) and delta <= std.math.maxInt(i32);
}

fn decodeTwoByte(code: []const u8, opcode_start: usize, index_after_escape: usize) Error!DecodedInstruction {
    if (index_after_escape >= code.len) return error.UnsupportedInstruction;
    const opcode = code[index_after_escape];
    const index = index_after_escape + 1;
    if (opcode >= 0x80 and opcode <= 0x8f) return rel(code, index, 4, .jcc_rel32);
    return switch (opcode) {
        0x1f => modRmInstruction(code, index, 0),
        0x28, 0x29, 0x2e, 0x2f, 0x57, 0x6f, 0x7f => modRmInstruction(code, index, 0),
        else => {
            _ = opcode_start;
            return error.UnsupportedInstruction;
        },
    };
}

fn modRmInstruction(code: []const u8, modrm_index: usize, immediate_len: usize) Error!DecodedInstruction {
    if (modrm_index >= code.len) return error.UnsupportedInstruction;
    const modrm = code[modrm_index];
    var len = modrm_index + 1;
    const mode = modrm >> 6;
    const rm = modrm & 7;
    var branch: BranchKind = .none;
    var displacement_offset: usize = 0;
    var displacement_width: usize = 0;
    if (mode != 3 and rm == 4) {
        if (len >= code.len) return error.UnsupportedInstruction;
        const sib = code[len];
        len += 1;
        if (mode == 0 and (sib & 7) == 5) {
            displacement_offset = len;
            displacement_width = 4;
            len += 4;
        }
    } else if (mode == 0 and rm == 5) {
        branch = .rip_relative_memory;
        displacement_offset = len;
        displacement_width = 4;
        len += 4;
    }
    if (mode == 1) {
        displacement_offset = len;
        displacement_width = 1;
        len += 1;
    }
    if (mode == 2) {
        displacement_offset = len;
        displacement_width = 4;
        len += 4;
    }
    len += immediate_len;
    if (code.len < len) return error.UnsupportedInstruction;
    return .{
        .len = len,
        .branch = branch,
        .displacement_offset = displacement_offset,
        .displacement_width = displacement_width,
    };
}

fn rel(code: []const u8, immediate_index: usize, width: usize, branch: BranchKind) Error!DecodedInstruction {
    if (code.len < immediate_index + width) return error.UnsupportedInstruction;
    return .{
        .len = immediate_index + width,
        .branch = branch,
        .displacement_offset = immediate_index,
        .displacement_width = width,
    };
}

fn require(code: []const u8, len: usize) Error!DecodedInstruction {
    if (code.len < len) return error.UnsupportedInstruction;
    return .{ .len = len };
}

fn immediateWidth(prefix_and_opcode: []const u8) usize {
    return if (std.mem.indexOfScalar(u8, prefix_and_opcode, 0x48) != null) 8 else 4;
}

fn immediateForOpcode(opcode: u8) usize {
    return switch (opcode) {
        0x83 => 1,
        else => 0,
    };
}

fn isLegacyPrefix(byte: u8) bool {
    return byte == 0x66 or byte == 0x67 or byte == 0xf2 or byte == 0xf3 or byte == 0x2e or byte == 0x36 or byte == 0x3e or byte == 0x26 or byte == 0x64 or byte == 0x65;
}

fn isRexPrefix(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x4f;
}

fn relocatedInstructionLength(raw: []const u8, instruction: DecodedInstruction) usize {
    _ = raw;
    return switch (instruction.branch) {
        .none => instruction.len,
        .call_rel32 => 12,
        .jmp_rel8, .jmp_rel32 => 12,
        .jcc_rel8, .jcc_rel32 => 18,
        .rip_relative_memory => instruction.len,
    };
}

fn relocateInstruction(out: []u8, raw: []const u8, instruction: DecodedInstruction, source_address: usize, destination_address: usize) Error!usize {
    switch (instruction.branch) {
        .none => {
            if (out.len < raw.len) return error.UnsupportedInstruction;
            @memcpy(out[0..raw.len], raw);
            return raw.len;
        },
        .call_rel32 => {
            if (out.len < absolute_jump_len) return error.UnsupportedInstruction;
            const target = resolveBranchTarget(raw, instruction, source_address);
            out[0] = 0x48;
            out[1] = 0xb8;
            std.mem.writeInt(u64, out[2..10], target, .little);
            out[10] = 0xff;
            out[11] = 0xd0;
            return absolute_jump_len;
        },
        .jmp_rel8, .jmp_rel32 => {
            if (out.len < absolute_jump_len) return error.UnsupportedInstruction;
            const target = resolveBranchTarget(raw, instruction, source_address);
            return writeAbsoluteJump(out, target);
        },
        .jcc_rel8, .jcc_rel32 => {
            if (out.len < 18) return error.UnsupportedInstruction;
            const target = resolveBranchTarget(raw, instruction, source_address);
            const inverse = invertConditionCode(raw);
            out[0] = 0x70 | inverse;
            out[1] = 0x0c;
            _ = try writeAbsoluteJump(out[2..14], target);
            @memset(out[14..18], 0x90);
            return 18;
        },
        .rip_relative_memory => {
            if (out.len < raw.len) return error.UnsupportedInstruction;
            @memcpy(out[0..raw.len], raw);
            const target = resolveRipRelativeTarget(raw, instruction, source_address);
            const new_disp = @as(i128, @intCast(target)) - @as(i128, @intCast(destination_address + instruction.len));
            if (new_disp < std.math.minInt(i32) or new_disp > std.math.maxInt(i32)) return error.UnsupportedInstruction;
            std.mem.writeInt(i32, out[instruction.displacement_offset .. instruction.displacement_offset + 4], @intCast(new_disp), .little);
            return raw.len;
        },
    }
}

fn resolveBranchTarget(raw: []const u8, instruction: DecodedInstruction, source_address: usize) usize {
    return switch (instruction.displacement_width) {
        1 => {
            const delta = std.mem.readInt(i8, raw[instruction.displacement_offset .. instruction.displacement_offset + 1], .little);
            return source_address + raw.len +% @as(usize, @bitCast(@as(isize, delta)));
        },
        4 => {
            const delta = std.mem.readInt(i32, raw[instruction.displacement_offset .. instruction.displacement_offset + 4], .little);
            return source_address + raw.len +% @as(usize, @bitCast(@as(isize, delta)));
        },
        else => unreachable,
    };
}

fn resolveRipRelativeTarget(raw: []const u8, instruction: DecodedInstruction, source_address: usize) usize {
    const delta = std.mem.readInt(i32, raw[instruction.displacement_offset .. instruction.displacement_offset + 4], .little);
    return source_address + raw.len +% @as(usize, @bitCast(@as(isize, delta)));
}

fn invertConditionCode(raw: []const u8) u8 {
    if (raw[0] == 0x0f) return raw[1] ^ 1;
    return raw[0] ^ 1;
}

test "x86_64 absolute jump encoding" {
    var bytes: [absolute_jump_len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, absolute_jump_len), try writeAbsoluteJump(&bytes, 0x1122334455667788));
    try std.testing.expectEqual(@as(u8, 0x48), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xb8), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0xff), bytes[10]);
    try std.testing.expectEqual(@as(u8, 0xe0), bytes[11]);
}

test "x86_64 relative jump encoding" {
    var bytes: [near_jump_len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, near_jump_len), try writeRelativeJump(&bytes, 0x1000, 0x1010));
    try std.testing.expectEqual(@as(u8, 0xe9), bytes[0]);
    try std.testing.expectEqual(@as(i32, 0x0b), std.mem.readInt(i32, bytes[1..5], .little));
}

test "x86_64 prologue length plan" {
    const code = [_]u8{ 0x55, 0x48, 0x89, 0xe5, 0x48, 0x83, 0xec, 0x20, 0x90, 0x90, 0x90, 0x90 };
    try std.testing.expectEqual(@as(usize, 8), try relocationLength(&code, near_jump_len));
    try std.testing.expectEqual(@as(usize, 12), try relocationLength(&code, absolute_jump_len));
}

test "x86_64 decodes branch and RIP-relative forms" {
    try std.testing.expectEqual(BranchKind.call_rel32, (try decode(&[_]u8{ 0xe8, 0, 0, 0, 0 })).branch);
    try std.testing.expectEqual(BranchKind.jmp_rel8, (try decode(&[_]u8{ 0xeb, 0 })).branch);
    try std.testing.expectEqual(BranchKind.jcc_rel32, (try decode(&[_]u8{ 0x0f, 0x84, 0, 0, 0, 0 })).branch);
    try std.testing.expectEqual(BranchKind.rip_relative_memory, (try decode(&[_]u8{ 0x48, 0x8b, 0x05, 0, 0, 0, 0 })).branch);
}

test "x86_64 relocated length grows control-flow instructions" {
    try std.testing.expectEqual(@as(usize, 12), try relocatedLength(&[_]u8{ 0xe8, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(usize, 18), try relocatedLength(&[_]u8{ 0x0f, 0x84, 0, 0, 0, 0 }));
}
