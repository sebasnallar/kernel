// MyLittleKernel - ARM64 Exception Vector Table
//
// ARM64 requires the exception vector table to be:
// - 2KB aligned (11 bits)
// - 16 vectors of 128 bytes each (0x80 bytes)

const root = @import("root");
const interrupt = root.interrupt;
const console = root.console;

/// Install the exception vector table
pub fn install() void {
    // Get mutable pointer to vector table
    const table_ptr: [*]u32 = @ptrCast(@alignCast(&vector_table));
    const vbar = @intFromPtr(&vector_table);

    // Helper to encode branch instruction
    const encodeB = struct {
        fn f(from: u64, to: u64) u32 {
            const off: i64 = @as(i64, @intCast(to)) - @as(i64, @intCast(from));
            const imm26: u32 = @truncate(@as(u32, @bitCast(@as(i32, @truncate(off >> 2)))) & 0x3FFFFFF);
            return (0b000101 << 26) | imm26;
        }
    }.f;

    // === EL1h vectors (exceptions while in kernel mode) ===

    // Patch Sync vector (at offset 0x200) to branch to syncEntry
    const sync_handler_addr = @intFromPtr(&syncEntry);
    const sync_vector_addr = vbar + 0x200;
    const sync_b_inst = encodeB(sync_vector_addr, sync_handler_addr);
    table_ptr[0x200 / 4] = sync_b_inst;

    // Patch IRQ vector (at offset 0x280) to branch to irqEntry
    const irq_handler_addr = @intFromPtr(&irqEntry);
    const irq_vector_addr = vbar + 0x280;
    const b_inst = encodeB(irq_vector_addr, irq_handler_addr);
    table_ptr[0x280 / 4] = b_inst;

    // === EL0 64-bit vectors (exceptions from userspace) ===

    // Patch EL0 Sync vector (at offset 0x400) - syscalls from userspace
    const el0_sync_handler_addr = @intFromPtr(&el0SyncEntry);
    const el0_sync_vector_addr = vbar + 0x400;
    const el0_sync_b_inst = encodeB(el0_sync_vector_addr, el0_sync_handler_addr);
    table_ptr[0x400 / 4] = el0_sync_b_inst;

    // Patch EL0 IRQ vector (at offset 0x480) - interrupts while in userspace
    const el0_irq_handler_addr = @intFromPtr(&el0IrqEntry);
    const el0_irq_vector_addr = vbar + 0x480;
    const el0_irq_b_inst = encodeB(el0_irq_vector_addr, el0_irq_handler_addr);
    table_ptr[0x480 / 4] = el0_irq_b_inst;

    // Ensure write is visible
    asm volatile ("dsb sy");
    asm volatile ("isb");

    // Verify the write by reading back
    const verify = table_ptr[0x280 / 4];
    console.puts("  Written: ");
    console.putHex(b_inst);
    console.puts(" Read back: ");
    console.putHex(verify);
    if (verify == b_inst) {
        console.puts(" (OK)\n");
    } else {
        console.puts(" (MISMATCH!)\n");
    }

    console.puts("  VBAR_EL1 = ");
    console.putHex(vbar);
    console.puts("\n  IRQ vector at ");
    console.putHex(irq_vector_addr);
    console.puts(" -> handler at ");
    console.putHex(irq_handler_addr);
    console.puts("\n  Branch inst: ");
    console.putHex(b_inst);
    console.newline();

    asm volatile ("msr vbar_el1, %[vbar]"
        :
        : [vbar] "r" (vbar),
    );
    asm volatile ("isb");
    // Clear instruction cache to ensure patched code is visible
    asm volatile ("ic iallu");
    asm volatile ("dsb sy");
    asm volatile ("isb");
}

// Vector table - pre-initialized with NOPs, aligned to 2KB
// We use a var so we can patch it at runtime
// Use .data.vectors instead of .text.vectors so it's writable
export var vector_table: [2048]u8 align(2048) linksection(".data.vectors") = initVectorTable();

