const std = @import("std");

pub const patch_len = 16;
pub const jump_len = 16;

pub const Error = error{UnsupportedInstruction};

pub const InstructionKind = enum {
    copy,
    b,
    bl,
    b_cond,
    cbz,
    cbnz,
    tbz,
    tbnz,
    adr,
    adrp,
    literal_load,
    bti,
    pac,
};

pub const DecodedInstruction = struct {
    raw: u32,
    kind: InstructionKind,
};

pub const RelocatedInstruction = struct {
    len: usize,
    ends_control_flow: bool = false,
};

pub fn relocationLength(code: []const u8, required_len: usize) Error!usize {
    if (required_len == 0 or code.len < required_len or required_len % 4 != 0) return error.UnsupportedInstruction;
    var len: usize = 0;
    while (len < required_len) : (len += 4) {
        _ = try decode(std.mem.readInt(u32, code[len..][0..4], .little));
    }
    return len;
}

pub fn relocatedLength(code: []const u8) Error!usize {
    if (code.len == 0 or code.len % 4 != 0) return error.UnsupportedInstruction;
    var len: usize = 0;
    var index: usize = 0;
    while (index < code.len) : (index += 4) {
        len += (try relocatedInstructionLength(std.mem.readInt(u32, code[index..][0..4], .little))).len;
    }
    return len;
}

pub fn decode(instruction: u32) Error!DecodedInstruction {
    return .{ .raw = instruction, .kind = classify(instruction) orelse return error.UnsupportedInstruction };
}

pub fn relocate(out: []u8, code: []const u8, source_address: usize) Error!usize {
    if (code.len == 0 or code.len % 4 != 0) return error.UnsupportedInstruction;
    var out_index: usize = 0;
    var code_index: usize = 0;
    while (code_index < code.len) : (code_index += 4) {
        const instruction = std.mem.readInt(u32, code[code_index..][0..4], .little);
        out_index += try relocateInstruction(out[out_index..], instruction, source_address + code_index);
    }
    return out_index;
}

pub fn writeAbsoluteJump(out: []u8, target: usize) Error!usize {
    if (out.len < jump_len) return error.UnsupportedInstruction;
    // ldr x16, #8; br x16; .quad target
    std.mem.writeInt(u32, out[0..4], 0x58000050, .little);
    std.mem.writeInt(u32, out[4..8], 0xd61f0200, .little);
    std.mem.writeInt(u64, out[8..16], target, .little);
    return jump_len;
}

pub fn classify(instruction: u32) ?InstructionKind {
    if (instruction == 0xd503201f) return .copy; // nop
    if ((instruction & 0xfffffff0) == 0xd503241f) return .bti;
    if (instruction == 0xd503233f or instruction == 0xd50323bf) return .pac; // paciasp/autiasp
    if ((instruction & 0x7c000000) == 0x14000000) return if ((instruction & 0x80000000) != 0) .bl else .b;
    if ((instruction & 0xff000010) == 0x54000000) return .b_cond;
    if ((instruction & 0x7e000000) == 0x34000000) return if ((instruction & 0x01000000) != 0) .cbnz else .cbz;
    if ((instruction & 0x7e000000) == 0x36000000) return if ((instruction & 0x01000000) != 0) .tbnz else .tbz;
    if ((instruction & 0x9f000000) == 0x10000000) return .adr;
    if ((instruction & 0x9f000000) == 0x90000000) return .adrp;
    if ((instruction & 0x3b000000) == 0x18000000) return .literal_load;
    if (isDirectCopy(instruction)) return .copy;
    return null;
}

fn isDirectCopy(instruction: u32) bool {
    if ((instruction & 0xffc00000) == 0x91000000) return true; // add imm
    if ((instruction & 0xffc00000) == 0xd1000000) return true; // sub imm
    if ((instruction & 0xffc00000) == 0xa9000000) return true; // stp
    if ((instruction & 0xffc00000) == 0xa9400000) return true; // ldp
    if ((instruction & 0xfffffc00) == 0xd10003ff) return true; // sub sp
    if ((instruction & 0xfffffc00) == 0x910003ff) return true; // add sp
    if ((instruction & 0xffe00c00) == 0xf8000000) return true; // str/ldr pre/post unsigned family subset
    if ((instruction & 0x1f000000) == 0x0b000000) return true; // add/sub register class subset
    return false;
}

fn relocatedInstructionLength(instruction: u32) Error!RelocatedInstruction {
    const kind = (try decode(instruction)).kind;
    return switch (kind) {
        .copy, .bti, .pac => .{ .len = 4 },
        .b, .bl => .{ .len = 20, .ends_control_flow = kind == .b },
        .b_cond, .cbz, .cbnz, .tbz, .tbnz => .{ .len = 24 },
        .adr, .adrp => .{ .len = 16 },
        .literal_load => .{ .len = 20 },
    };
}

