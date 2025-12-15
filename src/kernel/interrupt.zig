// MyLittleKernel - Interrupt Handling
//
// ARM64 exception and interrupt management:
//   - Exception vector table
//   - GIC (Generic Interrupt Controller) driver
//   - Timer interrupt for preemption
//   - Interrupt routing to userspace services

const root = @import("root");
const scheduler = root.scheduler;
const vectors = root.vectors;

// ============================================================
// ARM64 Exception Classes
// ============================================================

/// Exception class (from ESR_EL1.EC field)
pub const ExceptionClass = enum(u6) {
    unknown = 0b000000,
    wf_trap = 0b000001,
    sve_simd_fp = 0b000111,
    illegal_state = 0b001110,
    svc_aarch64 = 0b010101, // System calls!
    inst_abort_lower = 0b100000,
    inst_abort_same = 0b100001,
    pc_alignment = 0b100010,
    data_abort_lower = 0b100100,
    data_abort_same = 0b100101,
    sp_alignment = 0b100110,
    serror = 0b101111,
    breakpoint_lower = 0b110000,
    breakpoint_same = 0b110001,
    brk_aarch64 = 0b111100,
    _,
};

// ============================================================
// Exception Frame
// ============================================================

/// Saved CPU state during exception
pub const ExceptionFrame = struct {
    // General purpose registers x0-x30
    regs: [31]u64,
    sp: u64,
    elr: u64, // Return address
    spsr: u64, // Saved processor state
    esr: u64, // Exception syndrome
    far: u64, // Fault address
};

// ============================================================
// GIC (Generic Interrupt Controller)
// ============================================================

/// GIC Distributor registers (QEMU virt: 0x08000000)
const GICD_BASE: usize = 0x08000000;
const GICD_CTLR: *volatile u32 = @ptrFromInt(GICD_BASE + 0x000);
const GICD_TYPER: *volatile u32 = @ptrFromInt(GICD_BASE + 0x004);
const GICD_ISENABLER: *volatile [32]u32 = @ptrFromInt(GICD_BASE + 0x100);
const GICD_ICENABLER: *volatile [32]u32 = @ptrFromInt(GICD_BASE + 0x180);
const GICD_IPRIORITYR: *volatile [256]u32 = @ptrFromInt(GICD_BASE + 0x400);
const GICD_ITARGETSR: *volatile [256]u32 = @ptrFromInt(GICD_BASE + 0x800);

/// GIC CPU Interface registers (QEMU virt: 0x08010000)
const GICC_BASE: usize = 0x08010000;
const GICC_CTLR: *volatile u32 = @ptrFromInt(GICC_BASE + 0x000);
const GICC_PMR: *volatile u32 = @ptrFromInt(GICC_BASE + 0x004);
const GICC_IAR: *volatile u32 = @ptrFromInt(GICC_BASE + 0x00C);
const GICC_EOIR: *volatile u32 = @ptrFromInt(GICC_BASE + 0x010);

/// Well-known interrupt numbers
pub const IRQ = struct {
    pub const TIMER_NS_PHYS: u32 = 30; // Non-secure physical timer (PPI)
    pub const UART0: u32 = 33; // UART0 (SPI)
};

// ============================================================
// Interrupt Handlers
// ============================================================

const MAX_IRQ: usize = 256;
var irq_handlers: [MAX_IRQ]?*const fn () void = [_]?*const fn () void{null} ** MAX_IRQ;
var timer_ticks: u64 = 0;

// ============================================================
// Initialization
// ============================================================

/// Initialize exception vector table
pub fn initVectors() void {
    vectors.install();
}

/// Initialize the GIC
pub fn initGic() void {
    // Disable distributor during configuration
    GICD_CTLR.* = 0;

    // Set all interrupts to lowest priority (0xFF)
    for (GICD_IPRIORITYR) |*reg| {
        reg.* = 0xFFFFFFFF;
    }

    // Route all SPIs to CPU 0
    // (SPIs start at interrupt 32, registers 8+)
    for (GICD_ITARGETSR[8..]) |*reg| {
        reg.* = 0x01010101;
    }

    // Enable distributor
    GICD_CTLR.* = 1;

    // Configure CPU interface
    GICC_PMR.* = 0xFF; // Accept all priority levels
    GICC_CTLR.* = 1; // Enable interface
}