fn initVectorTable() [2048]u8 {
    @setEvalBranchQuota(10000);
    var table: [2048]u8 = undefined;

    // Helper to encode ARM64 instructions
    const encodeB = struct {
        fn f(offset: i32) u32 {
            // B instruction: 0b000101 << 26 | imm26
            const imm26: u32 = @bitCast(@as(i32, offset >> 2) & 0x3FFFFFF);
            return (0b000101 << 26) | imm26;
        }
    }.f;

    // Write instruction to table
    const writeInst = struct {
        fn f(t: *[2048]u8, offset: usize, inst: u32) void {
            t[offset] = @truncate(inst);
            t[offset + 1] = @truncate(inst >> 8);
            t[offset + 2] = @truncate(inst >> 16);
            t[offset + 3] = @truncate(inst >> 24);
        }
    }.f;

    // NOP instruction
    const NOP: u32 = 0xD503201F;
    // ERET instruction
    const ERET: u32 = 0xD69F03E0;

    // Fill entire table with NOPs first
    var i: usize = 0;
    while (i < 2048) : (i += 4) {
        writeInst(&table, i, NOP);
    }

    // For each of 16 vectors, fill 128 bytes
    // Vectors 0-3: EL1t (shouldn't happen) - infinite loop
    // Vectors 4-7: EL1h (normal kernel) - we handle sync and irq
    // Vectors 8-11: EL0 64-bit - for later
    // Vectors 12-15: EL0 32-bit - not used

    // Vector 0 (EL1t Sync) at offset 0x000 - just loop
    writeInst(&table, 0x000, encodeB(0));

    // Vector 1 (EL1t IRQ) at offset 0x080 - just loop
    writeInst(&table, 0x080, encodeB(0));

    // Vector 2 (EL1t FIQ) at offset 0x100 - just loop
    writeInst(&table, 0x100, encodeB(0));

    // Vector 3 (EL1t SError) at offset 0x180 - just loop
    writeInst(&table, 0x180, encodeB(0));

    // Vector 4 (EL1h Sync) at offset 0x200 - just eret for now
    writeInst(&table, 0x200, ERET);

    // Vector 5 (EL1h IRQ) at offset 0x280 - this is our main IRQ handler!
    // We need proper save/call/restore here. For now, just ERET
    // This will be replaced with proper handler code
    writeInst(&table, 0x280, ERET);

    // Vector 6 (EL1h FIQ) at offset 0x300 - just loop
    writeInst(&table, 0x300, encodeB(0));

    // Vector 7 (EL1h SError) at offset 0x380 - just loop
    writeInst(&table, 0x380, encodeB(0));

    // Vectors 8-15 (EL0) - just loop
    writeInst(&table, 0x400, encodeB(0));
    writeInst(&table, 0x480, encodeB(0));
    writeInst(&table, 0x500, encodeB(0));
    writeInst(&table, 0x580, encodeB(0));
    writeInst(&table, 0x600, encodeB(0));
    writeInst(&table, 0x680, encodeB(0));
    writeInst(&table, 0x700, encodeB(0));
    writeInst(&table, 0x780, encodeB(0));

    return table;
}