fn relocateInstruction(out: []u8, instruction: u32, source_address: usize) Error!usize {
    const decoded = try decode(instruction);
    return switch (decoded.kind) {
        .copy, .bti, .pac => copyInstruction(out, instruction),
        .b => relocateBranch(out, instruction, source_address, false),
        .bl => relocateBranch(out, instruction, source_address, true),
        .b_cond => relocateConditionalBranch(out, instruction, source_address),
        .cbz, .cbnz => relocateCompareBranch(out, instruction, source_address),
        .tbz, .tbnz => relocateTestBranch(out, instruction, source_address),
        .adr => relocateAdr(out, instruction, source_address, false),
        .adrp => relocateAdr(out, instruction, source_address, true),
        .literal_load => relocateLiteralLoad(out, instruction, source_address),
    };
}

fn copyInstruction(out: []u8, instruction: u32) Error!usize {
    if (out.len < 4) return error.UnsupportedInstruction;
    std.mem.writeInt(u32, out[0..4], instruction, .little);
    return 4;
}

fn relocateBranch(out: []u8, instruction: u32, source_address: usize, link: bool) Error!usize {
    if (out.len < 20) return error.UnsupportedInstruction;
    const offset = decodeImm26Offset(instruction);
    const target = source_address +% @as(usize, @bitCast(offset));
    const load: u32 = if (link) 0x58000070 else 0x58000050; // ldr x16/x17, #12
    std.mem.writeInt(u32, out[0..4], load, .little);
    std.mem.writeInt(u32, out[4..8], if (link) @as(u32, 0xd63f0220) else @as(u32, 0xd61f0200), .little); // blr/br x17/x16
    std.mem.writeInt(u32, out[8..12], 0xd503201f, .little);
    std.mem.writeInt(u64, out[12..20], target, .little);
    return 20;
}

fn relocateConditionalBranch(out: []u8, instruction: u32, source_address: usize) Error!usize {
    if (out.len < 24) return error.UnsupportedInstruction;
    const offset = decodeImm19Offset(instruction);
    const target = source_address +% @as(usize, @bitCast(offset));
    const condition = instruction & 0xf;
    const inverse = condition ^ 1;
    const skip = encodeBCond(5, inverse);
    std.mem.writeInt(u32, out[0..4], skip, .little);
    std.mem.writeInt(u32, out[4..8], 0x58000050, .little); // ldr x16, #8
    std.mem.writeInt(u32, out[8..12], 0xd61f0200, .little); // br x16
    std.mem.writeInt(u64, out[12..20], target, .little);
    std.mem.writeInt(u32, out[20..24], 0xd503201f, .little);
    return 24;
}

fn relocateCompareBranch(out: []u8, instruction: u32, source_address: usize) Error!usize {
    if (out.len < 24) return error.UnsupportedInstruction;
    const offset = decodeImm19Offset(instruction);
    const target = source_address +% @as(usize, @bitCast(offset));
    const inverse = instruction ^ @as(u32, 0x01000000);
    const branch = encodeImm19Instruction(inverse, 5);
    std.mem.writeInt(u32, out[0..4], branch, .little);
    std.mem.writeInt(u32, out[4..8], 0x58000050, .little);
    std.mem.writeInt(u32, out[8..12], 0xd61f0200, .little);
    std.mem.writeInt(u64, out[12..20], target, .little);
    std.mem.writeInt(u32, out[20..24], 0xd503201f, .little);
    return 24;
}

fn relocateTestBranch(out: []u8, instruction: u32, source_address: usize) Error!usize {
    if (out.len < 24) return error.UnsupportedInstruction;
    const offset = decodeImm14Offset(instruction);
    const target = source_address +% @as(usize, @bitCast(offset));
    const inverse = instruction ^ @as(u32, 0x01000000);
    const branch = encodeImm14Instruction(inverse, 5);
    std.mem.writeInt(u32, out[0..4], branch, .little);
    std.mem.writeInt(u32, out[4..8], 0x58000050, .little);
    std.mem.writeInt(u32, out[8..12], 0xd61f0200, .little);
    std.mem.writeInt(u64, out[12..20], target, .little);
    std.mem.writeInt(u32, out[20..24], 0xd503201f, .little);
    return 24;
}

fn relocateAdr(out: []u8, instruction: u32, source_address: usize, page_only: bool) Error!usize {
    if (out.len < 16) return error.UnsupportedInstruction;
    const rd = instruction & 0x1f;
    const target_address = if (page_only)
        std.mem.alignBackward(usize, source_address +% @as(usize, @bitCast(decodeImm21PageOffset(instruction))), 4096)
    else
        source_address +% @as(usize, @bitCast(decodeImm21Offset(instruction)));
    std.mem.writeInt(u32, out[0..4], 0x58000040 | rd, .little); // ldr xN, #8
    std.mem.writeInt(u32, out[4..8], 0x14000003, .little); // b #12
    std.mem.writeInt(u64, out[8..16], target_address, .little);
    return 16;
}