/// Enable timer interrupt
pub fn enableTimerIrq() void {
    // Set timer interrupt priority (PPIs are in first bank)
    // PPI 30 is at offset 30 in IPRIORITYR (each byte is one IRQ)
    const priority_reg = GICD_BASE + 0x400 + (IRQ.TIMER_NS_PHYS & ~@as(u32, 3));
    const priority_shift = (IRQ.TIMER_NS_PHYS % 4) * 8;
    const priority_ptr: *volatile u32 = @ptrFromInt(priority_reg);
    const mask = ~(@as(u32, 0xFF) << @intCast(priority_shift));
    const prio = @as(u32, 0x80) << @intCast(priority_shift); // Mid priority
    priority_ptr.* = (priority_ptr.* & mask) | prio;

    // Enable the non-secure physical timer interrupt (PPI 30)
    enableIrq(IRQ.TIMER_NS_PHYS);

    // Configure the timer itself
    const timer_freq = getTimerFrequency();
    const interval = timer_freq / 100; // 100 Hz = 10ms ticks

    console.puts("  Timer freq: ");
    console.putDec(timer_freq);
    console.puts(" Hz, interval: ");
    console.putDec(interval);
    console.newline();

    setTimerCompare(interval);
    enableTimer();
}

/// Get ARM generic timer frequency
fn getTimerFrequency() u64 {
    var freq: u64 = undefined;
    asm volatile ("mrs %[freq], cntfrq_el0"
        : [freq] "=r" (freq),
    );
    return freq;
}

/// Set timer compare value
fn setTimerCompare(ticks: u64) void {
    asm volatile ("msr cntp_tval_el0, %[ticks]"
        :
        : [ticks] "r" (ticks),
    );
}

/// Enable the physical timer
fn enableTimer() void {
    // CNTP_CTL_EL0: Enable=1, IMASK=0
    asm volatile ("msr cntp_ctl_el0, %[val]"
        :
        : [val] "r" (@as(u64, 1)),
    );
}

// ============================================================
// IRQ Management
// ============================================================

/// Enable a specific interrupt
pub fn enableIrq(irq: u32) void {
    const reg = irq / 32;
    const bit: u5 = @truncate(irq % 32);
    GICD_ISENABLER[reg] = @as(u32, 1) << bit;
}

/// Disable a specific interrupt
pub fn disableIrq(irq: u32) void {
    const reg = irq / 32;
    const bit: u5 = @truncate(irq % 32);
    GICD_ICENABLER[reg] = @as(u32, 1) << bit;
}

/// Register an interrupt handler
pub fn registerHandler(irq: u32, handler: *const fn () void) void {
    if (irq < MAX_IRQ) {
        irq_handlers[irq] = handler;
    }
}

/// Unregister an interrupt handler
pub fn unregisterHandler(irq: u32) void {
    if (irq < MAX_IRQ) {
        irq_handlers[irq] = null;
    }
}

// ============================================================
// Exception Handlers (called from vector table)
// ============================================================

const console = root.console;

/// Handle IRQ exception
pub fn handleIrq() void {
    // Read interrupt ID from GIC
    const iar = GICC_IAR.*;
    const irq = iar & 0x3FF;

    // Spurious interrupt check
    if (irq >= 1020) return;

    // Dispatch interrupt
    switch (irq) {
        IRQ.TIMER_NS_PHYS => handleTimerIrq(),
        else => {
            if (irq < MAX_IRQ) {
                if (irq_handlers[irq]) |handler| handler();
            }
        },
    }

    // Signal end of interrupt
    GICC_EOIR.* = iar;
}

/// Handle timer interrupt
fn handleTimerIrq() void {
    timer_ticks += 1;

    // Re-arm timer for next tick
    const timer_freq = getTimerFrequency();
    const interval = timer_freq / 100;
    setTimerCompare(interval);

    // Call scheduler for preemption
    scheduler.timerTick();
}