// The real IRQ handler needs to be a naked function
// that saves registers, calls handleIrq, restores, and erets
pub fn irqEntry() callconv(.Naked) void {
    asm volatile (
        // Save caller-saved registers
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x18, x30, [sp, #-16]!
        \\
        // Call the Zig handler
        \\bl handleIrqWrapper
        \\
        // Restore registers
        \\ldp x18, x30, [sp], #16
        \\ldp x16, x17, [sp], #16
        \\ldp x14, x15, [sp], #16
        \\ldp x12, x13, [sp], #16
        \\ldp x10, x11, [sp], #16
        \\ldp x8, x9, [sp], #16
        \\ldp x6, x7, [sp], #16
        \\ldp x4, x5, [sp], #16
        \\ldp x2, x3, [sp], #16
        \\ldp x0, x1, [sp], #16
        \\eret
    );
}

export fn handleIrqWrapper() callconv(.C) void {
    interrupt.handleIrq();
}

// Sync exception handler (for SVC/syscalls)
pub fn syncEntry() callconv(.Naked) void {
    asm volatile (
        // Allocate frame and save registers in struct order
        // SyscallFrame: x0-x7, x8-x17, x18, x30, elr, spsr (22 * 8 = 176 bytes)
        \\sub sp, sp, #176
        \\stp x0, x1, [sp, #0]
        \\stp x2, x3, [sp, #16]
        \\stp x4, x5, [sp, #32]
        \\stp x6, x7, [sp, #48]
        \\stp x8, x9, [sp, #64]
        \\stp x10, x11, [sp, #80]
        \\stp x12, x13, [sp, #96]
        \\stp x14, x15, [sp, #112]
        \\stp x16, x17, [sp, #128]
        \\stp x18, x30, [sp, #144]
        \\mrs x0, elr_el1
        \\mrs x1, spsr_el1
        \\stp x0, x1, [sp, #160]
        \\
        // Pass frame pointer to handler
        \\mov x0, sp
        \\bl handleSyncWrapper
        \\
        // Restore ELR_EL1 and SPSR_EL1
        \\ldp x0, x1, [sp, #160]
        \\msr elr_el1, x0
        \\msr spsr_el1, x1
        \\
        // Restore registers (x0 may have been modified by syscall return value)
        \\ldp x18, x30, [sp, #144]
        \\ldp x16, x17, [sp, #128]
        \\ldp x14, x15, [sp, #112]
        \\ldp x12, x13, [sp, #96]
        \\ldp x10, x11, [sp, #80]
        \\ldp x8, x9, [sp, #64]
        \\ldp x6, x7, [sp, #48]
        \\ldp x4, x5, [sp, #32]
        \\ldp x2, x3, [sp, #16]
        \\ldp x0, x1, [sp, #0]
        \\add sp, sp, #176
        \\eret
    );
}

const syscall = root.syscall;
const scheduler = root.scheduler;

export fn handleSyncWrapper(frame: *syscall.SyscallFrame) callconv(.C) void {
    // Read ESR to determine exception type
    var esr: u64 = undefined;
    asm volatile ("mrs %[esr], esr_el1"
        : [esr] "=r" (esr),
    );

    // Extract exception class (bits 31:26)
    const ec = (esr >> 26) & 0x3F;

    // EC 0x15 = SVC instruction (64-bit)
    if (ec == 0x15) {
        // This is a syscall - dispatch it
        syscall.dispatch(frame);
    } else {
        // Other sync exception - for now just return
        // TODO: Handle page faults, undefined instructions, etc.
    }
}

// ============================================================
// EL0 Exception Handlers (exceptions from userspace)
// ============================================================

/// EL0 Sync handler - handles syscalls from userspace
/// When entering from EL0, we're automatically on SP_EL1 (kernel stack)
pub fn el0SyncEntry() callconv(.Naked) void {
    asm volatile (
        // We're on kernel stack (SP_EL1). Save user state.
        // Allocate frame: x0-x30, sp_el0, elr, spsr = 34 * 8 = 272 bytes
        // But we'll use same SyscallFrame layout for compatibility (176 bytes)
        // and save SP_EL0 separately
        \\sub sp, sp, #192
        \\stp x0, x1, [sp, #0]
        \\stp x2, x3, [sp, #16]
        \\stp x4, x5, [sp, #32]
        \\stp x6, x7, [sp, #48]
        \\stp x8, x9, [sp, #64]
        \\stp x10, x11, [sp, #80]
        \\stp x12, x13, [sp, #96]
        \\stp x14, x15, [sp, #112]
        \\stp x16, x17, [sp, #128]
        \\stp x18, x30, [sp, #144]
        \\mrs x0, elr_el1
        \\mrs x1, spsr_el1
        \\stp x0, x1, [sp, #160]
        // Save SP_EL0 (user stack pointer)
        \\mrs x0, sp_el0
        \\str x0, [sp, #176]
        \\
        // Pass frame pointer to handler
        \\mov x0, sp
        \\bl handleEl0SyncWrapper
        \\
        // Restore SP_EL0
        \\ldr x0, [sp, #176]
        \\msr sp_el0, x0
        // Restore ELR_EL1 and SPSR_EL1
        \\ldp x0, x1, [sp, #160]
        \\msr elr_el1, x0
        \\msr spsr_el1, x1
        \\
        // Restore user registers
        \\ldp x18, x30, [sp, #144]
        \\ldp x16, x17, [sp, #128]
        \\ldp x14, x15, [sp, #112]
        \\ldp x12, x13, [sp, #96]
        \\ldp x10, x11, [sp, #80]
        \\ldp x8, x9, [sp, #64]
        \\ldp x6, x7, [sp, #48]
        \\ldp x4, x5, [sp, #32]
        \\ldp x2, x3, [sp, #16]
        \\ldp x0, x1, [sp, #0]
        \\add sp, sp, #192
        \\eret
    );
}

/// Extended frame for EL0 exceptions (includes SP_EL0)
pub const El0Frame = struct {
    // Same as SyscallFrame
    x0: u64,
    x1: u64,
    x2: u64,
    x3: u64,
    x4: u64,
    x5: u64,
    x6: u64,
    x7: u64,
    x8: u64,
    x9: u64,
    x10: u64,
    x11: u64,
    x12: u64,
    x13: u64,
    x14: u64,
    x15: u64,
    x16: u64,
    x17: u64,
    x18: u64,
    x30: u64,
    elr: u64,
    spsr: u64,
    // Extra: user stack pointer
    sp_el0: u64,
};

export fn handleEl0SyncWrapper(frame: *El0Frame) callconv(.C) void {
    // Read ESR to determine exception type
    var esr: u64 = undefined;
    asm volatile ("mrs %[esr], esr_el1"
        : [esr] "=r" (esr),
    );

    // Extract exception class (bits 31:26)
    const ec = (esr >> 26) & 0x3F;

    // EC 0x15 = SVC instruction (64-bit)
    if (ec == 0x15) {
        // This is a syscall from userspace - dispatch it
        // Cast to SyscallFrame (same layout for first 22 fields)
        const syscall_frame: *syscall.SyscallFrame = @ptrCast(frame);
        syscall.dispatch(syscall_frame);
    } else {
        // Other sync exception from userspace
        console.puts(console.Color.red);
        console.puts("[EL0] Sync EC=");
        console.putHex(ec);
        console.puts(" ESR=");
        console.putHex(esr);
        console.puts(" ELR=");
        console.putHex(frame.elr);
        console.puts(" FAR=");
        // Read FAR_EL1 (fault address register)
        var far: u64 = undefined;
        asm volatile ("mrs %[far], far_el1"
            : [far] "=r" (far),
        );
        console.putHex(far);
        console.newline();
        console.puts(console.Color.reset);
    }
}

/// EL0 IRQ handler - handles interrupts while in userspace
/// This is critical for preemption of user threads
pub fn el0IrqEntry() callconv(.Naked) void {
    asm volatile (
        // We're on kernel stack (SP_EL1). Save ALL user state.
        // This is important because we might context switch away
        \\sub sp, sp, #192
        \\stp x0, x1, [sp, #0]
        \\stp x2, x3, [sp, #16]
        \\stp x4, x5, [sp, #32]
        \\stp x6, x7, [sp, #48]
        \\stp x8, x9, [sp, #64]
        \\stp x10, x11, [sp, #80]
        \\stp x12, x13, [sp, #96]
        \\stp x14, x15, [sp, #112]
        \\stp x16, x17, [sp, #128]
        \\stp x18, x30, [sp, #144]
        \\mrs x0, elr_el1
        \\mrs x1, spsr_el1
        \\stp x0, x1, [sp, #160]
        // Save SP_EL0 (user stack pointer)
        \\mrs x0, sp_el0
        \\str x0, [sp, #176]
        \\
        // Call the IRQ handler
        \\bl handleEl0IrqWrapper
        \\
        // Restore SP_EL0
        \\ldr x0, [sp, #176]
        \\msr sp_el0, x0
        // Restore ELR_EL1 and SPSR_EL1
        \\ldp x0, x1, [sp, #160]
        \\msr elr_el1, x0
        \\msr spsr_el1, x1
        \\
        // Restore user registers
        \\ldp x18, x30, [sp, #144]
        \\ldp x16, x17, [sp, #128]
        \\ldp x14, x15, [sp, #112]
        \\ldp x12, x13, [sp, #96]
        \\ldp x10, x11, [sp, #80]
        \\ldp x8, x9, [sp, #64]
        \\ldp x6, x7, [sp, #48]
        \\ldp x4, x5, [sp, #32]
        \\ldp x2, x3, [sp, #16]
        \\ldp x0, x1, [sp, #0]
        \\add sp, sp, #192
        \\eret
    );
}

export fn handleEl0IrqWrapper() callconv(.C) void {
    // Handle the interrupt (same as kernel mode)
    interrupt.handleIrq();

    // After IRQ handling, check if we need to reschedule
    // For user threads, we need to yield here to allow preemption
    // The user's state is already saved on the kernel stack by el0IrqEntry
    scheduler.checkReschedule();
}
