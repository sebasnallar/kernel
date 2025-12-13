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

    // Patch Sync vector (at offset 0x200) to branch to syncEntry
    const sync_handler_addr = @intFromPtr(&syncEntry);
    const sync_vector_addr = vbar + 0x200;
    const sync_b_inst = encodeB(sync_vector_addr, sync_handler_addr);
    table_ptr[0x200 / 4] = sync_b_inst;

    // Patch IRQ vector (at offset 0x280) to branch to irqEntry
    const irq_handler_addr = @intFromPtr(&irqEntry);
    const irq_vector_addr = vbar + 0x280;
    const b_inst = encodeB(irq_vector_addr, irq_handler_addr);

    // Write the branch instruction at the IRQ vector entry
    table_ptr[0x280 / 4] = b_inst;

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
        // Save all caller-saved registers + syscall args
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
        // Save ELR_EL1 and SPSR_EL1
        \\mrs x0, elr_el1
        \\mrs x1, spsr_el1
        \\stp x0, x1, [sp, #-16]!
        \\
        // Pass frame pointer to handler
        \\mov x0, sp
        \\bl handleSyncWrapper
        \\
        // Restore ELR_EL1 and SPSR_EL1
        \\ldp x0, x1, [sp], #16
        \\msr elr_el1, x0
        \\msr spsr_el1, x1
        \\
        // Restore registers (x0 contains return value from syscall)
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

const syscall = root.syscall;

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
