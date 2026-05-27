const std = @import("std");
const builtin = @import("builtin");

const MachPort = if (builtin.os.tag.isDarwin()) std.c.mach_port_t else u32;
const MachPortArray = if (builtin.os.tag.isDarwin()) std.c.mach_port_array_t else [*]MachPort;
const MachMsgTypeNumber = if (builtin.os.tag.isDarwin()) std.c.mach_msg_type_number_t else u32;
const ThreadAct = if (builtin.os.tag.isDarwin()) std.c.thread_act_t else MachPort;
const ThreadFlavor = if (builtin.os.tag.isDarwin()) std.c.thread_flavor_t else u32;
const KernReturn = if (builtin.os.tag.isDarwin()) std.c.kern_return_t else i32;

pub const Error = error{
    UnsupportedPlatform,
    UnsupportedOperation,
    AccessDenied,
    Conflict,
};

pub const PatchWindow = struct {
    target: usize,
    len: usize,
    trampoline: ?usize = null,
    trampoline_len: usize = 0,
};

pub const Transaction = struct {
    threads: []MachPort = &.{},
    suspended_count: usize = 0,

    fn empty() Transaction {
        return .{};
    }
};

extern "c" fn mach_thread_self() MachPort;
extern "c" fn thread_suspend(thread: ThreadAct) KernReturn;

pub fn beginPatchTransaction(window: PatchWindow, allow_racy: bool) Error!Transaction {
    if (!isDarwin()) return error.UnsupportedPlatform;
    if (allow_racy) return Transaction.empty();
    if (window.len == 0) return error.UnsupportedOperation;

    var ports: MachPortArray = undefined;
    var count: MachMsgTypeNumber = 0;
    if (std.c.task_threads(std.c.mach_task_self(), &ports, &count) != 0) return error.AccessDenied;
    const thread_ports = ports[0..count];
    const current = mach_thread_self();
    var transaction: Transaction = .{ .threads = thread_ports };
    var index: usize = 0;
    while (index < thread_ports.len) : (index += 1) {
        const thread = thread_ports[index];
        if (thread == current) continue;
        if (thread_suspend(thread) != 0) {
            resumeSuspended(transaction);
            deallocateThreadPorts(thread_ports);
            _ = std.c.mach_port_deallocate(std.c.mach_task_self(), current);
            return error.AccessDenied;
        }
        thread_ports[transaction.suspended_count] = thread;
        transaction.suspended_count += 1;
    }
    _ = std.c.mach_port_deallocate(std.c.mach_task_self(), current);

    if (anySuspendedThreadInWindow(transaction, window)) {
        resumeSuspended(transaction);
        deallocateThreadPorts(thread_ports);
        return error.Conflict;
    }

    return transaction;
}

pub fn endPatchTransaction(transaction: Transaction) void {
    if (transaction.threads.len == 0) return;
    resumeSuspended(transaction);
    deallocateThreadPorts(transaction.threads);
}

fn resumeSuspended(transaction: Transaction) void {
    for (transaction.threads[0..transaction.suspended_count]) |thread| {
        _ = std.c.thread_resume(thread);
    }
}

fn deallocateThreadPorts(threads: []MachPort) void {
    const bytes = threads.len * @sizeOf(MachPort);
    for (threads) |thread| _ = std.c.mach_port_deallocate(std.c.mach_task_self(), thread);
    if (bytes != 0) _ = std.c.vm_deallocate(std.c.mach_task_self(), @intFromPtr(threads.ptr), bytes);
}

fn anySuspendedThreadInWindow(transaction: Transaction, window: PatchWindow) bool {
    for (transaction.threads[0..transaction.suspended_count]) |thread| {
        if (readThreadPC(thread)) |pc| {
            if (addressInWindow(pc, window.target, window.len)) return true;
            if (window.trampoline) |trampoline| {
                if (addressInWindow(pc, trampoline, window.trampoline_len)) return true;
            }
        } else |_| {
            return true;
        }
    }
    return false;
}

fn addressInWindow(address: usize, start: usize, len: usize) bool {
    return len != 0 and address >= start and address < start + len;
}

fn readThreadPC(thread: ThreadAct) Error!usize {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => readArm64PC(thread),
        .x86_64 => readX86_64PC(thread),
        else => error.UnsupportedOperation,
    };
}

const ARM_THREAD_STATE64: ThreadFlavor = 6;
const ARM_THREAD_STATE64_COUNT: MachMsgTypeNumber = 68;
const X86_THREAD_STATE64: ThreadFlavor = 4;
const X86_THREAD_STATE64_COUNT: MachMsgTypeNumber = 42;

const ArmThreadState64 = extern struct {
    x: [29]u64,
    fp: u64,
    lr: u64,
    sp: u64,
    pc: u64,
    cpsr: u32,
    flags: u32,
};

const X86ThreadState64 = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rsp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,
    cs: u64,
    fs: u64,
    gs: u64,
};

fn readArm64PC(thread: ThreadAct) Error!usize {
    var state: ArmThreadState64 = undefined;
    var count: MachMsgTypeNumber = ARM_THREAD_STATE64_COUNT;
    const kr = std.c.thread_get_state(thread, ARM_THREAD_STATE64, @ptrCast(&state), &count);
    if (kr != 0) return error.AccessDenied;
    return @intCast(state.pc);
}

fn readX86_64PC(thread: ThreadAct) Error!usize {
    var state: X86ThreadState64 = undefined;
    var count: MachMsgTypeNumber = X86_THREAD_STATE64_COUNT;
    const kr = std.c.thread_get_state(thread, X86_THREAD_STATE64, @ptrCast(&state), &count);
    if (kr != 0) return error.AccessDenied;
    return @intCast(state.rip);
}

fn isDarwin() bool {
    return comptime builtin.os.tag.isDarwin();
}

test "address window matching is half-open" {
    try std.testing.expect(!addressInWindow(9, 10, 4));
    try std.testing.expect(addressInWindow(10, 10, 4));
    try std.testing.expect(addressInWindow(13, 10, 4));
    try std.testing.expect(!addressInWindow(14, 10, 4));
}
