// MyLittleKernel - ARM64 Context Switching
//
// Low-level assembly for switching between threads.
// Saves/restores callee-saved registers per AAPCS64.

const root = @import("root");
const scheduler = root.scheduler;

/// Perform context switch from current to next thread
/// This saves the current CPU state and restores the next thread's state.
///
/// Arguments:
///   old_ctx: Pointer to current thread's CpuContext (to save into)
///   new_ctx: Pointer to next thread's CpuContext (to restore from)
pub fn switchContext(old_ctx: *scheduler.CpuContext, new_ctx: *const scheduler.CpuContext) void {
    // Save callee-saved registers to old context, restore from new context
    // IMPORTANT: No function calls here - they would clobber registers before the asm runs
    asm volatile (
        // Save current thread's callee-saved registers
        \\stp x19, x20, [%[old], #0]
        \\stp x21, x22, [%[old], #16]
        \\stp x23, x24, [%[old], #32]
        \\stp x25, x26, [%[old], #48]
        \\stp x27, x28, [%[old], #64]
        \\str x29, [%[old], #80]
        // Save return address: calculate address of .Lresume_ctx label
        \\adr x2, .Lresume_ctx
        \\str x2, [%[old], #88]
        \\mov x2, sp
        \\str x2, [%[old], #96]
        \\
        // Restore next thread's callee-saved registers
        \\ldp x19, x20, [%[new], #0]
        \\ldp x21, x22, [%[new], #16]
        \\ldp x23, x24, [%[new], #32]
        \\ldp x25, x26, [%[new], #48]
        \\ldp x27, x28, [%[new], #64]
        \\ldp x29, x30, [%[new], #80]
        \\ldr x2, [%[new], #96]
        \\mov sp, x2
        \\
        // Return to new thread (via restored x30/lr)
        \\ret
        \\
        \\.Lresume_ctx:
        // Old thread resumes here when switched back
        :
        : [old] "r" (old_ctx),
          [new] "r" (new_ctx),
        : "x2", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "x30", "memory"
    );
}

/// Start a new thread for the first time
/// This doesn't save any context, just loads the new thread's context and jumps to it.
///
/// Arguments:
///   ctx: Pointer to the new thread's CpuContext
pub fn startThread(ctx: *const scheduler.CpuContext) noreturn {
    asm volatile (
        // Load the thread's registers
        \\ldp x19, x20, [x0, #0]
        \\ldp x21, x22, [x0, #16]
        \\ldp x23, x24, [x0, #32]
        \\ldp x25, x26, [x0, #48]
        \\ldp x27, x28, [x0, #64]
        \\ldp x29, x30, [x0, #80]
        \\ldr x1, [x0, #96]
        \\mov sp, x1
        \\
        // Load entry point and jump to it
        \\ldr x1, [x0, #104]
        \\br x1
        :
        : [ctx] "{x0}" (ctx),
        : "x1", "memory"
    );
    unreachable;
}

/// Switch to a new thread that hasn't run yet - INLINE VERSION
/// Use this inline assembly directly in the scheduler to avoid function call overhead.
/// The old thread will resume at the .Lresume label when switched back.
pub inline fn switchToNewInline(old_ctx: *scheduler.CpuContext, new_ctx: *const scheduler.CpuContext) void {
    asm volatile (
        // Save current thread's callee-saved registers
        \\stp x19, x20, [%[old], #0]
        \\stp x21, x22, [%[old], #16]
        \\stp x23, x24, [%[old], #32]
        \\stp x25, x26, [%[old], #48]
        \\stp x27, x28, [%[old], #64]
        \\str x29, [%[old], #80]
        // Save return address: calculate address of .Lresume label
        \\adr x2, .Lresume
        \\str x2, [%[old], #88]
        \\mov x2, sp
        \\str x2, [%[old], #96]
        \\
        // Load new thread's registers (except x30, sp, pc)
        \\ldp x19, x20, [%[new], #0]
        \\ldp x21, x22, [%[new], #16]
        \\ldp x23, x24, [%[new], #32]
        \\ldp x25, x26, [%[new], #48]
        \\ldp x27, x28, [%[new], #64]
        \\ldr x29, [%[new], #80]
        \\ldr x2, [%[new], #96]
        \\mov sp, x2
        \\
        // Jump to new thread's entry point (stored in pc field at offset 104)
        \\ldr x2, [%[new], #104]
        \\br x2
        \\
        \\.Lresume:
        // This is where the old thread resumes when switched back via switchContext
        :
        : [old] "r" (old_ctx),
          [new] "r" (new_ctx),
        : "x2", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "x30", "memory"
    );
}

/// Initialize a thread's context for first execution (kernel thread - EL1)
/// Sets up the context so that when the thread is switched to,
/// it starts executing at the entry point with the given stack.
pub fn initContext(ctx: *scheduler.CpuContext, entry: u64, stack_top: u64) void {
    // Zero all callee-saved registers
    ctx.x19 = 0;
    ctx.x20 = 0;
    ctx.x21 = 0;
    ctx.x22 = 0;
    ctx.x23 = 0;
    ctx.x24 = 0;
    ctx.x25 = 0;
    ctx.x26 = 0;
    ctx.x27 = 0;
    ctx.x28 = 0;
    ctx.x29 = 0; // Frame pointer
    ctx.x30 = @intFromPtr(&threadExit); // Return address -> cleanup
    ctx.sp = stack_top;
    ctx.pc = entry;
}

/// Initialize a user thread's context for first execution (EL0)
/// The thread will drop to EL0 via ERET when first scheduled.
pub fn initUserContext(ctx: *scheduler.CpuContext, entry: u64, kernel_sp: u64, user_sp: u64) void {
    // Zero all callee-saved registers
    ctx.x19 = 0;
    ctx.x20 = 0;
    ctx.x21 = 0;
    ctx.x22 = 0;
    ctx.x23 = 0;
    ctx.x24 = 0;
    ctx.x25 = 0;
    ctx.x26 = 0;
    ctx.x27 = 0;
    ctx.x28 = 0;
    ctx.x29 = 0; // Frame pointer
    ctx.x30 = 0; // Not used - we ERET to entry point
    ctx.sp = kernel_sp; // Kernel stack (SP_EL1 for exception handling)
    ctx.pc = entry; // Entry point in user code

    // Store user_sp in x19 temporarily - will be loaded into SP_EL0 before ERET
    ctx.x19 = user_sp;
}

/// Start a user thread for the first time - drops to EL0 via ERET
/// This saves the old context and then ERets to the new user thread.
/// old_ctx: kernel context to save (so we can return to scheduler)
/// entry: user code entry point
/// user_sp: user stack pointer (SP_EL0)
/// kernel_sp: kernel stack for this thread (SP_EL1)
pub inline fn startUserThreadInline(
    old_ctx: *scheduler.CpuContext,
    entry: u64,
    user_sp: u64,
    kernel_sp: u64,
) void {
    asm volatile (
        // Save current (kernel) thread's callee-saved registers
        \\stp x19, x20, [%[old], #0]
        \\stp x21, x22, [%[old], #16]
        \\stp x23, x24, [%[old], #32]
        \\stp x25, x26, [%[old], #48]
        \\stp x27, x28, [%[old], #64]
        \\str x29, [%[old], #80]
        // Save resume address
        \\adr x2, .Lresume_from_user
        \\str x2, [%[old], #88]
        \\mov x2, sp
        \\str x2, [%[old], #96]
        \\
        // Set up for EL0 entry
        // Set kernel stack (SP_EL1) - this is where exceptions will use
        \\mov sp, %[ksp]
        \\
        // Set user stack (SP_EL0)
        \\msr sp_el0, %[usp]
        \\
        // Set return address for ERET (ELR_EL1)
        \\msr elr_el1, %[entry]
        \\
        // Set SPSR_EL1 for EL0t (bits 3:0 = 0 for EL0)
        // Enable interrupts (clear I bit = bit 7, clear F bit = bit 6)
        \\mov x2, #0
        \\msr spsr_el1, x2
        \\
        // Clear user-visible registers for clean start
        \\mov x0, #0
        \\mov x1, #0
        \\mov x2, #0
        \\mov x3, #0
        \\mov x4, #0
        \\mov x5, #0
        \\mov x6, #0
        \\mov x7, #0
        \\mov x8, #0
        \\mov x9, #0
        \\mov x10, #0
        \\mov x11, #0
        \\mov x12, #0
        \\mov x13, #0
        \\mov x14, #0
        \\mov x15, #0
        \\mov x16, #0
        \\mov x17, #0
        \\mov x18, #0
        \\mov x29, #0
        \\mov x30, #0
        \\
        // Drop to EL0!
        \\eret
        \\
        \\.Lresume_from_user:
        // When this thread is switched back (after being preempted), we resume here
        :
        : [old] "r" (old_ctx),
          [entry] "r" (entry),
          [usp] "r" (user_sp),
          [ksp] "r" (kernel_sp),
        : "x2", "memory"
    );
}

/// Called when a thread's entry function returns
/// This cleans up the thread.
fn threadExit() callconv(.C) noreturn {
    // Get current thread and mark it as dead
    if (scheduler.getCurrent()) |thread| {
        thread.state = .dead;
    }
    // Yield to let scheduler pick next thread
    scheduler.yield();
    // Should never reach here
    while (true) {
        asm volatile ("wfe");
    }
}