/// Handle synchronous exception
pub fn handleSync(esr: u64, elr: u64, far: u64) void {
    const ec: ExceptionClass = @enumFromInt(@as(u6, @truncate(esr >> 26)));

    switch (ec) {
        .svc_aarch64 => {
            // System call - handled by vectors.zig el0_sync
            // Parameters are passed through registers, not used here
        },
        .data_abort_lower => {
            // Data abort from userspace (EL0) - kill the process
            handleUserFault("Data abort", esr, elr, far);
        },
        .inst_abort_lower => {
            // Instruction fetch fault from userspace (EL0) - kill the process
            handleUserFault("Instruction abort", esr, elr, far);
        },
        .data_abort_same, .inst_abort_same => {
            // Fault from kernel (EL1) - this is a kernel bug, panic!
            kernelPanic("Kernel fault", ec, esr, elr, far);
        },
        .illegal_state => {
            kernelPanic("Illegal state", ec, esr, elr, far);
        },
        .pc_alignment, .sp_alignment => {
            // Alignment fault - kill user process or panic if kernel
            if (isUserException(esr)) {
                handleUserFault("Alignment fault", esr, elr, far);
            } else {
                kernelPanic("Kernel alignment fault", ec, esr, elr, far);
            }
        },
        .serror => {
            kernelPanic("SError interrupt", ec, esr, elr, far);
        },
        else => {
            // Unhandled exception
            console.puts("\n[EXCEPTION] Unhandled exception class: 0x");
            console.putHex(@intFromEnum(ec));
            console.puts(" ESR: 0x");
            console.putHex(esr);
            console.puts(" ELR: 0x");
            console.putHex(elr);
            console.puts("\n");
            if (isUserException(esr)) {
                handleUserFault("Unknown exception", esr, elr, far);
            } else {
                kernelPanic("Unknown kernel exception", ec, esr, elr, far);
            }
        },
    }
}

/// Check if exception originated from user mode (EL0)
fn isUserException(esr: u64) bool {
    // Bit 25 of ESR_EL1 indicates if exception was from lower level
    // For data/instruction aborts, check EC[5] (bit 26+5=31)
    // Actually, we can check by looking at the exception class
    const ec: ExceptionClass = @enumFromInt(@as(u6, @truncate(esr >> 26)));
    return switch (ec) {
        .data_abort_lower, .inst_abort_lower, .svc_aarch64 => true,
        else => false,
    };
}

/// Handle a userspace fault by killing the process
fn handleUserFault(reason: []const u8, esr: u64, elr: u64, far: u64) void {
    console.puts("\n[FAULT] ");
    console.puts(reason);
    console.puts(" in user process\n");
    console.puts("  ESR: 0x");
    console.putHex(esr);
    console.puts("  ELR: 0x");
    console.putHex(elr);
    console.puts("\n  FAR: 0x");
    console.putHex(far);

    // Get current process info
    if (scheduler.getCurrent()) |thread| {
        if (thread.process) |proc| {
            console.puts("\n  PID: ");
            console.putDec(proc.pid);
            console.puts(" TID: ");
            console.putDec(thread.tid);
        }
    }
    console.puts("\n  Killing process...\n");

    // Kill the faulting process with signal-like exit code (128 + signal)
    // SIGSEGV = 11, so exit code = 139
    scheduler.exitProcess(139);
}

/// Kernel panic - unrecoverable error
fn kernelPanic(reason: []const u8, ec: ExceptionClass, esr: u64, elr: u64, far: u64) void {
    console.puts("\n\n");
    console.puts("╔══════════════════════════════════════════════════════════════╗\n");
    console.puts("║                    KERNEL PANIC                              ║\n");
    console.puts("╠══════════════════════════════════════════════════════════════╣\n");
    console.puts("║ ");
    console.puts(reason);
    console.puts("\n");
    console.puts("╠══════════════════════════════════════════════════════════════╣\n");
    console.puts("║ Exception Class: 0x");
    console.putHex(@intFromEnum(ec));
    console.puts("\n");
    console.puts("║ ESR_EL1:         0x");
    console.putHex(esr);
    console.puts("\n");
    console.puts("║ ELR_EL1:         0x");
    console.putHex(elr);
    console.puts("\n");
    console.puts("║ FAR_EL1:         0x");
    console.putHex(far);
    console.puts("\n");
    console.puts("╚══════════════════════════════════════════════════════════════╝\n");
    console.puts("\nSystem halted.\n");

    // Halt the system
    disableInterrupts();
    while (true) {
        asm volatile ("wfe");
    }
}

/// Get timer tick count
pub fn getTimerTicks() u64 {
    return timer_ticks;
}

/// Enable interrupts (clear DAIF.I)
pub fn enableInterrupts() void {
    asm volatile ("msr daifclr, #2");
}

/// Disable interrupts (set DAIF.I)
pub fn disableInterrupts() void {
    asm volatile ("msr daifset, #2");
}

/// Check if interrupts are enabled
pub fn interruptsEnabled() bool {
    var daif: u64 = undefined;
    asm volatile ("mrs %[daif], daif"
        : [daif] "=r" (daif),
    );
    return (daif & (1 << 7)) == 0;
}