fn relocateLiteralLoad(out: []u8, instruction: u32, source_address: usize) Error!usize {
    if (out.len < 20) return error.UnsupportedInstruction;
    const rt = instruction & 0x1f;
    const kind = (instruction >> 30) & 0x3;
    const target = source_address +% @as(usize, @bitCast(decodeImm19Offset(instruction)));
    std.mem.writeInt(u32, out[0..4], 0x58000050, .little); // ldr x16, #8
    std.mem.writeInt(u32, out[4..8], literalLoadViaRegister(kind, rt), .little);
    std.mem.writeInt(u32, out[8..12], 0xd503201f, .little);
    std.mem.writeInt(u64, out[12..20], target, .little);
    return 20;
}

fn literalLoadViaRegister(kind: u32, rt: u32) u32 {
    return switch (kind) {
        0b00 => 0xb9400200 | rt | (@as(u32, 16) << 5), // ldr wt, [x16]
        0b01 => 0xf9400200 | rt | (@as(u32, 16) << 5), // ldr xt, [x16]
        0b10 => 0xbd400200 | rt | (@as(u32, 16) << 5), // ldr st, [x16]
        0b11 => 0xfd400200 | rt | (@as(u32, 16) << 5), // ldr dt, [x16]
        else => unreachable,
    };
}

fn decodeImm26Offset(instruction: u32) isize {
    const imm = signExtend((instruction & 0x03ffffff), 26);
    return @as(isize, imm) << 2;
}

fn decodeImm19Offset(instruction: u32) isize {
    const imm = signExtend((instruction >> 5) & 0x7ffff, 19);
    return @as(isize, imm) << 2;
}

fn decodeImm14Offset(instruction: u32) isize {
    const imm = signExtend((instruction >> 5) & 0x3fff, 14);
    return @as(isize, imm) << 2;
}

fn decodeImm21Offset(instruction: u32) isize {
    const immlo = (instruction >> 29) & 0x3;
    const immhi = (instruction >> 5) & 0x7ffff;
    const imm = signExtend((immhi << 2) | immlo, 21);
    return @as(isize, imm);
}

fn decodeImm21PageOffset(instruction: u32) isize {
    const immlo = (instruction >> 29) & 0x3;
    const immhi = (instruction >> 5) & 0x7ffff;
    const imm = signExtend((immhi << 2) | immlo, 21);
    return @as(isize, imm) << 12;
}

fn signExtend(value: u32, bits: u5) i32 {
    const shift: u5 = @intCast(@as(u32, 32) - bits);
    return (@as(i32, @bitCast(value << shift))) >> shift;
}

fn encodeBCond(skip_words: u32, condition: u32) u32 {
    return 0x54000000 | ((skip_words & 0x7ffff) << 5) | (condition & 0xf);
}

fn encodeImm19Instruction(instruction: u32, skip_words: u32) u32 {
    return (instruction & ~@as(u32, 0x00ffffe0)) | ((skip_words & 0x7ffff) << 5);
}

fn encodeImm14Instruction(instruction: u32, skip_words: u32) u32 {
    return (instruction & ~@as(u32, 0x0007ffe0)) | ((skip_words & 0x3fff) << 5);
}

test "arm64 absolute jump encoding" {
    var bytes: [jump_len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, jump_len), try writeAbsoluteJump(&bytes, 0x1122334455667788));
    try std.testing.expectEqual(@as(u32, 0x58000050), std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xd61f0200), std.mem.readInt(u32, bytes[4..8], .little));
}

test "arm64 classifies PC-relative and PAC/BTI prologue instructions" {
    try std.testing.expectEqual(InstructionKind.b, (try decode(0x14000000)).kind);
    try std.testing.expectEqual(InstructionKind.bl, (try decode(0x94000000)).kind);
    try std.testing.expectEqual(InstructionKind.b_cond, (try decode(0x54000000)).kind);
    try std.testing.expectEqual(InstructionKind.cbz, (try decode(0x34000000)).kind);
    try std.testing.expectEqual(InstructionKind.cbnz, (try decode(0x35000000)).kind);
    try std.testing.expectEqual(InstructionKind.tbz, (try decode(0x36000000)).kind);
    try std.testing.expectEqual(InstructionKind.tbnz, (try decode(0x37000000)).kind);
    try std.testing.expectEqual(InstructionKind.adr, (try decode(0x10000000)).kind);
    try std.testing.expectEqual(InstructionKind.adrp, (try decode(0x90000000)).kind);
    try std.testing.expectEqual(InstructionKind.literal_load, (try decode(0x58000000)).kind);
    try std.testing.expectEqual(InstructionKind.bti, (try decode(0xd503241f)).kind);
    try std.testing.expectEqual(InstructionKind.pac, (try decode(0xd503233f)).kind);
}

test "arm64 relocation expands branch-like instructions" {
    const branch = try relocatedInstructionLength(0x14000000);
    try std.testing.expectEqual(@as(usize, 20), branch.len);
    try std.testing.expect(branch.ends_control_flow);
    const cond = try relocatedInstructionLength(0x54000000);
    try std.testing.expectEqual(@as(usize, 24), cond.len);
    try std.testing.expect(!cond.ends_control_flow);
}
